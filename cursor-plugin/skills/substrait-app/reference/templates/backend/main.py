"""Minimal conforming backend for Substrait upload mode (OceanBase / MySQL-wire).

Keep:
  - listening on port 8000
  - GET /health (the readiness probe)
  - API routes under /api (the ingress routes /api here; everything else → frontend,
    or to this backend when no frontend/ is shipped — then serve / yourself)
  - reading DATABASE_URL / JWT_SECRET from the environment (plus REDIS_URL /
    KAFKA_BROKERS / QDRANT_URL for any backing service declared in substrait.yaml)

Database: the platform provisions an **OceanBase** database per app and injects
DATABASE_URL. OceanBase speaks the **MySQL wire protocol** — use the `asyncmy`
driver with `%s` placeholders. It is NOT PostgreSQL: no `asyncpg`, no `$1`.
All DDL lives in Flyway migrations under resources/db/migration/ — never in code.
"""
import os
from contextlib import asynccontextmanager
from urllib.parse import unquote, urlparse

import asyncmy
from fastapi import FastAPI, Request
from pydantic import BaseModel

_pool = None


def _dsn() -> dict:
    # DATABASE_URL looks like: mysql://user%40tenant:password@host:2881/dbname
    u = urlparse(os.environ["DATABASE_URL"])
    return {
        "host": u.hostname,
        "port": u.port or 2881,
        "user": unquote(u.username or ""),
        "password": unquote(u.password or ""),
        "db": (u.path or "/").lstrip("/"),
    }


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _pool
    if os.getenv("DATABASE_URL"):
        _pool = await asyncmy.create_pool(**_dsn(), autocommit=True)
    yield
    if _pool is not None:
        _pool.close()
        await _pool.wait_closed()


app = FastAPI(title="My uploaded app", lifespan=lifespan)

# Custom config you declared in .env.example is injected as env vars (set the real
# values in the portal). Read it with os.getenv, with a sensible default for local dev.
GREETING = os.getenv("APP_GREETING", "Hello")


# Every endpoint declares a response model. That's what makes the app SELF-DESCRIBING:
# FastAPI publishes these field names/types in /openapi.json, which feeds the portal's
# API tab and the API Library other builders design against. A bare `return {...}`
# publishes "object, any fields" — keep responses typed.
class Health(BaseModel):
    status: str


class Message(BaseModel):
    message: str


class Config(BaseModel):
    greeting: str


class Me(BaseModel):
    email: str | None
    user: str | None


@app.get("/health", response_model=Health)
def health():
    return {"status": "ok"}


@app.get("/api/hello", response_model=Message)
def hello():
    return {"message": f"{GREETING} from Substrait"}


@app.get("/api/config", response_model=Config)
def config():
    return {"greeting": GREETING}


@app.get("/api/me", response_model=Me)
def me(request: Request):
    # When the app owner enables Google SSO (the portal's Access tab), the platform's
    # auth proxy injects the signed-in user's identity into every gated request —
    # trustworthy while SSO is on, absent otherwise (public paths, local dev), so
    # treat a missing header as anonymous. The browser never sees these headers;
    # this endpoint is how a frontend asks "who am I?".
    return {
        "email": request.headers.get("x-forwarded-email"),
        "user": request.headers.get("x-forwarded-user"),
    }


class ItemIn(BaseModel):
    name: str


class Item(BaseModel):
    id: int
    name: str
    created_at: str


class ItemList(BaseModel):
    items: list[Item]
    note: str | None = None


class CreateResult(BaseModel):
    ok: bool
    note: str | None = None


@app.get("/api/items", response_model=ItemList)
async def list_items():
    if _pool is None:
        return {"items": [], "note": "DATABASE_URL not set"}
    # OceanBase is MySQL-wire: asyncmy + %s placeholders (never asyncpg / $1).
    async with _pool.acquire() as conn, conn.cursor() as cur:
        await cur.execute("SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT %s", (50,))
        rows = await cur.fetchall()
    return {"items": [{"id": r[0], "name": r[1], "created_at": str(r[2])} for r in rows]}


@app.post("/api/items", status_code=201, response_model=CreateResult)
async def create_item(item: ItemIn):
    if _pool is None:
        return {"ok": False, "note": "DATABASE_URL not set"}
    async with _pool.acquire() as conn, conn.cursor() as cur:
        await cur.execute("INSERT INTO items (name) VALUES (%s)", (item.name,))
    return {"ok": True}
