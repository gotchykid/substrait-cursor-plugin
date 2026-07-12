---
name: substrait:deploy
description: Package the current project (source only) and deploy it to its linked Substrait app
---

You are deploying the current project to **Substrait**. This plugin bundles a deploy
script that zips the project (source only), uploads it to the app this project is
linked to, and (with `--watch`) follows the build until the preview is live.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-deploy.sh` under the installed `substrait` Cursor plugin) and run the scripts
from there. They self-locate their shared helper, so they only need to be invoked by path.
**Always prefix script invocations with `SUBSTRAIT_MEMO_FILE=AGENTS.md`** — the scripts
maintain a project-memory block and Cursor reads `AGENTS.md`, not the default `CLAUDE.md`.

1. **Check the link:** run `bash <plugin>/scripts/substrait-link.sh status`.
   If this project isn't linked, stop and tell the user to run `/substrait:link` first.
   Deploys are authorised either by the machine's account link (personal token + this
   project's bound app slug) or by an app-scoped deploy token saved in the project —
   linking sets up whichever the user chose.

2. **Generate the endpoint inventory** — only when the backend serves no OpenAPI spec.
   After each deploy goes live, the platform harvests the app's own spec
   (`/openapi.json` or `/api/openapi.json` — FastAPI serves one by default) and that
   takes precedence, so for those backends **skip this step**. For stacks without a
   spec (plain Go/Node/etc. routers), study the backend source (routes, routers,
   controllers — whatever the stack uses) and write **`.substrait/endpoints.json`**
   listing every HTTP endpoint the backend serves. The deploy script submits this file
   to Substrait after the upload, and the portal shows it on the app's **API** tab.
   Exact shape:

   ```json
   {
     "endpoints": [
       {"method": "GET", "path": "/api/items", "description": "List items"},
       {"method": "POST", "path": "/api/items", "description": "Create an item"},
       {"method": "GET", "path": "/health", "description": "Readiness probe"}
     ]
   }
   ```

   Rules: `method` is one of GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS, `WS` for websocket
   routes, or `*` for catch-alls; `path` starts with `/` and keeps route parameters in
   the framework-neutral `{param}` form (≤ 200 chars, no whitespace); `description` is
   one short sentence (≤ 300 chars, optional); at most 300 endpoints. List concrete
   routes the code actually registers — don't invent or pad. Regenerate the file on
   every deploy (the server replaces the whole inventory, so removed endpoints drop
   out). If you genuinely cannot read the backend (e.g. it's a compiled artifact),
   skip this step — the script deploys fine without the file.

3. **Deploy** from the project root:
   `bash <plugin>/scripts/substrait-deploy.sh --watch`
   The script runs a **compliance preflight** before packaging — it halts (without
   uploading) if the repo isn't Substrait-compliant (missing backend Dockerfile, a
   `frontend/` with no frontend Dockerfile, or a stray `k8s/`). If it reports a
   compliance failure, relay the exact message and help the user fix the repo; do not
   try to bypass it.
   The script also auto-detects the **backend stack** (fastapi/python/node/go/rust/…) from
   the project and records it on the app as a label — the platform is stack-agnostic, so
   this only affects what's shown in the portal. If the guess is wrong, pass
   `--stack <name>` (e.g. `--watch --stack go`).
   If the script warns that the **endpoint inventory is stale** (older than backend
   changes), the deploy itself is unaffected — regenerate `.substrait/endpoints.json`
   from the current backend source, then resubmit without redeploying:
   `bash <plugin>/scripts/substrait-deploy.sh endpoints`

4. **Report the outcome:** the run number and, on success, the live preview URL. If the
   script reports a failure, surface the HTTP status / message and suggest checking the
   portal logs for that run — do not retry automatically.

Note: the script enforces the 16 MB source-only limit and excludes `node_modules/`,
`.venv/`, `dist/`, build output and `.git/`. If it reports the zip is too large, help the
user find and exclude the offending large files rather than bypassing the check.
