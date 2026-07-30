---
name: substrait:deploy
description: Deploy the current project to its linked Substrait app (zip upload, or a pushed-branch trigger for GitHub-connected apps)
---

You are deploying the current project to **Substrait**. This plugin bundles a deploy
script that picks the path from the linked app's mode: a **GitHub-connected app** is
deployed by *trigger* — Substrait pulls the pushed branch, so nothing is uploaded and
everything (including `openapi.json` and `substrait.yaml`) must be **committed and
pushed** first — while any other app is zipped (source only) and uploaded. Either way,
`--watch` follows the build until the preview is live.

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

2. **Author the app's OpenAPI spec** — write **`openapi.json` at the project root**
   (next to `backend/` and `substrait.yaml` — commit it, it's part of the code): a
   complete OpenAPI 3.x document you author by studying the backend source. It ships
   inside the deploy and the platform records it as the app's published API
   description — it takes precedence over the platform's runtime harvest, and it's
   what other builders see in the platform's **API Library** (portal **API** tab
   included). Your spec is usually *richer* than the runtime one — frameworks only
   emit response schemas for typed handlers, but you can read what each handler
   actually returns.

   What to write:
   - **Every route the code registers** — method + path (route params in `{param}`
     form), including `/health`. Nothing invented, nothing padded: if it isn't in the
     code, it isn't in the spec.
   - **A real `summary` per operation** — one sentence saying what the endpoint does
     (not a restatement of its path).
   - **Request bodies and parameters** — from the handler signatures/models.
   - **Response schemas** — trace each handler's return value (dict literals, ORM
     rows, serializers) and write the actual field names and types under
     `responses.200.content.application/json.schema`. Share shapes via
     `components/schemas`. Where a field's type is genuinely unknowable from the code,
     leave that field generic rather than guessing — accuracy beats completeness.

   Keep it valid JSON with a top-level `paths` object, under 1 MB. Regenerate the file
   whenever the backend's routes or shapes change — each deploy replaces the whole
   spec, so removed endpoints drop out. If you genuinely cannot read the backend
   (e.g. it's a compiled artifact), skip this step — the platform falls back to
   harvesting the running app's own `/openapi.json` when it serves one. (Legacy: an
   inventory-only `.substrait/endpoints.json` is still accepted when no spec file
   exists.)

   **Also keep the app's description current** — `substrait.yaml` at the project root
   is **required**, with a top-level `description:` (1–3 sentences: what the app does,
   the data it manages, who it's for). Each deploy records it onto the app, and it's
   what teammates see in the portal and the platform's **API Library** — so write it
   from what the app *actually does now*, and update it when the app's purpose grows.
   A missing file, a missing description, or leftover scaffold placeholder text fails
   the deploy's validation (the script pre-checks this locally). Create the file with
   just the `description:` key if the app declares no backing services — but if the
   app already uses redis/kafka/qdrant, keep them declared under `services:`.

3. **Commit and push first if the app is GitHub-connected.** For a connected app the
   deploy builds the **pushed branch**, not your working tree — so after writing or
   regenerating `openapi.json` / `substrait.yaml`, commit everything and push to the
   connected branch before deploying. The script refuses to trigger from a dirty tree,
   the wrong branch, or an unpushed HEAD, and the server independently verifies the
   commit SHA — if it reports a mismatch, push (or pull a teammate's newer commits) and
   re-run. Do not try to work around these gates; they exist so the platform never
   builds code you didn't validate. (Zip-deployed apps skip this step — the zip carries
   the working tree directly.)

4. **Deploy** from the project root:
   `bash <plugin>/scripts/substrait-deploy.sh --watch`
   The script runs a **compliance preflight** before deploying anything — it halts if
   the repo isn't Substrait-compliant (missing backend Dockerfile, a
   `frontend/` with no frontend Dockerfile, a stray `k8s/`, or a missing/placeholder
   `substrait.yaml` description). If it reports a
   compliance failure, relay the exact message and help the user fix the repo; do not
   try to bypass it.
   For zip deploys the script also auto-detects the **backend stack**
   (fastapi/python/node/go/rust/…) from
   the project and records it on the app as a label — the platform is stack-agnostic, so
   this only affects what's shown in the portal. If the guess is wrong, pass
   `--stack <name>` (e.g. `--watch --stack go`). Connected apps ignore `--stack` — the
   platform detects the stack from the repo itself.
   If the script warns that the **spec is stale** (`openapi.json` older than backend
   changes), stop and regenerate it from the current backend source before deploying —
   the file ships with the deploy and becomes the app's published API description, so
   a stale one publishes wrong schemas.

5. **Report the outcome:** the run number and, on success, the live preview URL. If the
   script reports a failure, surface the HTTP status / message and suggest checking the
   portal logs for that run — do not retry automatically.

Note: for zip deploys the script enforces the 16 MB source-only limit and excludes
`node_modules/`, `.venv/`, `dist/`, build output and `.git/`. If it reports the zip is
too large, help the user find and exclude the offending large files rather than
bypassing the check.
