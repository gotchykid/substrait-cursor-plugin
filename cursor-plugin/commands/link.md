---
name: substrait:link
description: Link this project to a Substrait app (account link — pick or create the app right here)
---

You are linking the current working directory to one app on the **Substrait** platform so
the user can deploy it with `/substrait:deploy`. Two credential models exist:

- **Account link (preferred):** a **personal access token** (`sbt_…`) stored once per
  machine (`~/.substrait/config.json`). It authenticates the user; each project then just
  records **which app** it deploys to (a slug in `.substrait/config.json`, no secret).
- **Per-app deploy token** (`sbd_…`, the original flow): scoped to a single app, stored in
  the project. Still fully supported — and it wins over the account token if both exist.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin) and run the scripts from
there. They self-locate their shared helper, so they only need to be invoked by path.
**Always prefix script invocations with `SUBSTRAIT_MEMO_FILE=AGENTS.md`** — the scripts
maintain a project-memory block and Cursor reads `AGENTS.md`, not the default `CLAUDE.md`.

1. **Check current state:** run `bash <plugin>/scripts/substrait-link.sh status`.
   It reports both layers: whether this machine has an account link, and what this project
   is bound to. If the project is already linked and the user only wanted to check, you're
   done.

2. **Ensure the account link (once per machine).** If status says there's no account link
   (also available standalone as `/substrait:login`):
   `bash <plugin>/scripts/substrait-link.sh account`
   This opens the Substrait portal in the user's browser, where they (already logged in)
   **authorize Cursor on their account** — the personal token is minted and returned to
   the CLI automatically, no copy/paste. The command prints a URL and a short verification
   code; relay both to the user in case the browser didn't open, and tell them to complete
   the authorization in the browser. It blocks until they approve.
   - Only on a **self-hosted** Substrait portal, pass `--portal-url <URL>`.
   - Headless / CI fallback: the user mints a token on the portal's **Access tokens**
     page, then `bash <plugin>/scripts/substrait-link.sh save-account --token <TOKEN>`.
     Ask **only for the token**; never echo it back in plain text.

3. **Bind this project to an app.** With the account link in place:
   - List the user's apps: `bash <plugin>/scripts/substrait-link.sh apps`
     (prints `slug<TAB>display name` lines). Show them to the user and ask which app this
     project should deploy to — or whether to create a new one.
   - Existing app: `bash <plugin>/scripts/substrait-link.sh use --app <SLUG>`
   - New app:      `bash <plugin>/scripts/substrait-link.sh create --name "<NAME>"`

4. **Per-app token fallback.** If the user prefers a token scoped to one app (shared
   machines, CI secrets):
   - Browser flow: `bash <plugin>/scripts/substrait-link.sh login` (pick the app in the
     browser; the `sbd_…` token is fetched automatically).
   - Paste flow: mint on the app's **Deploy** tab, then
     `bash <plugin>/scripts/substrait-link.sh save --token <TOKEN>` (add
     `--portal-url <URL>` only for self-hosted).

5. **Confirm** the linked app + preview URL, and remind the user they can now run
   `/substrait:deploy` to ship the current code.

Note: on a successful link, the script also records a **"Substrait deployment" section
in the project's `AGENTS.md`** (creating the file if needed; that's why the
`SUBSTRAIT_MEMO_FILE=AGENTS.md` prefix matters) so every future session knows the deploy
contract without loading the skill. It's a marker-delimited block the plugin keeps
current on later deploys; deleting the whole block opts the project out — don't re-add
it by hand if the user removed it.
