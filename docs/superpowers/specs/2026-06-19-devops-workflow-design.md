# Vuhom DevOps Workflow — Design Spec
**Date:** 2026-06-19  
**Status:** Approved

---

## Goal

`main` = production on both API and platform repos. Push to `main` triggers build → GHCR push → SSH deploy to the Vuhom Hetzner server (`91.107.169.203`). Full server rebuild: PostgreSQL replaces MySQL, redesign branch becomes main.

---

## 1. Git Merges

### API (`VuHome/API`)
- `redesign` is 122 commits ahead of `main`. `main` is 8 commits that don't exist in `redesign` — all stale old code.
- Strategy: **reset `main` to `redesign`** (force-push `redesign` HEAD onto `main`). No merge commit noise — `redesign` IS the new main.
- Delete `redesign` branch after.

### Platform (`VuHome/platform`)
- `develop` is 2 ahead, 1 behind `main` (diverged). The 2 ahead commits: "fix" and "add splash screen for pwa and icons".
- Strategy: **merge `develop` → `main`** (merge commit). Keep `develop` branch for ongoing work.

---

## 2. API CI/CD Workflow

Replace the broken self-hosted workflow in `.github/workflows/ci-cd.yml` on `main`.

**Trigger:** push to `main` only  
**Runner:** `ubuntu-latest` (no self-hosted dependency)

**Jobs:**

### `build-push`
1. Checkout
2. Set up Docker Buildx
3. Login to GHCR with `GITHUB_TOKEN`
4. Build and push `ghcr.io/vuhome/api:latest`
5. Registry cache (`type=registry,ref=ghcr.io/vuhome/api:cache`)

### `deploy`
Depends on `build-push`.  
1. SSH into `${{ secrets.DEPLOY_HOST }}` as `root` using `${{ secrets.SSH_DEPLOY_KEY }}`
2. On the server:
   ```bash
   echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
   cd /opt/vuhom/api
   docker compose pull
   docker compose up -d --remove-orphans
   docker image prune -f
   ```

**GitHub Actions secrets required** (same as platform — likely already set):
- `DEPLOY_HOST` — `91.107.169.203`
- `SSH_DEPLOY_KEY` — private key for root on the server

**Remove:** old `.drone.yml` and `.drone.yml.bak` files.

---

## 3. API Dockerfile Fix

The `redesign` Dockerfile has a bug: `HEALTHCHECK` and `EXPOSE` reference port `8008`, but the app reads `HTTP_PORT` from env (set to `8003`).

**Fix:** Change healthcheck to use `$HTTP_PORT` env var (or hardcode `8003` to match the production env):
```dockerfile
EXPOSE 8003
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${HTTP_PORT:-8003}/health || exit 1
```

The `CMD` already runs Alembic migrations before starting: `alembic upgrade head && python3 main.py` — no change needed.

---

## 4. DevOps Repo — Docker Compose Updates

All compose files live in `DevOps/docker/` and are deployed to the server at `/opt/vuhom/`.

### `docker/db/docker-compose.yml` — new file
Replace MySQL with PostgreSQL 16:
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

volumes:
  postgres_data:

networks:
  proxy:
    external: true
```

### `docker/api/docker-compose.yml` — already correct
`ghcr.io/vuhome/api:latest`, port 8003, `api.vuhom.com` — no changes needed.

### Remove `docker-compose.mysql.yml` references
The old MySQL compose is only in the API repo itself — the DevOps repo never had a MySQL compose. After merge, the API repo's `docker-compose.mysql.yml` is gone (it doesn't exist on `redesign`).

---

## 5. Server Rebuild

Executed once manually. After this, all future deploys are automated via CI/CD.

### Step 1 — Tear down MySQL
```bash
cd /opt/vuhom/db
docker compose down -v   # -v removes the mysql volume — data is intentionally discarded
```

### Step 2 — Stand up PostgreSQL
```bash
mkdir -p /opt/vuhom/db
# copy new docker-compose.yml from DevOps repo
echo "POSTGRES_PASS=<generated>" > /opt/vuhom/db/.env
docker compose -f /opt/vuhom/db/docker-compose.yml up -d
```

### Step 3 — Update API .env
New vars to add/update at `/opt/vuhom/api/.env`:
```
# PostgreSQL (replaces MySQL)
POSTGRESQL_HOST=vuhom-postgres
POSTGRESQL_PORT=5432
POSTGRESQL_USER=vuhom
POSTGRESQL_PASS=<same as POSTGRES_PASS above>
POSTGRESQL_DB_NAME=vuhom

# Notification providers (switch from mock when keys arrive)
EMAIL_PROVIDER=smtp
SMS_PROVIDER=mock          # → twilio when TWILIO_* vars are set
PUSH_PROVIDER=mock         # → firebase when FIREBASE_* vars are set

# Placeholders — fill when keys arrive
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM_NUMBER=
TWILIO_MESSAGING_SERVICE_SID=
FIREBASE_CREDENTIALS_PATH=
FIREBASE_PROJECT_ID=

# New in redesign
ENVIRONMENT=production
ROOT_PATH=
RATE_LIMIT_ENABLED=true
```
Remove the `MYSQL_*` vars.

### Step 4 — Deploy API
```bash
cd /opt/vuhom/api
docker compose pull   # pulls ghcr.io/vuhome/api:latest (built from redesign/main)
docker compose up -d --remove-orphans
```
Alembic runs automatically in the container CMD and creates all tables.

### Step 5 — Create super admin
```bash
docker exec vuhom-api python -m script.create_super_admin
```

---

## 6. Platform — No Server Changes Needed

Platform's CI/CD is already correct (`ubuntu-latest`, SSH deploy, `/opt/vuhom/platform`). After merging `develop` → `main`, the next push will trigger the existing workflow automatically.

---

## Secrets Checklist

These must exist in **both** `VuHome/API` and `VuHome/platform` GitHub repos (platform already has them; API needs them added):

| Secret | Value |
|--------|-------|
| `DEPLOY_HOST` | `91.107.169.203` |
| `SSH_DEPLOY_KEY` | root private key for Vuhom server |

---

## Out of Scope (this spec)

- Twilio/Firebase credentials — added to `.env` manually when keys arrive; set `SMS_PROVIDER=twilio` / `PUSH_PROVIDER=firebase` then.
- Social auth keys (Google, Apple) — empty strings for now, won't break startup.
- Stripe — `STRIPE_MOCK_MODE=true` default is fine until keys arrive.
- Staging/dev environment — only production target in this spec.
