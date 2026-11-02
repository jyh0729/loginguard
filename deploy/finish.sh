#!/usr/bin/env bash
# deploy.sh 가 중간에 끊겼을 때(CloudShell 세션 종료 등) 마무리하는 스크립트.
# 가장 최근에 만든 LoginGuard 인스턴스가 정상 응답할 때까지 기다린 뒤
# 고정 주소(탄력적 IP)를 옮기고 나머지 이전 인스턴스를 종료한다. 여러 번 실행해도 안전하다.
#   bash deploy/finish.sh
set -euo pipefail
export AWS_DEFAULT_REGION="${REGION:-${AWS_REGION:-us-east-1}}"
APP=loginguard
log() { echo "[$(date +%H:%M:%S)] $*"; }

echo "현재 LoginGuard 인스턴스:"
aws ec2 describe-instances --filters "Name=tag:App,Values=$APP" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,PublicIpAddress,LaunchTime]' --output table

read -r NEW_ID NEW_IP < <(aws ec2 describe-instances --filters "Name=tag:App,Values=$APP" "Name=instance-state-name,Values=pending,running" \
  --query 'sort_by(Reservations[].Instances[], &LaunchTime)[-1].[InstanceId,PublicIpAddress]' --output text)
[ -n "${NEW_ID:-}" ] && [ "$NEW_ID" != "None" ] || { echo "실행 중인 인스턴스가 없습니다"; exit 1; }
log "최신 인스턴스: $NEW_ID ($NEW_IP)"

# 1. 헬스 체크 (최대 30분, 1분마다 진행 표시)
for i in $(seq 1 180); do
  BODY=$(curl -s -m 5 "http://$NEW_IP/health" || true)
  if echo "$BODY" | grep -q '"status":"ok"'; then log "헬스 체크 성공: $BODY"; break; fi
  [ $((i % 6)) -eq 0 ] && log "아직 준비 중... ($((i / 6))분 경과, 실제 RBA 학습은 15~20분)"
  [ "$i" -eq 180 ] && { log "30분 안에 응답이 없습니다"; exit 1; }
  sleep 10
done

# 2. 고정 주소
IP="$NEW_IP"
ALLOC_ID=$(aws ec2 describe-addresses --filters "Name=tag:App,Values=$APP" --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)
if [ -z "$ALLOC_ID" ] || [ "$ALLOC_ID" = "None" ]; then
  ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
             --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$APP},{Key=App,Value=$APP}]" \
             --query AllocationId --output text 2>/dev/null || true)
fi
if [ -n "$ALLOC_ID" ] && [ "$ALLOC_ID" != "None" ] && \
   aws ec2 associate-address --allocation-id "$ALLOC_ID" --instance-id "$NEW_ID" --allow-reassociation >/dev/null 2>&1; then
  IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
  log "고정 주소 연결: $IP → $NEW_ID"
else
  log "탄력적 IP를 쓸 수 없어 인스턴스 IP로 진행합니다"
fi

# 3. 이전 인스턴스 종료
OLD_IDS=$(aws ec2 describe-instances --filters "Name=tag:App,Values=$APP" "Name=instance-state-name,Values=pending,running" \
          --query "Reservations[].Instances[?InstanceId!='$NEW_ID'].InstanceId" --output text)
if [ -n "$OLD_IDS" ]; then
  log "이전 인스턴스 종료: $OLD_IDS"
  aws ec2 terminate-instances --instance-ids $OLD_IDS >/dev/null
fi

echo
log "마무리 완료 ✅"
echo "  관제 화면 : http://$IP/"
echo "  헬스 체크 : http://$IP/health"
