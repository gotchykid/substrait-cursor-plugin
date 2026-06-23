# Substrait deploy contract — full reference

You upload **app code plus its Dockerfile(s)**. Your app builds from its **own**
Dockerfile, so the contract is behavioural — a container that `EXPOSE`s 8000 and serves
`GET /health` — not stack-locked to FastAPI. The platform owns **only the Kubernetes
manifests**: it mints the slug and binds namespace, image and ingress host, so you never
write k8s or deal with the slug. The k8s manifests are never committed into your repo;
they're materialised at deploy time. The worker:

1. **VALIDATING** — extracts the zip (zip-slip safe) and validates your app against this
   contract (a backend Dockerfile is required; a frontend one too when you ship `frontend/`).
2. **REPO_INIT** — creates a private GitHub repo and force-pushes your code as-is
   (your Dockerfiles included; no k8s manifests added).
3. **BUILDING → MIGRATING → DEPLOYING → SMOKE_TEST → PREVIEW_LIVE** — a build Job
   clones the repo and builds **your** Dockerfile (kaniko); Flyway runs your migrations;
   then the platform renders its k8s manifests (slug + image bound) and applies them.

## What goes in the zip

| Path | Required | Notes |
|------|----------|-------|
| `cicd/Dockerfile.backend` (or `cicd/Dockerfile` / `backend/Dockerfile`) | ✅ | builds the backend image; must `EXPOSE 8000`, serve `GET /health` and the API under **`/api`** |
| `cicd/Dockerfile.frontend` (or `frontend/Dockerfile`) | ✅ when `frontend/` present | builds the SPA image; serves the built bundle on **port 80** |
| `cicd/nginx.conf` | with the scaffold's frontend Dockerfile | serves the SPA; referenced by `Dockerfile.frontend` |
| `backend/main.py` | scaffold | the scaffold's Dockerfile runs `uvicorn main:app` on port 8000; serves `GET /health` and its API under **`/api`** |
| `backend/requirements.txt` | scaffold | your backend deps (installed by your Dockerfile) |
| `backend/.env.example` (or root `.env.example`) | optional | declares custom env vars + secrets; the platform pre-creates them in the app's Settings. Mark secrets with a trailing `# secret` |
| `backend/resources/db/migration/V*.sql` (or `resources/db/migration`) | optional | Flyway, MySQL/OceanBase dialect |
| `frontend/` | optional | React + Vite + Tailwind; **deployed** alongside the backend (see Full-stack below) |

**Do not** include `k8s/` — anything you put there is discarded and replaced by the
platform's manifests. You **do** ship the `cicd/` Dockerfiles; the platform no longer
generates one.

## You own the Dockerfile; the platform owns only k8s (no `__APP_SLUG__` to manage)

The platform generates the k8s manifests from internal templates, fills in the slug it
mints from your display name, and binds the app to its namespace, image and ingress
host. **You write none of that and never reference the slug.** Your Dockerfile, by
contrast, is yours — start from the scaffold's `cicd/Dockerfile.backend` and edit it
freely, as long as the image still `EXPOSE`s 8000 and serves `GET /health`.

### Wheels-only by default

The scaffold's `cicd/Dockerfile.backend` installs deps with
`pip install --only-binary=:all:`. The base is `python:3.12-slim`, which has no C
compiler, so a dep with no wheel for this Python would otherwise fall back to a source
build and die deep in a cryptic compile (surfaced as a `BackoffLimitExceeded` build
failure). `--only-binary` makes that fail fast and legibly instead. If you genuinely
need a source build, pin a version that ships a wheel, or add the toolchain
(`apt-get install -y gcc …`) and drop the flag.

### Build context depends on where the Dockerfile lives

- `cicd/Dockerfile.backend` / `cicd/Dockerfile` is built with the **repo root** as the
  context, so its `COPY` paths are repo-root-relative: `COPY backend/requirements.txt .`,
  `COPY backend/ .` (this is what the scaffold ships).
- `backend/Dockerfile` is built with **`backend/` as the context** — write it like a
  standalone service Dockerfile: `COPY requirements.txt .`, `COPY . .`.

If a `COPY`/`ADD` source can't be found in that context, the deploy is rejected up front
with a clear message rather than failing deep inside the image build.

## Build resource ceiling (heavy deps)

The image is built by kaniko on GKE Autopilot, which caps build scratch space at
**10Gi ephemeral storage per build** (the platform requests the max). The base image,
your `pip install` downloads, the installed `site-packages`, and kaniko's layer
snapshots all share that 10Gi — a build whose installed footprint exceeds it is
**evicted** mid-build (surfaced as `kaniko-… failed (BackoffLimitExceeded): Evicted:
… ephemeral local storage usage exceeds …`).

The usual culprit is **GPU PyTorch**: `torch` (often pulled transitively by
`sentence-transformers` / `transformers`) defaults to the CUDA build, dragging in
~6 GB of `nvidia-*` wheels that don't fit — and the cluster has no GPUs anyway. Pin the
**CPU-only** build instead, e.g. in your `backend/Dockerfile`:

```dockerfile
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir -r requirements.txt
```

(or add `--extra-index-url https://download.pytorch.org/whl/cpu` and pin `torch==X.Y.Z+cpu`).

## Full-stack: one host, path-based routing

The app deploys as full-stack into one sandbox namespace behind **one ingress host**:

- **`/api`** → the backend service.
- **everything else** → the frontend (the SPA).

So the backend **must serve its HTTP API under `/api`** (e.g. `/api/users`), and the
frontend calls the API **same-origin via relative `/api` paths** — no API URL is baked
into the bundle (the scaffold's `cicd/Dockerfile.frontend` builds with `VITE_API_URL=""`).
That Dockerfile builds the Vite bundle and serves it via nginx on port 80; the platform
deploys `<slug>-frontend` beside `<slug>-backend`. If you ship no `frontend/`, only the
backend is deployed (and you need no frontend Dockerfile).

### Build-time frontend env vars (`frontend/.env.production`)

Vite inlines `import.meta.env.VITE_*` at **build time**, but the portal's env vars
(`.env.example` → app Settings) are injected into the **backend at runtime only** — they
never reach the Vite build. So a `VITE_GOOGLE_CLIENT_ID` set in the portal will be
`undefined` in the shipped bundle. To set build-time frontend vars, commit a
**`frontend/.env.production`** file: your `cicd/Dockerfile.frontend` runs
`npm run build` in production mode, so Vite auto-loads it and inlines the values.

```
# frontend/.env.production — build-time, PUBLIC-ONLY values
VITE_GOOGLE_CLIENT_ID=1234567890-abc.apps.googleusercontent.com
VITE_SENTRY_DSN=https://abc@o0.ingest.sentry.io/0
```

> ⚠️ **PUBLIC values only — never secrets.** Unlike `backend/.env.example` (whose values
> you fill in privately in the portal and are injected at backend runtime), everything in
> `frontend/.env.production` is **committed to git AND baked into the shipped JS bundle**,
> which any visitor can read. Put only non-secret, publishable config here (OAuth *client*
> IDs, public DSNs, analytics keys, feature flags). API keys, client *secrets*, tokens →
> `backend/.env.example`, proxied through your backend.

- **Leave `VITE_API_URL` unset — use relative `/api` paths.** The scaffold's
  `cicd/Dockerfile.frontend` sets `ENV VITE_API_URL=""` before `npm run build`, and that
  process env beats `.env` files, so any `VITE_API_URL` you put in `.env.production` is
  **silently ignored**. Keep it that way so the SPA hits the backend same-origin via the ingress.
- **`.gitignore` gotcha:** most real Vite projects ship a `.gitignore` containing `.env`
  or `.env*`, which would silently drop this file so it never reaches the build. If your
  `.gitignore` ignores env files, explicitly un-ignore this one:
  ```gitignore
  .env*
  !.env.production
  ```
  (The Substrait scaffold's `frontend/.gitignore` already keeps `.env.production` tracked.)
- Changing a value here requires a **re-upload / rebuild** (it's compiled into the bundle).
  This is the right home for config that changes rarely; for values you want to rotate
  without a rebuild, fetch them at runtime from a backend endpoint instead.

## Runtime contract

- Backend is **FastAPI** in the scaffold; the contract itself is behavioural (any stack
  that meets the points below works, since you own the Dockerfile).
- Listen on **port 8000**; serve **`GET /health`** (200, the readiness probe) and your
  API under **`/api`** (so the ingress routes it to the backend).
- Database is **always OceanBase** — the platform provisions a per-app OceanBase DB and
  injects `DATABASE_URL`. There is no other database option (no Postgres/SQLite).
- Read secrets from env (injected via the `app-secrets` Secret):
  - `DATABASE_URL` — OceanBase (MySQL-wire), `mysql://user:pass@host:2881/db`. Use
    `asyncmy` + `%s` placeholders. **Not** PostgreSQL — no `asyncpg`, no `$1`.
  - `REDIS_URL`
  - `JWT_SECRET`
- Declare your app's **own** config (API keys, flags, third-party creds) in
  `backend/.env.example`: one `NAME=value` per line, a trailing `# secret` to mark a
  secret. On upload the platform pre-creates these under the app's Settings (prefilled
  with the example value) for the user to fill in. Don't list the platform-injected
  keys above; read your vars at runtime via `os.getenv`. Re-uploading only adds new
  keys — it never overwrites values already set in the portal.
- All DDL in Flyway migrations — never in application code.
- Source only in the zip: exclude `node_modules/`, `.venv/`, `dist/`,
  `__pycache__/`, build output. Max size 16 MB (default).
- Frontend (optional) standard stack is **React + Vite + Tailwind CSS** — see
  `reference/templates/frontend/`. Ship `cicd/Dockerfile.frontend` (+ `cicd/nginx.conf`)
  with it; it serves the SPA on port 80. Call the API with relative `/api` paths.
- Build-time frontend config (`VITE_*`) goes in a committed **`frontend/.env.production`**
  (public, non-secret values only — it's baked into the JS bundle). Leave `VITE_API_URL`
  unset (the frontend Dockerfile forces `""`). See *Build-time frontend env vars* above.

## Pre-upload checklist

- [ ] `cicd/Dockerfile.backend` (or another backend Dockerfile) is present — `EXPOSE 8000`, serves `GET /health`, API under `/api`.
- [ ] If `frontend/` is present, `cicd/Dockerfile.frontend` (+ `cicd/nginx.conf`) is shipped too — serves the SPA on port 80.
- [ ] Backend deps install wheels-only (`--only-binary=:all:`), or you've added the toolchain for any source-built dep.
- [ ] Backend API routes are under `/api` (so the ingress routes them to the backend).
- [ ] Frontend (if any) calls the API via relative `/api` paths, not an absolute URL.
- [ ] Build-time `VITE_*` vars (if any) are in a committed `frontend/.env.production` — public values only, no secrets, and `VITE_API_URL` is left unset. If `.gitignore` ignores `.env*`, it un-ignores `.env.production`.
- [ ] No `k8s/` (the platform owns it).
- [ ] Schema changes only in `backend/resources/db/migration/V*.sql`.
- [ ] Custom env vars/secrets declared in `backend/.env.example` (secrets marked `# secret`); no real secret values committed.
- [ ] Secrets read from env, none committed.
- [ ] Zip is source-only and under 16 MB.
