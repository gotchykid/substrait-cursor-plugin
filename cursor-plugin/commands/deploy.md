---
name: substrait:deploy
description: Package the current project (source only) and deploy it to its linked Substrait app
---

You are deploying the current project to **Substrait**. This plugin bundles a deploy
script that zips the project (source only), uploads it to the app the project's deploy
token is bound to, and (with `--watch`) follows the build until the preview is live.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-deploy.sh` under the installed `substrait` Cursor plugin) and run the scripts
from there. They self-locate their shared helper, so they only need to be invoked by path.

1. **Check the link:** run `bash <plugin>/scripts/substrait-link.sh status`.
   If this project isn't linked, stop and tell the user to run `/substrait:link` first
   (deploys are authorised by the app-scoped token saved during linking).

2. **Deploy** from the project root:
   `bash <plugin>/scripts/substrait-deploy.sh --watch`

3. **Report the outcome:** the run number and, on success, the live preview URL. If the
   script reports a failure, surface the HTTP status / message and suggest checking the
   portal logs for that run — do not retry automatically.

Note: the script enforces the 16 MB source-only limit and excludes `node_modules/`,
`.venv/`, `dist/`, build output and `.git/`. If it reports the zip is too large, help the
user find and exclude the offending large files rather than bypassing the check.
