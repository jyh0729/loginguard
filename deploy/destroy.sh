#!/usr/bin/env bash
# 배포한 LoginGuard EC2 와 보안 그룹을 모두 지운다 (실습 끝나고 비용이 나가지 않도록).
#   bash deploy/destroy.sh
set -euo pipefail
export AWS_DEFAULT_REGION="${REGION:-${AWS_REGION:-us-east-1}}"

IDS=$(aws ec2 describe-instances --filters "Name=tag:App,Values=loginguard" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  echo "인스턴스 종료: $IDS"
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS
fi
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=loginguard-web --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID" && echo "보안 그룹 삭제: $SG_ID"
fi
echo "정리 완료"
