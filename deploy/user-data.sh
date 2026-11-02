#!/bin/bash
# EC2 첫 부팅 때 실행되는 스크립트 (deploy.sh 가 __값__ 을 채워서 넘긴다)
# GitHub 에서 코드를 받아 Docker 이미지를 만들고 docker compose 로 80번 포트에 띄운다.
set -euxo pipefail
exec > /var/log/loginguard-deploy.log 2>&1

dnf install -y docker git
systemctl enable --now docker

# docker compose 플러그인
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

git clone --depth 1 -b "__BRANCH__" "__REPO_URL__" /opt/loginguard
cd /opt/loginguard
VERSION=$(git rev-parse --short=7 HEAD)

cat > .env <<EOF
APP_VERSION=${VERSION}
HOST_PORT=80
AWS_DEFAULT_REGION=__REGION__
CLOUDWATCH_LOG_GROUP=__LOG_GROUP__
MODEL_SOURCE=__MODEL_SOURCE__
RBA_ROWS=__RBA_ROWS__
EOF

docker build --build-arg APP_VERSION="${VERSION}" -t "loginguard:${VERSION}" .
docker compose up -d --no-build

# (선택) 실제 SSH 로그인 시도 수집기 — deploy.sh 를 COLLECT_SSH=1 로 실행했을 때만
if [ "__COLLECT_SSH__" = "1" ]; then
  cat > /etc/systemd/system/loginguard-ssh-collector.service <<'UNIT'
[Unit]
Description=LoginGuard SSH login attempt collector
After=docker.service sshd.service
[Service]
ExecStart=/usr/bin/python3 /opt/loginguard/deploy/ssh_collector.py --api http://127.0.0.1:80
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now loginguard-ssh-collector
fi
echo "DEPLOY_DONE version=${VERSION}"
