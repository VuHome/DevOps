# Vuhom — Infrastructure & Codebase Handoff

**Last updated:** 2026-06-19  
**Status:** Production live. CI/CD operational.

---

## What This Is

Vuhom (internal name: Lotus) is a Canadian super-app for home services, home rental, and roommate matching. This document is the single source of truth for a future engineer or AI agent picking up this codebase. Everything relevant — including decisions made, things that broke, how they were fixed, and what's still pending — is here.

---

## Infrastructure

### Server

| Property | Value |
|---|---|
| Provider | Hetzner Cloud |
| Type | cx43 |
| Location | fsn1 (Germany) |
| Primary SSH IP | `91.107.169.203` |
| Floating IP (DNS) | `78.46.253.50` |
| OS | Ubuntu 24.04 |
| SSH user | `root` |

All deploy operations use the primary IP `91.107.169.203`. The floating IP `78.46.253.50` is DNS-only — attached to loopback via `/etc/netplan/60-floating-ip.yaml`.

### DNS (Cloudflare)

| Record | Points to | Proxy |
|---|---|---|
| `vuhom.com` | `78.46.253.50` | DNS-only |
| `*.vuhom.com` | `78.46.253.50` | DNS-only |

Cloudflare proxy is intentionally OFF. Traefik handles TLS directly.

### S3 — Hetzner Object Storage (fsn1)

Endpoint: `https://fsn1.your-objectstorage.com`  
Signature version: `S3v4` (required by Hetzner)  
Region: `us-east-1` (hardcoded in boto3 client, Hetzner ignores it)

| Bucket | Access | Purpose |
|---|---|---|
| `vuhom-profile` | public-read | User profile images |
| `vuhom-listing` | public-read | Listing images |
| `vuhom-operator` | public-read | Operator documents |
| `vuhom-tfstate` | private | Terraform remote state |

### GitHub

Org: `VuHome`  
Repos: `API`, `platform`, `DevOps`, `admin`, `Front-End-Old`

Push to `main` on API or platform triggers auto-deploy via GitHub Actions.

### IaC

Terraform state in `vuhom-tfstate` S3 bucket. Config in `DevOps/terraform/`.

---

## Server Layout

```
/opt/vuhom/
  api/           ← FastAPI app
    docker-compose.yml
    .env          ← secrets, NEVER commit
  platform/      ← Next.js app
    docker-compose.yml
    .env
  db/            ← Postgres + Redis
    docker-compose.yml
    .env          ← POSTGRES_PASS, REDIS_PASS
  traefik/       ← Reverse proxy
    docker-compose.yml
    dynamic.yml   ← routing rules (file provider, no Docker socket)
    certs/        ← LE certs managed by Traefik
```

Docker network: `proxy` (external, all services attached)

---

## Running Containers

| Container | Image | Port | Notes |
|---|---|---|---|
| `traefik` | traefik:v3.3 | 80, 443 | File provider — no Docker socket |
| `vuhom-api` | ghcr.io/vuhome/api:latest | 8003 | FastAPI, Celery worker embedded |
| `vuhom-platform` | ghcr.io/vuhome/platform:latest | 3000 | Next.js |
| `vuhom-postgres` | postgres:16-alpine | 5432 | DB |
| `vuhom-redis` | redis:7-alpine | 6379 | Cache, Celery broker |

### Why no Docker socket for Traefik?

Docker 28.x broke Traefik's Docker provider (API version incompatibility). Fixed by switching to file provider: routes defined in `/opt/vuhom/traefik/dynamic.yml`. **When adding a new service, update `dynamic.yml` both on the server AND in `DevOps/docker/traefik/dynamic.yml` in the repo.**

---

## CI/CD

Both API and platform use identical GitHub Actions patterns.

**Trigger:** push to `main`  
**Runner:** `ubuntu-latest`  
**Steps:** checkout → Buildx → login GHCR → build+push image → SSH deploy  

**Deploy secrets** (set in repo Settings → Secrets → Actions):

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | `91.107.169.203` |
| `SSH_DEPLOY_KEY` | Private key at `~/.ssh/vuhom-deploy` on server |

Deploy key public key is at `~/.ssh/vuhom-deploy.pub` on the server. It is already authorized in `~/.ssh/authorized_keys`.

On deploy:
1. Pull new image from GHCR
2. `docker compose up -d --remove-orphans`
3. Prune old images

---

## API Codebase

**Repo:** `VuHome/API`  
**Language:** Python 3.11  
**Framework:** FastAPI  
**Port:** 8003  
**Image:** `ghcr.io/vuhome/api:latest`

### Startup sequence (lifespan in http_server.py)

1. Redis connect
2. MinIO/S3 initialize (non-fatal if fails)
3. PostgreSQL connect
4. Celery worker start

Alembic migrations run in Docker CMD before uvicorn: `alembic upgrade head && python3 main.py`

### Key env vars on server (`/opt/vuhom/api/.env`)

```
ENVIRONMENT=production
USE_HTTPS=false            ← Traefik handles TLS, API sees plain HTTP
WORKERS=1                  ← 1 uvicorn worker; Celery runs embedded
HTTP_PORT=8003

POSTGRESQL_HOST=vuhom-postgres
POSTGRESQL_PORT=5432
POSTGRESQL_USER=vuhom
POSTGRESQL_PASS=<set on server>
POSTGRESQL_DB_NAME=vuhom

REDIS_HOST=vuhom-redis
REDIS_PORT=6379
REDIS_PASS=<set on server>

MINIO_IP=fsn1.your-objectstorage.com
MINIO_ACCESS_KEY=<hetzner s3 key>
MINIO_SECRET_KEY=<hetzner s3 secret>

EMAIL_PROVIDER=smtp
SMTP_SERVER=smtp.mx.cloudflare.net
EMAIL_SMTP_PORT=465
EMAIL_SENDER_USERNAME=api_token
EMAIL_SENDER_PASSWORD=<cloudflare email api token>
SENDER_EMAIL=noreply@vuhom.com
FROM_ADDRESS=noreply@vuhom.com

SMS_PROVIDER=mock           ← switch to "twilio" when keys arrive
PUSH_PROVIDER=mock          ← switch to "firebase" when keys arrive

STRIPE_MOCK_MODE=true       ← switch to false when keys arrive
```

### Auth flow — phone signup

Phone numbers use `phonenumbers` library (E.164 normalization). Only Canadian numbers are allowed (`ALLOWED_ISOS = {"ca"}`). The `validate_phone_number()` function in `modules/auth/schema.py` normalizes to E.164 (`+1XXXXXXXXXX` format) before storing in Redis OTP cache. All lookups (signup → verify) must use the same normalized format.

### Email provider — port 465 vs 587

`modules/notifications/providers/email_provider.py` detects the port:
- Port 465 → `smtplib.SMTP_SSL` (implicit SSL, Cloudflare's SMTPS)
- Port 587 → `smtplib.SMTP` + `starttls()` (STARTTLS)

The server `.env` uses port 465 with Cloudflare. This is correct.

### Notification providers

| Provider | Env var | Current | Switch to production |
|---|---|---|---|
| Email | `EMAIL_PROVIDER` | `smtp` | Already production |
| SMS | `SMS_PROVIDER` | `mock` | Set `twilio` + `TWILIO_*` vars |
| Push | `PUSH_PROVIDER` | `mock` | Set `firebase` + `FIREBASE_*` vars |

When switching SMS: `SMS_PROVIDER=twilio`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `TWILIO_MESSAGING_SERVICE_SID`

When switching push: `PUSH_PROVIDER=firebase`, `FIREBASE_CREDENTIALS_PATH`, `FIREBASE_PROJECT_ID`

### Celery

Runs embedded in the API container (not a separate container). Queues: `logging`, `notifications`, `default`. Beat scheduler runs for retry fallback. With `WORKERS=1`, there is exactly one Celery worker — no contention.

If `WORKERS` is ever increased beyond 1, move Celery to a separate container to prevent duplicate task processing.

### Super admin

Created with `docker exec vuhom-api python -m script.create_super_admin`

| Field | Value |
|---|---|
| Email | `eng.mortezamoafi@gmail.com` |
| Password | `!@QW12qw` |
| Force change on first login | Yes |

To override defaults, set `SUPER_ADMIN_EMAIL`, `SUPER_ADMIN_PASSWORD`, etc. in `.env` before running the script.

---

## Platform Codebase

**Repo:** `VuHome/platform`  
**Framework:** Next.js  
**Port:** 3000  
**Image:** `ghcr.io/vuhome/platform:latest`

CI/CD: same pattern as API. Deploy key same.

---

## Users on Server

| User | Access | SSH Key |
|---|---|---|
| `root` | Full | Amir's personal key + deploy key |
| `morteza` | sudo | `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzTAXQBLanIJhdJMwobnpUwM0qsqBWDxo504azb/oih morteza@morteza-pc` |

---

## Pending (keys not yet received)

These are placeholder env vars waiting for real credentials. Set them in `/opt/vuhom/api/.env` on the server, then restart the container.

- **Twilio (SMS):** `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `TWILIO_MESSAGING_SERVICE_SID` → then set `SMS_PROVIDER=twilio`
- **Firebase (push):** `FIREBASE_CREDENTIALS_PATH`, `FIREBASE_PROJECT_ID` → then set `PUSH_PROVIDER=firebase`
- **Stripe:** `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` → then set `STRIPE_MOCK_MODE=false`
- **Social auth:** `GOOGLE_CLIENT_ID_IOS`, `GOOGLE_CLIENT_ID_ANDROID`, `GOOGLE_CLIENT_ID_WEB`, `APPLE_CLIENT_ID_IOS`, `APPLE_TEAM_ID`

Restart after any `.env` change: `cd /opt/vuhom/api && docker compose up -d`

---

## Known Issues / Technical Debt

1. **Node.js 20 deprecation in CI/CD** — GitHub Actions `actions/checkout@v4` etc. use Node 20 which is deprecated. Non-blocking. Pin to v5 of affected actions when convenient.

2. **Dockerfile CMD uses shell form** — `CMD alembic upgrade head && python3 main.py` should be JSON array form for proper signal handling: `CMD ["sh", "-c", "alembic upgrade head && python3 main.py"]`. Non-blocking.

3. **`utils/email_sender.py`** — legacy file used by `modules/user/services/admin_service.py` only. Not connected to the Celery/template notification system. Contains hardcoded HTML. Should be migrated to the template system eventually.

4. **`modules/notifications/env_updated.py`** — leftover development file, appears to be a draft of `utils/env.py`. Not imported anywhere active. Can be deleted.

5. **Traefik file provider** — adding a new service requires editing `dynamic.yml` on the server AND in the DevOps repo. There's no auto-discovery. This is intentional (Docker socket issue) but worth documenting.

6. **`APPLE_CLIENT_ID_WEB` hardcoded default** — `utils/env.py` has a Google OAuth client ID as the default for `APPLE_CLIENT_ID_WEB`. This is a copy-paste error in the original code. Override via env var when Apple Sign-In is set up.

---

## Quick Operations Reference

```bash
# SSH to server
ssh root@91.107.169.203

# View API logs
docker logs vuhom-api -f --tail 100

# Restart API after .env change
cd /opt/vuhom/api && docker compose up -d

# Manual deploy (force pull latest image)
cd /opt/vuhom/api && docker compose pull && docker compose up -d --remove-orphans

# Check health
curl https://api.vuhom.com/health

# Run Alembic migration manually (if needed)
docker exec vuhom-api alembic upgrade head

# View Postgres
docker exec -it vuhom-postgres psql -U vuhom -d vuhom

# View Redis
docker exec -it vuhom-redis redis-cli -a <REDIS_PASS>

# Create super admin
docker exec vuhom-api python -m script.create_super_admin

# Check CI/CD status
# GitHub → VuHome/API → Actions
```

---

## Architecture Decisions Made

**Why PostgreSQL not MySQL?** MySQL was the original choice but was replaced in the infra rebuild (2026-06-19). PostgreSQL has better async driver support (asyncpg), better JSON handling, and is standard for FastAPI + SQLAlchemy stacks.

**Why Traefik file provider?** Docker 28.x broke Traefik's Docker socket provider. File provider is explicit and predictable — each route is defined in `dynamic.yml`.

**Why embedded Celery?** Single container simplicity for the current scale. Move to separate container if `WORKERS > 1` or if task throughput becomes a bottleneck.

**Why Hetzner S3 not AWS S3?** Cost. Hetzner fsn1 object storage is in the same datacenter as the server, so egress is free between services.

**Why Cloudflare email routing?** The domain is already on Cloudflare. `noreply@vuhom.com` routes through Cloudflare's SMTP relay (`smtp.mx.cloudflare.net:465`). No separate email service needed at current scale.
