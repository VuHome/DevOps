#!/bin/bash
set -e

DEPLOY_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2aoG82yZXaUhQEXEuDq3HISnwOD2q7KablCqYtSJiA vuhom-github-deploy"
DEVOPS_RAW="https://raw.githubusercontent.com/VuHome/DevOps/main"

echo "--- Adding deploy key ---"
grep -qF "$DEPLOY_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null \
  || echo "$DEPLOY_PUBKEY" >> /root/.ssh/authorized_keys

echo "--- Waiting for Docker to be ready ---"
until docker info >/dev/null 2>&1; do sleep 2; done

echo "--- Creating directories ---"
mkdir -p /opt/vuhom/traefik /opt/vuhom/api /opt/vuhom/platform

echo "--- Deploying Traefik ---"
curl -fsSL "$DEVOPS_RAW/docker/traefik/docker-compose.yml" -o /opt/vuhom/traefik/docker-compose.yml
curl -fsSL "$DEVOPS_RAW/docker/traefik/traefik.yml"         -o /opt/vuhom/traefik/traefik.yml
touch /opt/vuhom/traefik/acme.json && chmod 600 /opt/vuhom/traefik/acme.json
cd /opt/vuhom/traefik && docker compose up -d

echo "--- Placing app compose files ---"
curl -fsSL "$DEVOPS_RAW/docker/api/docker-compose.yml"      -o /opt/vuhom/api/docker-compose.yml
curl -fsSL "$DEVOPS_RAW/docker/platform/docker-compose.yml" -o /opt/vuhom/platform/docker-compose.yml

echo "--- Creating placeholder .env for API ---"
[ -f /opt/vuhom/api/.env ] || cat > /opt/vuhom/api/.env << 'EOF'
DEBUG_MOOD=false
HTTP_HOST=0.0.0.0
HTTP_PORT=8003
ALLOW_ORIGINS=https://vuhom.com
APP_NAME=Vuhom API

USER_JWT_SECRET_KEY=CHANGE_ME
USER_JWT_ACCESS_EXPIRES=120
USER_JWT_REFRESH_EXPIRES=30
ADMIN_JWT_SECRET_KEY=CHANGE_ME
ADMIN_JWT_ACCESS_EXPIRES=60
ADMIN_JWT_REFRESH_EXPIRES=1

MYSQL_HOST=CHANGE_ME
MYSQL_PORT=3306
MYSQL_USER=CHANGE_ME
MYSQL_PASS=CHANGE_ME
MYSQL_DB_NAME=vuhom

REDIS_HOST=CHANGE_ME
REDIS_PORT=6379
REDIS_PASS=CHANGE_ME

MINIO_IP=fsn1.your-objectstorage.com
MINIO_ACCESS_KEY=CHANGE_ME
MINIO_SECRET_KEY=CHANGE_ME
IMAGE_SECRET_KEY=CHANGE_ME

SMTP_SERVER=smtp.mx.cloudflare.net
EMAIL_SMTP_PORT=465
EMAIL_SENDER_USERNAME=api_token
EMAIL_SENDER_PASSWORD=CHANGE_ME
SENDER_EMAIL=noreply@vuhom.com
FROM_ADDRESS=noreply@vuhom.com
EOF

echo "--- Done ---"
docker ps
