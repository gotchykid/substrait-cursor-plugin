---
name: substrait:link
description: Link this project to a Substrait app (browser flow — pick the app while logged in)
---

You are linking the current working directory to one app on the **Substrait** platform so
the user can deploy it with `/substrait:deploy`. A Substrait **deploy token** is scoped to a
single app; the link flow obtains one for the app the user chooses.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin) and run the scripts from
there. They self-locate their shared helper, so they only need to be invoked by path.

1. **Check current state:** run `bash <plugin>/scripts/substrait-link.sh status`.
   If it's already linked and the user only wanted to check, you're done.

2. **Link via the browser (default).** Run:
   `bash <plugin>/scripts/substrait-link.sh login`
   This opens the Substrait portal in the user's browser, where they (already logged in)
   **pick the app** to link. The deploy token is minted for that app and returned to the
   CLI automatically — no copy/paste. The command prints a URL and a short verification
   code; relay both to the user in case the browser didn't open, and tell them to complete
   the authorization in the browser. The command blocks until they approve, then confirms
   the linked app + preview URL.
   - Only on a **self-hosted** Substrait portal, pass `--portal-url <URL>`.

3. **Headless / CI fallback (paste a token).** If there's no browser (CI, a remote shell),
   the user can mint a token by hand instead:
   - In the portal, open the app → the **Deploy** tab → **Create deploy token**, copy the
     `sbd_…` value (shown once).
   - Then: `bash <plugin>/scripts/substrait-link.sh save --token <TOKEN>`
     (add `--portal-url <URL>` only for self-hosted). Ask the user **only for the token**;
     never echo it back in plain text.

4. **Confirm** the linked app + preview URL, and remind the user they can now run
   `/substrait:deploy` to ship the current code.
