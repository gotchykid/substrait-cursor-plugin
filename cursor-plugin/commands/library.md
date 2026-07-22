---
name: substrait:library
description: Browse the Substrait API Library and design an app against existing APIs
---

You are helping the user discover what data/APIs already exist on the **Substrait**
platform and — if they want — design a new app that consumes them. The **API Library**
is a design-time catalog with two kinds of entries:

- **`internal`** — company APIs registered by platform admins, each with a full
  OpenAPI spec, a base URL and `auth_notes` describing how to get access.
- **`app`** — deployed Substrait apps' endpoint inventories (method/path/description
  plus the app's `https://<slug>.apps.substrait.build` base URL).

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-library.sh` under the installed `substrait` Cursor plugin) and run the
scripts from there.

Reads need an **account link** (personal access token). If a call fails with 401/403,
run `/substrait:link` and complete the account authorization first.

1. **Fetch the catalog:** run `bash <plugin>/scripts/substrait-library.sh list`
   (optional filters: `--q <term>`, `--tag <tag>`). The output is JSON — parse it and
   present a readable summary grouped by kind: internal company APIs first, then
   deployed apps. Show name, slug, description and endpoint count. Don't dump raw JSON
   at the user.

2. **Explore what's relevant.** Ask what the user wants to build (unless they already
   said), then pull details for the entries that could serve it:
   - `… substrait-library.sh show internal <slug>` or `… show app <slug>` — endpoint
     summary, base URL and (for internal entries) `auth_notes`.
   - For deep questions about an internal API (request/response shapes, parameters):
     `… substrait-library.sh spec <slug> --out .substrait/specs/<slug>.json`
     then read/grep the file — full specs can be large, so never print one to the
     conversation wholesale.

3. **Design the app together.** Iterate with the user until the design is concrete:
   - which library APIs it consumes, and which specific endpoints;
   - data flow: what the app stores in its own database vs fetches live;
   - configuration: one env var per consumed API base URL, plus whatever credentials
     each entry's `auth_notes` describes. **The platform brokers nothing at runtime** —
     the app calls these APIs directly, and the user configures credentials as env
     vars on the app's Settings page after deploy (secrets belong in
     `backend/.env.example` with a `# secret` marker, never in code).
   - what the app itself exposes (its own API + frontend).

4. **Build and ship.** When the user is happy with the design, use the `substrait-app`
   skill to scaffold and implement it (the design maps onto the standard backend +
   frontend + migrations layout), then `/substrait:link` and `/substrait:deploy`.
