---
name: substrait-app
version: 2026.06.26.124603
description: Build apps that deploy on the Substrait platform via upload mode. Use whenever the user asks to build, scaffold, or package an app "for Substrait", "to upload to Substrait", or for the Substrait upload/deploy contract. The zip contains app code plus its Dockerfile(s) — a backend/ that serves GET /health on port 8000 (FastAPI in the scaffold) with a cicd/Dockerfile.backend and Flyway migrations, plus an optional React+Vite+Tailwind frontend/ with a cicd/Dockerfile.frontend. The platform generates only the Kubernetes manifests, so you never write k8s or deal with the app slug.
---

# Substrait upload-mode apps

Substrait deploys an uploaded `.zip` to a sandbox namespace by building the backend
image, running Flyway migrations, and applying the k8s manifests. You upload **app code
plus its Dockerfile(s)** — your app builds from its **own** Dockerfile, so the contract
is behavioural (a container that EXPOSEs 8000 and serves `GET /health`), not stack-locked.
The platform generates **only the Kubernetes manifests** and binds them to the slug it
mints. Your job: generate the app code and its Dockerfile(s); do **not** generate k8s.

## The deploy contract (non-negotiable)

Produce this layout at the zip root (start from `reference/templates/`):

```
cicd/
  Dockerfile.backend                       # REQUIRED — builds the backend image (EXPOSE 8000, GET /health)
  Dockerfile.frontend                      # REQUIRED when you ship frontend/ — builds the SPA image (port 80)
  nginx.conf                               # serves the built SPA; referenced by Dockerfile.frontend
backend/                                   # backend application code (FastAPI in the scaffold)
  main.py                                  # the scaffold Dockerfile runs `uvicorn main:app`, port 8000, GET /health
  requirements.txt                         # backend deps
  .env.example                             # OPTIONAL — declare custom env vars + secrets (prefilled in the portal)
  resources/db/migration/V*.sql            # OPTIONAL — Flyway migrations (MySQL/OceanBase dialect)
frontend/                                  # OPTIONAL — React + Vite + Tailwind (deployed with the backend)
docker-compose.yml                         # OPTIONAL — local-dev DB + Flyway runner; ignored by the platform
```

**Do NOT generate `k8s/`** — the platform owns it; any `k8s/` you include is discarded.
You **do** ship the `cicd/` Dockerfiles; the platform no longer generates one.

Hard rules — violating any of these fails validation or the deploy:

1. **Ship a backend Dockerfile** (`cicd/Dockerfile.backend`, `cicd/Dockerfile`, or
   `backend/Dockerfile`). It must `EXPOSE 8000`, serve **`GET /health`** (200, the
   readiness probe), and expose the API under **`/api`** (the ingress routes `/api` to
   the backend; everything else goes to the frontend, or to the backend when you ship no
   `frontend/` — see "Frontend" below). The scaffold's backend is FastAPI, but any stack
   meeting this contract works.
2. **Ship a frontend Dockerfile** (`cicd/Dockerfile.frontend` or `frontend/Dockerfile`)
   **whenever you include `frontend/`** — it must serve the built SPA on **port 80**.
3. **Build deps wheels-only.** The scaffold's `cicd/Dockerfile.backend` uses
   `pip install --only-binary=:all:` so a dep with no wheel fails fast and legibly on the
   compiler-less slim base, instead of dying in a cryptic source build. Need a source
   build? Pin a version that ships a wheel, or add the toolchain and drop the flag.
4. **Never write k8s manifests or reference the app slug.** The platform generates the
   manifests and fills in the slug, namespace, image and ingress host for you.
5. **All DDL goes in Flyway migrations** (`backend/resources/db/migration/V*.sql`,
   MySQL/OceanBase dialect) — never create tables from application code.
6. **Source only.** Exclude `node_modules/`, `.venv/`, `dist/`, `__pycache__/`, and
   build artifacts. Max zip size is 16 MB by default.

## Runtime environment

The database is **always OceanBase** — the platform provisions a per-app OceanBase
database and injects `DATABASE_URL`. There is no other database option; do not assume
or configure Postgres/SQLite/etc.

Secrets are injected via the `app-secrets` Kubernetes Secret — read them from env:

- `DATABASE_URL` — OceanBase, **MySQL-wire compatible** (`mysql://user:pass@host:2881/db`).
  Use a **MySQL** driver, never PostgreSQL (no `asyncpg`, no `$1`).
  - **Python (scaffold):** `asyncmy` with `%s` placeholders — see
    `reference/templates/backend/main.py`.
  - **Go / other stacks:** `DATABASE_URL` is a `mysql://` **URL** — convert it to your
    driver's DSN. For Go's `go-sql-driver/mysql` you must wrap the address in `tcp(...)`;
    a bare `host:port` fails at startup with `default addr for network '…:2881' unknown`.
    Full snippet + a Go backend Dockerfile: `reference/deploy-contract.md` → *Connecting
    from Go & other stacks*.
- `REDIS_URL`
- `JWT_SECRET`

Never commit secrets; always read from the environment.

## Declaring custom env vars & secrets

Your app's own config — API keys, feature flags, third-party credentials — goes in a
**`backend/.env.example`** (root `.env.example` also works). On upload the platform
parses it and **pre-creates each entry** under the app's Settings (Environment
variables / Secrets), so the user just fills in real values in the portal. Format:

```
APP_GREETING=Hello from Substrait     # env var, prefilled with "Hello from Substrait"
THIRD_PARTY_API_KEY=     # secret      ← mark a secret with a trailing "# secret"
```

- One `NAME=value` per line; the value is the prefilled placeholder (may be empty).
- Add a trailing `# secret` to store it write-only (masked in the portal).
- Do **not** list `DATABASE_URL`, `REDIS_URL` or `JWT_SECRET` — the platform injects those.
- Read them at runtime via `os.getenv("NAME")`; never commit real secret values.
- Re-uploading only adds new keys — it never overwrites a value the user has set in the portal.

## Frontend (full-stack)

A frontend is optional but, when present, is **deployed alongside the backend** in the
same sandbox namespace behind **one ingress host**: `/api` → backend, everything else →
frontend. The standard stack is **React + Vite + Tailwind CSS** — start from
`reference/templates/frontend/`.

If you ship **no `frontend/`**, the platform routes *all* traffic (including `/`) to the
backend, so a backend-only app must serve its own root/pages itself — a pure-API backend
will return its own 404 on `/` (the app is reachable, just rootless). No frontend
Dockerfile is needed in that case.

Call the backend **same-origin via relative `/api` paths** (e.g. `fetch("/api/...")`).
Do **not** hardcode an absolute API URL — the scaffold's `cicd/Dockerfile.frontend`
builds the bundle with `VITE_API_URL=""` so relative paths hit the backend through the
ingress, then serves it via nginx on port 80. Ship that Dockerfile alongside `frontend/`.

**Build-time frontend env vars (`VITE_*`).** Vite inlines `import.meta.env.VITE_*` at
build time, but the portal's env vars are injected into the **backend at runtime only** —
they never reach the Vite build. To set build-time frontend vars (e.g. an OAuth client
ID), commit a **`frontend/.env.production`**; the platform runs `npm run build` in
production mode, so Vite auto-loads it. Three rules:

- ⚠️ **Public, non-secret values only.** It's committed to git *and* baked into the JS
  bundle every visitor downloads. Secrets (API keys, client *secrets*) → `backend/.env.example`.
- **Never set `VITE_API_URL`** — it's platform-managed (forced to `""`); a value here is
  silently ignored. Use relative `/api` paths.
- If your `.gitignore` ignores `.env*`, un-ignore this file: add `!.env.production`.

See `reference/deploy-contract.md` → *Build-time frontend env vars* for the full rationale.

## Running locally

Local dev is **not** part of the deploy contract, but the scaffold is locally runnable.
Because production is **OceanBase (MySQL-wire)**, use a local **MySQL/MariaDB** so the
`asyncmy` driver, `%s` placeholders and Flyway migrations all run unchanged — **not
SQLite** (different driver, placeholders and dialect; the migrations won't apply). The
scaffold ships a root `docker-compose.yml` (a `db` + one-shot `migrate` service) and the
frontend's `vite.config.js` proxies `/api` → `:8000`, so dev is same-origin like prod:

```bash
docker compose up -d db && docker compose run --rm migrate   # MySQL + migrations
cd backend  && DATABASE_URL="mysql://root:root@localhost:3306/app" uvicorn main:app --reload
cd frontend && npm install && npm run dev                     # Vite proxies /api -> :8000
```

The platform ignores `docker-compose.yml` on upload. Already have a MySQL-wire DB (e.g. a
local TiDB on `:4000`)? Skip the compose file and point `DATABASE_URL` at it. See
`reference/local-dev.md` for the full guide.

## Workflow

1. Scaffold `backend/`, the `cicd/` Dockerfiles (and optionally `frontend/`) from `reference/templates/`.
2. Write the app in `backend/` (FastAPI on port 8000, `GET /health`, API under `/api`).
3. Build the UI in `frontend/`, calling the API via relative `/api` paths.
4. Put every schema change in a new `backend/resources/db/migration/V*.sql`.
5. List any custom config the app reads from env in `backend/.env.example` (mark secrets `# secret`).
6. Ship the `cicd/` Dockerfile(s); do **not** create `k8s/` — the platform generates only that.
7. When asked to package: zip the project root, source only.

See `reference/deploy-contract.md` for the full spec, `reference/local-dev.md` for
running locally, and `reference/templates/` for copy-paste-ready files.

## Updating this skill

This skill ships inside the **`substrait` Cursor plugin** (it's the plugin's bundled
skill, alongside the `/substrait:link` and `/substrait:deploy` commands). Update it the
way you update any Cursor plugin — from the marketplace you installed it from (the
`substrait` plugin in the `gotchykid/substrait-cursor-plugin` marketplace).

The plugin doesn't self-update, but a `sessionStart` hook checks once a day (fail-silent)
whether a newer version is published and, if so, nudges you to update — it never changes
any files itself.
