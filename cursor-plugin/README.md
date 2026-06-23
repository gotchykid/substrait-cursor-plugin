# Substrait plugin for Cursor

Build apps to the Substrait upload/deploy contract and ship them without leaving the
editor. The plugin bundles:

- the **`substrait-app`** skill — scaffolds a contract-compliant app (FastAPI `backend/`
  on port 8000, `cicd/` Dockerfiles, optional React+Vite+Tailwind `frontend/`, Flyway
  migrations); and
- two commands:
  - **`/substrait:link`** — link this project to one of your apps. Opens the portal in your
    browser so you pick the app while logged in; the app-scoped deploy token is fetched
    automatically (no copy/paste). Falls back to pasting a token for headless/CI.
  - **`/substrait:deploy`** — package the project (source only) and deploy it to the linked
    app (`--watch` to follow the build).

## Install

In Cursor, add the marketplace and install the plugin:

```
gotchykid/substrait-cursor-plugin
```

(Cursor → Plugins/Marketplace → add the `gotchykid/substrait-cursor-plugin` repo → install
the `substrait` plugin.)

## Set up & deploy

1. In your project, run `/substrait:link`. It opens the portal in your browser (you're
   already logged in), where you **pick the app** to link — the deploy token is minted for
   that app and returned to the CLI automatically. The app must already exist.
2. Run `/substrait:deploy` to ship (add `--watch` to follow the build to the live URL).

**Headless / CI?** If there's no browser, mint a token by hand: portal → your app → its
**Deploy** tab → **Create deploy token**, copy the `sbd_…` value (shown once), then run
`/substrait:link` and paste it.

Config is **per project** in `./.substrait/config.json` (chmod 600, gitignored) — portal
URL + the app-scoped token. You can override with `SUBSTRAIT_PORTAL_URL` / `SUBSTRAIT_TOKEN`
in the environment.

## Maintainers

**This repository is published, not edited here.** It is generated from canonical sources
in the Substrait monorepo and pushed by `scripts/publish-cursor.sh`:

- `skills/substrait-app/` is assembled from `portal-backend/app/resources/` by
  `scripts/sync-cursor.sh` (the same sources the portal, agent-runner, and the Claude Code
  plugin build from).
- `scripts/substrait-{common,link,deploy}.sh` are the editor-agnostic bash scripts copied
  verbatim from the Claude Code plugin (`substrait-plugin/scripts/`) by the same sync.
- the Cursor-specific glue (`.cursor-plugin/plugin.json`, `commands/`, `hooks/hooks.json`,
  `scripts/substrait-update-check-cursor.sh`) is authored in the monorepo under
  `cursor-plugin/`.

To ship a change, edit the sources in the monorepo, run `bash scripts/sync-cursor.sh`, then
`bash scripts/publish-cursor.sh`. Direct commits here will be overwritten on the next
publish.
