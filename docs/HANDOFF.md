# Vuhom — Infrastructure & Codebase Handoff

**Last updated:** 2026-06-23  
**Status:** Production live. CI/CD operational. Platform + API + Admin all deployed. Email sending live (Resend). SMS configured (Twilio trial).

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

`admin.vuhom.com` and `api.vuhom.com` resolve via the `*.vuhom.com` wildcard — no separate records needed. Cloudflare proxy is intentionally OFF. Traefik handles TLS directly.

Cloudflare also runs **Email Routing** on `vuhom.com` and `lotusion.com` (MX = `route1/2/3.mx.cloudflare.net`). See the Email section below.

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
  admin/         ← React/Vite admin panel (nginx)
    docker-compose.yml
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
| `vuhom-api` | ghcr.io/vuhome/api:latest | 8003 | FastAPI, Celery worker embedded → api.vuhom.com |
| `vuhom-platform` | ghcr.io/vuhome/platform:latest | 3000 | Next.js → vuhom.com |
| `vuhom-admin` | ghcr.io/vuhome/admin:latest | 80 | React/Vite + nginx → admin.vuhom.com |
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
SMTP_SERVER=smtp.resend.com
EMAIL_SMTP_PORT=587
EMAIL_SENDER_USERNAME=resend
EMAIL_SENDER_PASSWORD=<resend api key>
SENDER_EMAIL=noreply@vuhom.com
FROM_ADDRESS=noreply@vuhom.com

SMS_PROVIDER=twilio         ← LIVE (Twilio trial). See SMS section.
TWILIO_ACCOUNT_SID=<set on server>
TWILIO_AUTH_TOKEN=<set on server>
TWILIO_MESSAGING_SERVICE_SID=<set on server, MG...>
TWILIO_FROM_NUMBER=         ← intentionally empty; code uses messaging_service_sid
PUSH_PROVIDER=mock          ← switch to "firebase" when keys arrive

STRIPE_MOCK_MODE=true       ← switch to false when keys arrive

ALLOW_ORIGINS=https://vuhom.com,https://www.vuhom.com,https://admin.vuhom.com
```

### Auth flow — phone signup

Phone numbers use `phonenumbers` library (E.164 normalization). Only Canadian numbers are allowed (`ALLOWED_ISOS = {"ca"}`). The `validate_phone_number()` function in `modules/auth/schema.py` normalizes to E.164 (`+1XXXXXXXXXX` format) before storing in Redis OTP cache. All lookups (signup → verify) must use the same normalized format.

### Email — two separate systems

**Receiving (inbound mail to @vuhom.com / @lotusion.com):** Cloudflare Email Routing.
Catch-all (`*@`) forwards to `amirarabsalmani75@gmail.com`. MX records are
`route1/2/3.mx.cloudflare.net` (CF-managed/locked — you cannot edit MX while routing is on;
disable routing first if you must). Cloudflare Email Routing is **receive-only** — it CANNOT send.

**Sending (app transactional email — OTP, welcome, etc.):** Resend (`smtp.resend.com:587`, STARTTLS).
`modules/notifications/providers/email_provider.py` picks the transport by port:
- Port 587 → `smtplib.SMTP` + `starttls()` (STARTTLS) ← what we use
- Port 465 → `smtplib.SMTP_SSL` (implicit SSL) ← **blocked outbound on Hetzner, do not use**

Status: **LIVE.** `vuhom.com` is verified in Resend (account `it@lotusion.com`). The app sends
from `noreply@vuhom.com`; OTP delivery is confirmed. Resend DNS on Cloudflare: `resend._domainkey`
(DKIM TXT), `send` MX → `feedback-smtp.us-east-1.amazonses.com`, `send` TXT → amazonses SPF.
These coexist with Cloudflare Email Routing (which owns the apex MX) — no conflict.

Prior provider **Abrino** (abrino.email) is fully removed from DNS and code.

### Notification providers

| Provider | Env var | Current | Notes |
|---|---|---|---|
| Email | `EMAIL_PROVIDER` | `smtp` (Resend) | LIVE |
| SMS | `SMS_PROVIDER` | `twilio` | LIVE (trial — see below) |
| Push | `PUSH_PROVIDER` | `mock` | Set `firebase` + `FIREBASE_*` vars |

**SMS (Twilio) — LIVE, trial account.** Configured 2026-06-23. Account SID + Auth Token +
Messaging Service SID (`MG...`) are set on the server. `TWILIO_FROM_NUMBER` is left **empty on
purpose**: `modules/notifications/providers/sms_provider.py` uses `messaging_service_sid` when
present and ignores `from_number`. The Twilio account (name "vuhom") is a **TRIAL** — it can only
text **verified caller IDs** (currently `+14165248181`). To text arbitrary users, **upgrade the
Twilio account** (add funds); no code/env change needed after upgrade.

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

## Admin Panel

**Repo:** `VuHome/admin` (default branch `develop`; `main` is the deploy branch)  
**Framework:** React 18 + Vite + TypeScript, TanStack Query, Tailwind + shadcn/ui  
**Served by:** nginx (multi-stage Docker build → static bundle)  
**Image:** `ghcr.io/vuhome/admin:latest`  
**URL:** `https://admin.vuhom.com`

The API base URL (`https://api.vuhom.com`) is **baked in at build time** via the
`VITE_API_BASE_URL` build-arg in the Dockerfile / CI workflow — it is NOT a runtime env var.
To change it, edit the `build-args` in `.github/workflows/ci-cd.yml` and rebuild.

**Deploy key:** the admin repo has its OWN deploy key (`vuhom-admin-deploy`, generated 2026-06-23)
because the API/platform private key wasn't retrievable (only stored as a GitHub secret). Its
public key is in the server's `~/.ssh/authorized_keys`; the private key is the repo's
`SSH_DEPLOY_KEY` secret. `DEPLOY_HOST` secret = `91.107.169.203`.

**Login flow:** email OTP. The UI calls `POST /admin/auth/setotp {identifier: email}` → API caches
an OTP and emails it (via Resend) → user submits code to `POST /admin/auth/otplogin`. Log in with
the super admin `eng.mortezamoafi@gmail.com`; the OTP arrives in that inbox.

**Two bugs fixed 2026-06-23 to make login work:**
1. API 500 — the `/admin/auth/setotp` route was missing its `db` dependency (every other admin
   auth route had `db: AsyncSession = Depends(db_session)`). Added it + passed `db=db` to the service.
2. CORS — `admin.vuhom.com` wasn't in the API's `ALLOW_ORIGINS`. Added it on the server `.env`.

---

## Users on Server

| User | Access | SSH Key |
|---|---|---|
| `root` | Full | Amir's personal key + deploy key |
| `morteza` | sudo | `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzTAXQBLanIJhdJMwobnpUwM0qsqBWDxo504azb/oih morteza@morteza-pc` |

---

## Pending

**Waiting on user action:**
- **Twilio upgrade** — SMS is configured and working, but the account is a **trial** (texts only
  verified numbers). Upgrade the Twilio account (add funds) to text arbitrary users. No env change needed.
- **`h.asadnia@gmail.com`** — added as a second Cloudflare Email Routing destination but must click
  its verification email. Until then, both domains' catch-all forwards to `amirarabsalmani75@gmail.com`
  only. After verification, add it to both catch-all rules' forward `value` array.

**Waiting on keys not yet received** (set in `/opt/vuhom/api/.env`, then restart):
- **Firebase (push):** `FIREBASE_CREDENTIALS_PATH`, `FIREBASE_PROJECT_ID` → then set `PUSH_PROVIDER=firebase`
- **Stripe:** `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` → then set `STRIPE_MOCK_MODE=false`
- **Social auth:** `GOOGLE_CLIENT_ID_IOS`, `GOOGLE_CLIENT_ID_ANDROID`, `GOOGLE_CLIENT_ID_WEB`, `APPLE_CLIENT_ID_IOS`, `APPLE_TEAM_ID`

Restart after any `.env` change: `cd /opt/vuhom/api && docker compose up -d`

---

## Secrets & Credentials — where they live

**Never commit secrets.** They live in two places only:
1. **Server** `/opt/vuhom/*/.env` files (api, db, admin, platform) — the source of truth for runtime.
2. **Local** `DevOps/cf-data.txt` and `DevOps/resend-data.txt` — the Cloudflare and Resend tokens,
   used for API-driven DNS/domain management. These are **gitignored** (`.gitignore` has `*.txt`,
   `cf-data.txt`, `*-data.txt`). Cloudflare and GitHub auto-revoke tokens exposed in commits — this
   already happened once, do not repeat it.

**Cloudflare:** account ID `26b112f83fd08941cf1a78dcb644266c`. Zones: `vuhom.com` =
`b1ae590a620ffac77279e895107c051a`, `lotusion.com` = `8134f73f1f928ce6be0b75bab8548059`. The API
token is **account-scoped** — verify it via `GET /accounts/{id}/tokens/verify`, NOT
`/user/tokens/verify` (that returns "Invalid" for account-scoped tokens even when valid).

**Resend:** account email `it@lotusion.com` (forwards to Gmail via our routing). `vuhom.com` domain
id `0df3fba0-78b0-49b2-afd7-26e8b28969f5`, verified. Use a **full-access** key to manage domains;
the app only needs a send-key in `EMAIL_SENDER_PASSWORD`.

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

**Why Resend for sending + Cloudflare for receiving?** Cloudflare Email Routing is free and already on the domain, but it only *receives/forwards* — it cannot send. A dedicated transactional provider is required for app email. Resend was chosen: free tier (3,000/month), simple DKIM setup, and `smtp.resend.com:587` is reachable from Hetzner (port 465 is blocked outbound there). The earlier assumption that `smtp.mx.cloudflare.net` could send was wrong — it is an inbound MX host only.
