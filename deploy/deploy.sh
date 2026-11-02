#!/usr/bin/env bash
# LoginGuard EC2 배포 자동화 (AWS CLI). AWS CloudShell 에서 실행한다 (콘솔 권한을 그대로 써서 키 입력 불필요).
#
#   bash deploy/deploy.sh                 # week8 브랜치 최신 커밋 배포
#   BRANCH=main bash deploy/deploy.sh     # 다른 브랜치
#
# 동작 (매번 같은 방식으로 새 환경을 만든다 = 불변 배포)
#   1. 보안 그룹(80번 포트) 준비
#   2. 최신 Amazon Linux 2023 으로 새 EC2 생성 → user-data 가 GitHub 코드로 Docker 이미지 빌드 후 실행
#   3. 새 서버의 /health 가 지금 배포한 커밋 버전으로 응답할 때까지 대기
#   4. 확인되면 이전 버전 인스턴스 종료 (확인 실패 시 이전 버전은 그대로 둠)
set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-east-1}}"
REPO_URL="${REPO_URL:-https://github.com/jyh0729/loginguard.git}"
BRANCH="${BRANCH:-week8}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
INSTANCE_PROFILE="${INSTANCE_PROFILE:-LabInstanceProfile}"   # CloudWatch 로그용 권한 (없으면 파일 로그만)
LOG_GROUP="${LOG_GROUP:-/loginguard/predictions}"
COLLECT_SSH="${COLLECT_SSH:-0}"   # 1: 22번 포트를 열고 서버에 실제로 들어오는 SSH 로그인 시도를 수집해 판정
APP=loginguard
SG_NAME=loginguard-web
export AWS_DEFAULT_REGION="$REGION"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }

COMMIT=$(git ls-remote "$REPO_URL" "refs/heads/$BRANCH" | cut -c1-7)
[ -n "$COMMIT" ] || { echo "브랜치 $BRANCH 를 찾을 수 없습니다"; exit 1; }
log "배포 대상: $REPO_URL  브랜치 $BRANCH  커밋 $COMMIT  리전 $REGION"

# 1. 보안 그룹
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "LoginGuard web (80)" \
          --vpc-id "$VPC_ID" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  log "보안 그룹 생성: $SG_ID (80번 포트 허용)"
else
  log "보안 그룹 사용: $SG_ID"
fi
if [ "$COLLECT_SSH" = "1" ]; then
  # 비밀번호 로그인은 꺼져 있으므로(Amazon Linux 기본, 키로만 접속) 시도는 기록되지만 들어올 수는 없다
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null 2>&1 \
    && log "SSH 수집용 22번 포트 열기" || log "22번 포트는 이미 열려 있음"
fi

# 2. AMI (최신 Amazon Linux 2023)
AMI_ID=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
         --query Parameter.Value --output text 2>/dev/null || true)
if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
  AMI_ID=$(aws ec2 describe-images --owners amazon \
           --filters "Name=name,Values=al2023-ami-2023*-kernel-*-x86_64" "Name=state,Values=available" \
           --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
fi
log "AMI: $AMI_ID"

OLD_IDS=$(aws ec2 describe-instances --filters "Name=tag:App,Values=$APP" "Name=instance-state-name,Values=pending,running" \
          --query 'Reservations[].Instances[].InstanceId' --output text)

# 3. 새 인스턴스
UD_FILE=$(mktemp)
sed -e "s|__REPO_URL__|$REPO_URL|" -e "s|__BRANCH__|$BRANCH|" -e "s|__REGION__|$REGION|" -e "s|__LOG_GROUP__|$LOG_GROUP|" -e "s|__COLLECT_SSH__|$COLLECT_SSH|" \
    "$HERE/user-data.sh" > "$UD_FILE"

run() {
  aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --security-group-ids "$SG_ID" \
    --user-data "file://$UD_FILE" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=16,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$APP-$COMMIT},{Key=App,Value=$APP},{Key=Version,Value=$COMMIT}]" \
    --query 'Instances[0].InstanceId' --output text "$@"
}
if ! NEW_ID=$(run --iam-instance-profile "Name=$INSTANCE_PROFILE" 2>/dev/null); then
  log "인스턴스 프로파일($INSTANCE_PROFILE) 없이 생성합니다 (CloudWatch 대신 파일 로그)"
  NEW_ID=$(run)
fi
rm -f "$UD_FILE"
log "새 인스턴스: $NEW_ID ($INSTANCE_TYPE) — 시작 대기"
aws ec2 wait instance-running --instance-ids "$NEW_ID"
IP=$(aws ec2 describe-instances --instance-ids "$NEW_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "공인 IP: $IP — Docker 빌드·실행 대기 (보통 3~6분)"

# 4. 헬스 체크 (지금 배포한 커밋 버전으로 응답해야 성공)
for i in $(seq 1 60); do
  BODY=$(curl -s -m 5 "http://$IP/health" || true)
  if echo "$BODY" | grep -q "\"version\":\"$COMMIT\""; then
    log "헬스 체크 성공: $BODY"
    break
  fi
  [ "$i" -eq 60 ] && { log "10분 안에 응답이 없습니다. 이전 버전은 유지합니다. 새 인스턴스 로그: /var/log/loginguard-deploy.log"; exit 1; }
  sleep 10
done

# 5. 이전 버전 정리
if [ -n "$OLD_IDS" ]; then
  log "이전 인스턴스 종료: $OLD_IDS"
  aws ec2 terminate-instances --instance-ids $OLD_IDS >/dev/null
fi

echo
log "배포 완료 ✅  버전 $COMMIT"
echo "  관제 화면 : http://$IP/"
echo "  API 문서  : http://$IP/docs"
echo "  헬스 체크 : http://$IP/health"
if [ "$COLLECT_SSH" = "1" ]; then
  echo "  SSH 수집기: 켜짐 — 인터넷의 실제 SSH 로그인 시도가 관제 화면에 뜹니다 (보통 수십 분 안에 시작)"
fi
