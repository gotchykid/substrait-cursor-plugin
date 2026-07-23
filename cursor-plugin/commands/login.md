---
name: substrait:login
description: Authenticate this machine with your Substrait account (mints the personal access token)
---

You are authenticating the user's machine with the **Substrait** platform: a one-time
**account authorization** that mints a **personal access token** (`sbt_…`) and stores it
in `~/.substrait/config.json`. It is machine-wide — every project on this machine can
then browse the API Library (`/substrait:library`), bind itself to an app
(`/substrait:link`), and deploy (`/substrait:deploy`) without any per-project secret.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin) and run the scripts
from there.

1. **Check whether the machine is already authenticated:** run
   `bash <plugin>/scripts/substrait-link.sh whoami`.
   This verifies the stored token against the portal and prints who it authenticates.
   If it succeeds, tell the user they're already logged in (as whom) and stop — unless
   they explicitly want to re-authenticate or switch accounts, in which case continue.

2. **Browser authorization (preferred):**
   `bash <plugin>/scripts/substrait-link.sh account`
   This opens the Substrait portal in the user's browser, where they (already logged in
   there) **authorize Cursor on their account** — the personal token is minted and
   returned to the CLI automatically, no copy/paste. The command prints a URL and a short
   verification code; relay both to the user in case the browser didn't open, and tell
   them to complete the authorization in the browser. It blocks until they approve.
   - Only on a **self-hosted** Substrait portal, pass `--portal-url <URL>`.

3. **Headless / CI fallback.** If there is no browser on this machine: the user mints a
   personal token on the portal's **Access tokens** page (Settings), then
   `bash <plugin>/scripts/substrait-link.sh save-account --token <TOKEN>`
   (add `--portal-url <URL>` only for self-hosted). Ask **only for the token**; never
   echo it back in plain text. The script verifies it before saving.

4. **Confirm** with a `whoami` and tell the user what's now unlocked: `/substrait:link`
   to bind a project to an app, `/substrait:library` to browse the API catalog,
   `/substrait:deploy` to ship. This command does **not** bind the current project to
   any app — that's `/substrait:link`.
