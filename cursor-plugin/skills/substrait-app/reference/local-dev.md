# Running a Substrait app locally

Local dev is **not** part of the deploy contract — the platform builds your images,
provisions OceanBase, runs Flyway, and applies the k8s manifests in a sandbox. None of
that runs on your machine. The commands below assume the default **FastAPI + Vite**
scaffold; on another stack, run the backend however that stack runs (still on `:8000`,
reading `DATABASE_URL`) and keep the one piece that's the same for everyone: a
**MySQL-wire database**.

## The database: use MySQL/MariaDB, not SQLite

Production is **OceanBase**, which speaks the **MySQL wire protocol**. A local MySQL (or
MariaDB) container is therefore a *faithful* stand-in — the exact same things run
unchanged:

- the `asyncmy` driver and connection pattern in `backend/main.py`
- the `%s` query placeholders
- the Flyway migrations in `backend/resources/db/migration/V*.sql` (MySQL dialect)

**SQLite is a trap here.** It's a different driver (`aiosqlite`), different placeholders
(`?`), and a different SQL dialect — the scaffold's `BIGINT AUTO_INCREMENT` /
`DEFAULT CHARSET=utf8mb4` migrations won't even apply. You'd maintain two dialects and
test against a database that behaves differently from production, which defeats the point
of local testing. Stick with a MySQL-wire DB.

## Fast loop (recommended): containerized DB, native backend + frontend

Run the database in Docker (so migrations stay faithful) but run the backend and
frontend natively for hot reload.

```bash
# 1. Database — MySQL on localhost:3306, db name "app"
docker compose up -d db

# 2. Apply your Flyway migrations (same as the platform does on deploy)
docker compose run --rm migrate

# 3. Backend — FastAPI with reload on :8000
cd backend
python -m venv .venv && source .venv/bin/activate   # or: uv venv && source .venv/bin/activate
pip install -r requirements.txt                      # or: uv pip install -r requirements.txt
DATABASE_URL="mysql://root:root@localhost:3306/app" uvicorn main:app --reload --port 8000

# 4. Frontend — Vite dev server on :5173, proxying /api -> :8000
cd frontend
npm install
npm run dev
```

Open the Vite URL (http://localhost:5173). The app calls `/api/hello`, which the Vite
proxy forwards to the backend — same-origin, exactly like production behind the ingress.

`docker compose` here refers to `docker-compose.yml` at the project root (provided by the
scaffold). It defines just `db` (MySQL) and `migrate` (a one-shot Flyway runner). The
platform ignores this file on upload — it only reads `cicd/`, `backend/` and `frontend/`.

## Already have a MySQL-wire database?

Skip `docker-compose.yml` entirely and point `DATABASE_URL` at any MySQL-compatible
server — e.g. a local TiDB on `:4000` or an existing OceanBase. Run your migrations
against it (`flyway -url=jdbc:mysql://HOST:PORT/DB ... migrate`) and start the backend
with that `DATABASE_URL`.

## Environment variables locally

- `DATABASE_URL` — set it yourself as above (the platform injects it in prod).
- `JWT_SECRET` — set it in your shell only if your app reads it.
- Backing services from `substrait.yaml` (`REDIS_URL`, `KAFKA_BROKERS`, `QDRANT_URL`) —
  run a local equivalent and export the var. The scaffold's `docker-compose.yml` ships
  commented-out `redis`, `kafka` (Redpanda) and `qdrant` services that match what the
  platform provisions — uncomment the ones your manifest declares, then e.g.
  `export REDIS_URL=redis://localhost:6379/0`, `KAFKA_BROKERS=localhost:9092`,
  `QDRANT_URL=http://localhost:6333`.
- Custom config from `backend/.env.example` — export the ones you need, or `source` a
  local `.env` (don't commit real secrets).

## Notes

- The backend tolerates a missing `DATABASE_URL` (the `/api/items` routes return a
  "DATABASE_URL not set" note), so you can run the API without a DB for quick UI work —
  but anything touching tables needs the database up and migrated.
- This local setup is convenience only; the deploy contract in `deploy-contract.md` is
  what actually governs a successful upload.
