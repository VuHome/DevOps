# Vuhom DevOps Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up a complete push-to-deploy pipeline where `main` = production on both API and platform repos, backed by a clean Hetzner server running PostgreSQL instead of MySQL.

**Architecture:** GitHub Actions on `ubuntu-latest` builds Docker images on push to `main`, pushes to GHCR, then SSHes into `91.107.169.203` to pull and restart containers. Platform already has this working; API gets the same treatment. Server is rebuilt: MySQL replaced by PostgreSQL 16, Redis kept. Alembic migrations run automatically inside the API container on startup.

**Tech Stack:** GitHub Actions, Docker Compose, GHCR (`ghcr.io/vuhome/*`), PostgreSQL 16, Redis 7, Traefik v3, Python 3.11 (FastAPI), Next.js

---

## File Map

**VuHome/API repo (clone to `/tmp/vuhom-api`):**
- Modify: `Dockerfile` — fix EXPOSE + HEALTHCHECK port (8008 → 8003)
- Delete: `.drone.yml`, `.drone.yml.bak`
- Replace: `.github/workflows/ci-cd.yml` — rewrite for ubuntu-latest + SSH deploy
- Delete: `.github/workflows/test.yml` — dummy self-hosted workflow, no value

**VuHome/platform repo (via `gh` CLI only — no local clone needed):**
- Merge `develop` → `main` via PR

**VuHome/DevOps repo (`/home/amir/CodeBase/Lotusion/Vuhom/DevOps`):**
- Replace: `docker/db/docker-compose.yml` — swap MySQL for PostgreSQL, keep Redis

**Server `91.107.169.203` (via SSH):**
- Replace: `/opt/vuhom/db/docker-compose.yml`
- Replace: `/opt/vuhom/db/.env`
- Update: `/opt/vuhom/api/.env`

**GitHub → VuHome/API repo secrets:**
- Add: `DEPLOY_HOST`, `SSH_DEPLOY_KEY`

---

> **Critical ordering:** Tasks 1–8 can run in any order among themselves, but **Task 7 (GitHub secrets) MUST complete before Task 6 Step 3 (force-push to main)**. Pushing to main triggers CI/CD immediately; if `DEPLOY_HOST` and `SSH_DEPLOY_KEY` aren't set yet, the deploy job will fail on the first run.

---

## Task 1: Merge platform `develop` → `main`

**Files:** GitHub only (no local clone)

- [ ] **Step 1: Create and merge the PR**

```bash
gh pr create \
  --repo VuHome/platform \
  --base main \
  --head develop \
  --title "merge: develop into main" \
  --body "Bring splash screen and fix commits from develop into production."

gh pr merge --repo VuHome/platform --merge --delete-branch=false
```

Expected output: `✓ Merged pull request #N`

- [ ] **Step 2: Verify main is ahead**

```bash
gh api repos/VuHome/platform/compare/develop...main --jq '{status:.status,behind:.behind_by}'
```

Expected: `{"status":"behind","behind_by":0}` or `{"status":"identical"}` — develop is not ahead of main anymore.

---

## Task 2: Clone API repo, switch to redesign

**Files:** Local `/tmp/vuhom-api`

- [ ] **Step 1: Clone the redesign branch**

```bash
git clone --branch redesign git@github.com:VuHome/API.git /tmp/vuhom-api
cd /tmp/vuhom-api
```

Expected: repo cloned, `git branch` shows `* redesign`

- [ ] **Step 2: Verify you're on the right branch**

```bash
git log --oneline -3
```

Expected: recent commits from the redesign rewrite (not old main commits).

---

## Task 3: Fix Dockerfile healthcheck port

**Files:** Modify `/tmp/vuhom-api/Dockerfile`

The file currently has `EXPOSE 8008` and a healthcheck pointing at port `8008`, but `HTTP_PORT=8003` in the production env — healthchecks always fail.

- [ ] **Step 1: Open and locate the broken lines**

```bash
grep -n "8008\|EXPOSE\|HEALTHCHECK" /tmp/vuhom-api/Dockerfile
```

Expected output:
```
47:EXPOSE 8008
50:HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
51:    CMD curl -f http://localhost:8008/health || exit 1
```

- [ ] **Step 2: Replace with correct port**

Edit `/tmp/vuhom-api/Dockerfile`. Find the block:
```dockerfile
EXPOSE 8008

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8008/health || exit 1
```

Replace it with:
```dockerfile
EXPOSE 8003

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${HTTP_PORT:-8003}/health || exit 1
```

- [ ] **Step 3: Verify**

```bash
grep -n "8008\|EXPOSE\|HEALTHCHECK" /tmp/vuhom-api/Dockerfile
```

Expected: no more `8008` in output.

---

## Task 4: Remove stale Drone CI files

**Files:** Delete `/tmp/vuhom-api/.drone.yml`, `/tmp/vuhom-api/.drone.yml.bak`

- [ ] **Step 1: Remove both files**

```bash
cd /tmp/vuhom-api
git rm .drone.yml .drone.yml.bak
```

Expected: `rm '.drone.yml'` and `rm '.drone.yml.bak'`

---

## Task 5: Replace CI/CD workflow

**Files:** Replace `/tmp/vuhom-api/.github/workflows/ci-cd.yml`, delete `/tmp/vuhom-api/.github/workflows/test.yml`

- [ ] **Step 1: Delete the dummy test workflow**

```bash
cd /tmp/vuhom-api
git rm .github/workflows/test.yml
```

- [ ] **Step 2: Write the new ci-cd.yml**

Overwrite `/tmp/vuhom-api/.github/workflows/ci-cd.yml` with exactly:

```yaml
name: CI/CD

on:
  push:
    branches: [main]

env:
  IMAGE: ghcr.io/vuhome/api

jobs:
  build-push:
    name: Build & Push
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:latest
          cache-from: type=registry,ref=${{ env.IMAGE }}:cache
          cache-to: type=registry,ref=${{ env.IMAGE }}:cache,mode=max

  deploy:
    name: Deploy
    needs: build-push
    runs-on: ubuntu-latest

    steps:
      - uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: root
          key: ${{ secrets.SSH_DEPLOY_KEY }}
          script: |
            echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
            cd /opt/vuhom/api
            docker compose pull
            docker compose up -d --remove-orphans
            docker image prune -f
```

- [ ] **Step 3: Verify the file looks right**

```bash
cat /tmp/vuhom-api/.github/workflows/ci-cd.yml
```

Expected: exactly the YAML above, `runs-on: ubuntu-latest` in both jobs, no `self-hosted`.

---

## Task 6: Commit, push redesign, reset main

**Files:** `/tmp/vuhom-api` → remote `VuHome/API`

- [ ] **Step 1: Stage and commit all changes**

```bash
cd /tmp/vuhom-api
git add Dockerfile .github/workflows/ci-cd.yml .github/workflows/test.yml .drone.yml .drone.yml.bak
git status
```

Expected: all 5 files listed as staged changes.

```bash
git commit -m "ci: fix Dockerfile port, replace CI/CD with ubuntu-latest workflow, remove Drone"
```

- [ ] **Step 2: Push the fixed redesign branch**

```bash
git push origin redesign
```

- [ ] **Step 3: Force-push redesign onto main**

> ⚠️ **Stop here if Task 7 isn't done yet.** This push triggers CI immediately. Secrets must exist or the deploy job fails on first run.

```bash
git push origin redesign:main --force
```

Expected: `+ <sha>...<sha> redesign -> main (forced update)`

- [ ] **Step 4: Verify main is now at redesign HEAD**

```bash
gh api repos/VuHome/API/branches/main --jq '.commit.sha'
git rev-parse HEAD
```

Expected: both print the same SHA.

- [ ] **Step 5: Delete the redesign branch**

```bash
git push origin --delete redesign
```

Expected: `- [deleted] redesign`

---

## Task 7: Add GitHub Actions secrets to VuHome/API

**Note:** VuHome/platform already has `DEPLOY_HOST` and `SSH_DEPLOY_KEY` set. We're adding the same secrets to VuHome/API.

- [ ] **Step 1: Set DEPLOY_HOST**

```bash
gh secret set DEPLOY_HOST --repo VuHome/API --body "91.107.169.203"
```

Expected: `✓ Set Actions secret DEPLOY_HOST for VuHome/API`

- [ ] **Step 2: Copy SSH_DEPLOY_KEY from platform to API**

GitHub secrets can't be read back via API, so export the platform secret value into the API repo using this trick — it reads the already-configured secret from the runner context. Since you can't read it directly, use the private key file that was used when platform was set up.

If the key file is at `~/.ssh/vuhom-deploy` (or similar), run:

```bash
gh secret set SSH_DEPLOY_KEY --repo VuHome/API < ~/.ssh/vuhom-deploy
```

If you don't have the file locally, generate a new deploy keypair:

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy@vuhom" -f ~/.ssh/vuhom-deploy -N ""
```

Add the public key to the server:

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 \
  "echo '$(cat ~/.ssh/vuhom-deploy.pub)' >> /root/.ssh/authorized_keys"
```

Set the secret in both repos:

```bash
gh secret set SSH_DEPLOY_KEY --repo VuHome/API < ~/.ssh/vuhom-deploy
gh secret set SSH_DEPLOY_KEY --repo VuHome/platform < ~/.ssh/vuhom-deploy
```

- [ ] **Step 3: Verify secrets are set**

```bash
gh api repos/VuHome/API/actions/secrets --jq '.secrets[].name'
```

Expected output includes:
```
DEPLOY_HOST
SSH_DEPLOY_KEY
```

---

## Task 8: Update DevOps repo — replace MySQL with PostgreSQL in db compose

**Files:** Replace `/home/amir/CodeBase/Lotusion/Vuhom/DevOps/docker/db/docker-compose.yml`

The current file has `mysql` + `redis` services. Replace `mysql` with `postgres:16-alpine`, keep `redis` intact.

- [ ] **Step 1: Write the new compose file**

Overwrite `/home/amir/CodeBase/Lotusion/Vuhom/DevOps/docker/db/docker-compose.yml` with:

```yaml
services:
  vuhom-postgres:
    image: postgres:16-alpine
    container_name: vuhom-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: vuhom
      POSTGRES_USER: vuhom
      POSTGRES_PASSWORD: ${POSTGRES_PASS}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - proxy

  vuhom-redis:
    image: redis:7-alpine
    container_name: vuhom-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASS}
    volumes:
      - redis_data:/data
    networks:
      - proxy

volumes:
  postgres_data:
  redis_data:

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Commit and push**

```bash
cd /home/amir/CodeBase/Lotusion/Vuhom/DevOps
git add docker/db/docker-compose.yml
git commit -m "infra: replace MySQL with PostgreSQL 16 in db compose"
git push
```

---

## Task 9: Server rebuild — tear down MySQL, stand up PostgreSQL

**Target:** `root@91.107.169.203` via SSH  
**SSH command prefix for all steps:** `ssh -i ~/.ssh/amirarab root@91.107.169.203`

- [ ] **Step 1: Generate a PostgreSQL password**

Run locally:

```bash
POSTGRES_PASS=$(openssl rand -hex 20)
echo "Save this: $POSTGRES_PASS"
```

Copy the output — you'll use it in the next steps.

- [ ] **Step 2: Stop and remove MySQL (data intentionally discarded)**

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "cd /opt/vuhom/db && docker compose down -v"
```

Expected:
```
Container vuhom-mysql  Removed
Container vuhom-redis  Removed
Volume vuhom-db_mysql_data  Removed
Volume vuhom-db_redis_data  Removed
```

(Redis is also stopped here — it will be brought back up with PostgreSQL in the next step.)

- [ ] **Step 3: Upload the new db docker-compose.yml**

```bash
scp -i ~/.ssh/amirarab \
  /home/amir/CodeBase/Lotusion/Vuhom/DevOps/docker/db/docker-compose.yml \
  root@91.107.169.203:/opt/vuhom/db/docker-compose.yml
```

- [ ] **Step 4: Write the db .env on the server**

Replace `<POSTGRES_PASS>` and `<REDIS_PASS>` with actual values. Redis pass is `XT2qHrzezIGvm5zpW1JYddMP7S67rold` (already in API .env).

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "cat > /opt/vuhom/db/.env << 'EOF'
POSTGRES_PASS=<POSTGRES_PASS>
REDIS_PASS=XT2qHrzezIGvm5zpW1JYddMP7S67rold
EOF"
```

- [ ] **Step 5: Start PostgreSQL and Redis**

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "cd /opt/vuhom/db && docker compose up -d"
```

Expected:
```
Container vuhom-postgres  Started
Container vuhom-redis     Started
```

- [ ] **Step 6: Verify PostgreSQL is healthy**

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 \
  "docker exec vuhom-postgres pg_isready -U vuhom -d vuhom"
```

Expected: `/var/run/postgresql:5432 - accepting connections`

---

## Task 10: Update API .env on server

**File:** `/opt/vuhom/api/.env` on `91.107.169.203`

- [ ] **Step 1: Write the new .env**

Replace `<POSTGRES_PASS>` with the value generated in Task 9 Step 1.

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "cat > /opt/vuhom/api/.env << 'EOF'
DEBUG_MOOD=false
HTTP_HOST=0.0.0.0
HTTP_PORT=8003
ALLOW_ORIGINS=https://vuhom.com,https://www.vuhom.com
APP_NAME=Vuhom API
ENVIRONMENT=production
USE_HTTPS=true
WORKERS=2

USER_JWT_SECRET_KEY=2WItXIWv0Z7GZkA61tdsOsSeKzptssR9hvWah8oT8Ix0DoaENUgJRg4uDJZI1KV
USER_JWT_ACCESS_EXPIRES=120
USER_JWT_REFRESH_EXPIRES=30
ADMIN_JWT_SECRET_KEY=XtnB6bgxQBLBZTL77KBBGAZHdrWQ8Iwjz60Cgh1R7zBvCy1cjWfvgkcgANKi2
ADMIN_JWT_ACCESS_EXPIRES=60
ADMIN_JWT_REFRESH_EXPIRES=1

POSTGRESQL_HOST=vuhom-postgres
POSTGRESQL_PORT=5432
POSTGRESQL_USER=vuhom
POSTGRESQL_PASS=<POSTGRES_PASS>
POSTGRESQL_DB_NAME=vuhom

REDIS_HOST=vuhom-redis
REDIS_PORT=6379
REDIS_PASS=XT2qHrzezIGvm5zpW1JYddMP7S67rold

MINIO_IP=fsn1.your-objectstorage.com
MINIO_ACCESS_KEY=5GWLAGFJDOCEJAS28OAQ
MINIO_SECRET_KEY=9w6WNk4Mt4XIdclZlTmtXcwLR2LkIMNGqfRAxMeO
IMAGE_SECRET_KEY=K8T4EilXNtwQCBHs9vEoSAk43AJ43UgV

SMTP_SERVER=smtp.mx.cloudflare.net
EMAIL_SMTP_PORT=465
EMAIL_SENDER_USERNAME=api_token
EMAIL_SENDER_PASSWORD=<cloudflare-email-api-token>
SENDER_EMAIL=noreply@vuhom.com
FROM_ADDRESS=noreply@vuhom.com
EMAIL_PROVIDER=smtp

SMS_PROVIDER=mock
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM_NUMBER=
TWILIO_MESSAGING_SERVICE_SID=

PUSH_PROVIDER=mock
FIREBASE_CREDENTIALS_PATH=
FIREBASE_PROJECT_ID=

RATE_LIMIT_ENABLED=true
RATE_LIMIT_GLOBAL_MAX_REQUESTS=100
RATE_LIMIT_GLOBAL_WINDOW_SECONDS=60

STRIPE_MOCK_MODE=true
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=

GOOGLE_CLIENT_ID_IOS=
GOOGLE_CLIENT_ID_ANDROID=
GOOGLE_CLIENT_ID_WEB=
APPLE_CLIENT_ID_IOS=
APPLE_CLIENT_ID_WEB=
APPLE_TEAM_ID=
FACEBOOK_APP_ID=
FACEBOOK_APP_SECRET=

LOG_TO_FILE=true
LOG_RETENTION_DAYS=7
EOF"
```

- [ ] **Step 2: Verify the critical vars are present**

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 \
  "grep -E '^(POSTGRESQL_HOST|EMAIL_PROVIDER|SMS_PROVIDER|PUSH_PROVIDER|ENVIRONMENT)' /opt/vuhom/api/.env"
```

Expected:
```
POSTGRESQL_HOST=vuhom-postgres
EMAIL_PROVIDER=smtp
SMS_PROVIDER=mock
PUSH_PROVIDER=mock
ENVIRONMENT=production
```

---

## Task 11: First deploy and super admin

At this point main has been updated (Task 6), so either wait for CI/CD to trigger, or deploy manually. Do it manually first to verify everything works before the CI pipeline runs.

- [ ] **Step 1: Pull and restart the API container manually**

First, get a GitHub PAT to authenticate with GHCR (needed if VuHome/API is a private repo):

```bash
GH_PAT=$(gh auth token)
```

Then SSH and deploy:

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "
  echo '$GH_PAT' | docker login ghcr.io -u $(gh api user --jq .login) --password-stdin
  cd /opt/vuhom/api
  docker compose pull
  docker compose up -d --remove-orphans
  docker image prune -f
"
```

If VuHome/API is a **public** repo (packages are public-readable), skip the login line — `docker compose pull` works unauthenticated.

- [ ] **Step 2: Watch container startup logs (Alembic runs here)**

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "docker logs vuhom-api --follow --tail 50"
```

Wait until you see something like:
```
INFO  [alembic.runtime.migration] Running upgrade ...
INFO  [alembic.runtime.migration] Done.
INFO:     Started server process
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8003
```

Press `Ctrl+C` to stop following.

- [ ] **Step 3: Run health check**

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "docker exec vuhom-api curl -sf http://localhost:8003/health"
```

Expected: `{"status":"ok"}` or similar 200 response. If the endpoint doesn't exist yet, check `docker ps` shows `vuhom-api` as healthy.

- [ ] **Step 4: Create super admin**

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "docker exec vuhom-api python -m script.create_super_admin"
```

Expected: output confirming admin created, e.g.:
```
Super admin created: eng.mortezamoafi@gmail.com
```

(Default credentials are in `SUPER_USER` env class: `eng.mortezamoafi@gmail.com` / `!@QW12qw` with force-change-on-first-login.)

- [ ] **Step 5: Verify end-to-end via HTTPS**

```bash
curl -sf https://api.vuhom.com/health
```

Expected: `{"status":"ok"}` — proves Traefik TLS termination + API are working.

- [ ] **Step 6: Trigger a test CI/CD push to confirm automation**

Make a trivial commit to `VuHome/API` main and verify the GitHub Actions workflow runs:

```bash
cd /tmp/vuhom-api
git checkout main
git pull
echo "# Vuhom API" > README_CI_TEST.md
git add README_CI_TEST.md
git commit -m "ci: verify automated pipeline"
git push origin main
```

Then watch:

```bash
gh run watch --repo VuHome/API
```

Expected: both `Build & Push` and `Deploy` jobs complete green.

After confirming, clean up:

```bash
git rm README_CI_TEST.md
git commit -m "chore: remove CI test file"
git push origin main
```

---

## When API keys arrive (post-plan)

Once Twilio/Firebase credentials are ready, update the server `.env` in one SSH command:

```bash
ssh -i ~/.ssh/amirarab root@91.107.169.203 "
  sed -i 's/SMS_PROVIDER=mock/SMS_PROVIDER=twilio/' /opt/vuhom/api/.env
  sed -i 's/PUSH_PROVIDER=mock/PUSH_PROVIDER=firebase/' /opt/vuhom/api/.env
  sed -i 's/TWILIO_ACCOUNT_SID=/TWILIO_ACCOUNT_SID=<value>/' /opt/vuhom/api/.env
  # ... repeat for other Twilio/Firebase vars
  docker restart vuhom-api
"
```
