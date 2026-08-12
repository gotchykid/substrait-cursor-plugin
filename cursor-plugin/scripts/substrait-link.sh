#!/usr/bin/env bash
# Link Claude Code to Substrait — either your ACCOUNT (once per machine) or this
# PROJECT to one app.
#
# Account (personal access token, sbt_ — global ~/.substrait/config.json):
#   account      [--portal-url URL]         browser flow: authorize the CLI as you;
#                                           the personal token is fetched automatically
#   save-account --token TOKEN [--portal-url URL]  fallback: paste an sbt_ token minted
#                                           on the portal's Access tokens page
#   whoami                                  verify the account link against the portal
#                                           and print who it authenticates
# Project (with an account link in place — no per-project secret):
#   apps                                    list your apps (slug + name), to pick from
#   use    --app SLUG                       bind this project to an existing app
#   create --name NAME                      create a new empty app and bind to it
#
# Deploy-mode choice (mode 2 = zip upload, mode 3 = GitHub):
#   modes                                   app state + tenant toggles + recorded choice
#   repos                                   GitHub repos reachable via the App installs
#   set-mode --mode upload|connect [--repo OWNER/REPO] [--branch BR]
#                                           switch the app's deploy path and record it
#                                           in .substrait/config.json (deploy_mode)
#
# Per-app deploy token (sbd_ — the original flow, still supported; the project token
# wins over the account token when both exist):
#   login  [--portal-url URL]               browser flow: pick the app while logged in,
#                                           the deploy token is fetched automatically
#   save   --token TOKEN [--portal-url URL] fallback: paste an sbd_ token (headless/CI)
#
#   status                                  show account link + this project's binding
#
# Project config is ./.substrait/config.json (gitignored): a deploy token binds by
# credential; an account link binds by "slug" only, sent as X-Substrait-App.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

die() { echo "Error: $*" >&2; exit 1; }

# Shown when a config-establishing flow (login/account/save/save-account) runs without an
# explicit portal URL. There is NO default — the URL must be given via --portal-url or
# $SUBSTRAIT_PORTAL_URL (multi-tenant safety: a default would silently target the wrong
# installation). Kept as a constant so the four flows share one wording. Callers use it
# INLINE (not in a $() subshell) so die() actually exits the script.
_PORTAL_REQUIRED_MSG="a portal URL is required — pass --portal-url <your Substrait API URL> (e.g. https://api.substrait.build for the hosted platform, or your tenant/demo URL such as https://api.demo.substrait.build). There is no default."

# _write_config PORTAL TOKEN [SLUG] [HOST] — write .substrait/config.json (0600) and
# make sure .substrait/ is gitignored. SLUG/HOST are cached for friendlier messages.
_write_config() {
  local portal="$1" token="$2" slug="${3:-}" host="${4:-}" mode
  # Preserve a recorded deploy-mode choice across rewrites (set-mode wrote it).
  mode="$(_json_get "$SUBSTRAIT_CONFIG_FILE" deploy_mode 2>/dev/null)" || mode=""
  mkdir -p .substrait
  umask 177
  # Build the JSON by hand (no python): these are values we control — a portal URL, an
  # sbd_ token, a slug and a hostname — none of which contain JSON-special characters.
  { printf '{\n  "portal_url": "%s",\n  "token": "%s"' "${portal%/}" "$token"
    [ -n "$slug" ] && printf ',\n  "slug": "%s"' "$slug"
    [ -n "$host" ] && printf ',\n  "host": "%s"' "$host"
    [ -n "$mode" ] && printf ',\n  "deploy_mode": "%s"' "$mode"
    printf '\n}\n'
  } > "$SUBSTRAIT_CONFIG_FILE"
  chmod 600 "$SUBSTRAIT_CONFIG_FILE"
  if [ -f .gitignore ] && ! grep -qx '.substrait/' .gitignore 2>/dev/null; then
    printf '\n# Substrait CLI link state\n.substrait/\n' >> .gitignore
  elif [ ! -f .gitignore ]; then
    printf '# Substrait CLI link state\n.substrait/\n' > .gitignore
  fi
}

# _write_global_config PORTAL TOKEN — write the account-level ~/.substrait/config.json
# (0600). Holds the personal access token every project on this machine falls back to.
_write_global_config() {
  local portal="$1" token="$2"
  mkdir -p "$(dirname "$SUBSTRAIT_GLOBAL_CONFIG")"
  umask 177
  { printf '{\n  "portal_url": "%s",\n  "token": "%s"\n}\n' "${portal%/}" "$token"
  } > "$SUBSTRAIT_GLOBAL_CONFIG"
  chmod 600 "$SUBSTRAIT_GLOBAL_CONFIG"
}

# _write_project_ref SLUG [HOST] — bind this project to an app WITHOUT a secret (the
# account token authenticates; the slug names the app via X-Substrait-App). Ensures
# .substrait/ is gitignored like _write_config.
_write_project_ref() {
  local slug="$1" host="${2:-}" mode
  # Preserve a recorded deploy-mode choice across rewrites (_bind_project calls this
  # twice — slug-only, then again with the discovered host).
  mode="$(_json_get "$SUBSTRAIT_CONFIG_FILE" deploy_mode 2>/dev/null)" || mode=""
  mkdir -p .substrait
  umask 177
  { printf '{\n  "slug": "%s"' "$slug"
    [ -n "$host" ] && printf ',\n  "host": "%s"' "$host"
    [ -n "$mode" ] && printf ',\n  "deploy_mode": "%s"' "$mode"
    printf '\n}\n'
  } > "$SUBSTRAIT_CONFIG_FILE"
  chmod 600 "$SUBSTRAIT_CONFIG_FILE"
  if [ -f .gitignore ] && ! grep -qx '.substrait/' .gitignore 2>/dev/null; then
    printf '\n# Substrait CLI link state\n.substrait/\n' >> .gitignore
  elif [ ! -f .gitignore ]; then
    printf '# Substrait CLI link state\n.substrait/\n' > .gitignore
  fi
}

# _write_deploy_mode MODE — record the project's chosen deploy path (upload|connect)
# in the project config, preserving every other key. `/substrait:deploy` honors it.
_write_deploy_mode() {
  local mode="$1" portal token slug host
  portal="$(_json_get "$SUBSTRAIT_CONFIG_FILE" portal_url 2>/dev/null)" || portal=""
  token="$(_json_get "$SUBSTRAIT_CONFIG_FILE" token 2>/dev/null)" || token=""
  slug="$(_json_get "$SUBSTRAIT_CONFIG_FILE" slug 2>/dev/null)" || slug=""
  host="$(_json_get "$SUBSTRAIT_CONFIG_FILE" host 2>/dev/null)" || host=""
  mkdir -p .substrait
  umask 177
  { printf '{\n  "deploy_mode": "%s"' "$mode"
    [ -n "$portal" ] && printf ',\n  "portal_url": "%s"' "$portal"
    [ -n "$token" ] && printf ',\n  "token": "%s"' "$token"
    [ -n "$slug" ] && printf ',\n  "slug": "%s"' "$slug"
    [ -n "$host" ] && printf ',\n  "host": "%s"' "$host"
    printf '\n}\n'
  } > "$SUBSTRAIT_CONFIG_FILE"
  chmod 600 "$SUBSTRAIT_CONFIG_FILE"
}

# _account_token — the effective PERSONAL token (env or global config), if any.
# Project-level sbd_ tokens are deliberately excluded: account subcommands must not
# silently run on an app-scoped credential.
_account_token() {
  local t
  if [ -n "${SUBSTRAIT_TOKEN:-}" ] && [ "${SUBSTRAIT_TOKEN#sbt_}" != "$SUBSTRAIT_TOKEN" ]; then
    printf '%s' "$SUBSTRAIT_TOKEN"; return 0
  fi
  if t="$(_json_get "$SUBSTRAIT_GLOBAL_CONFIG" token)" && [ "${t#sbt_}" != "$t" ]; then
    printf '%s' "$t"; return 0
  fi
  return 1
}

cmd_login() {
  local portal=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --portal-url) portal="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  portal="${portal:-${SUBSTRAIT_PORTAL_URL:-}}"; [ -n "$portal" ] || die "$_PORTAL_REQUIRED_MSG"; portal="${portal%/}"

  # 1. Start the device-link flow — get the device_code (our secret) + a user_code/URL.
  substrait_anon_call POST "$portal/api/link/start" || die "could not reach $portal"
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "link start failed (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local start_body="$SUBSTRAIT_BODY"
  local device_code user_code verify_url interval
  device_code="$(printf '%s' "$start_body" | _json_field device_code)" || die "bad start response"
  user_code="$(printf '%s'  "$start_body" | _json_field user_code)"
  verify_url="$(printf '%s' "$start_body" | _json_field verify_url)"
  interval="$(printf '%s'   "$start_body" | _json_field interval)"; interval="${interval:-5}"

  # 2. Send the user to the browser (already logged in there) to pick the app.
  echo "Open this URL to authorize and pick the app to link:"
  echo "    $verify_url"
  echo "Verification code: $user_code"
  substrait_open_url "$verify_url" && echo "(opened in your browser)"
  echo "Waiting for you to authorize in the browser…"

  # 3. Poll until approved (or the request expires server-side -> status:expired).
  local poll_body="$(printf '{"device_code":"%s"}' "$device_code")"
  while :; do
    sleep "$interval"
    substrait_anon_call POST "$portal/api/link/poll" \
      -H "Content-Type: application/json" --data "$poll_body" || continue
    [ "${SUBSTRAIT_STATUS:-}" = "200" ] || continue
    local status; status="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field status)"
    case "$status" in
      approved) break ;;
      pending)  continue ;;
      expired|*) die "link expired or was not approved in time — run /substrait:link again" ;;
    esac
  done

  # 4. Persist the token the browser minted for the chosen app.
  local token slug host
  token="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field token)" || die "no token in approval"
  slug="$(printf '%s'  "$SUBSTRAIT_BODY" | _json_field slug)"
  host="$(printf '%s'  "$SUBSTRAIT_BODY" | _json_field host)"
  _write_config "$portal" "$token" "$slug" "$host"
  substrait_write_memo ensure
  echo "Linked this project to ${slug:-the app}${host:+ (https://$host)}. Run /substrait:deploy to ship it."
}

# ── Account-level linking (personal access token, global config) ────────────────

cmd_account() {
  local portal=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --portal-url) portal="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  portal="${portal:-${SUBSTRAIT_PORTAL_URL:-}}"; [ -n "$portal" ] || die "$_PORTAL_REQUIRED_MSG"; portal="${portal%/}"

  # 1. Start an ACCOUNT-scope device link — the browser will authorize the CLI as the
  #    user (no app picking) and mint a personal access token.
  substrait_anon_call POST "$portal/api/link/start" \
    -H "Content-Type: application/json" --data '{"scope":"account"}' || die "could not reach $portal"
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "link start failed (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local start_body="$SUBSTRAIT_BODY"
  local device_code user_code verify_url interval
  device_code="$(printf '%s' "$start_body" | _json_field device_code)" || die "bad start response"
  user_code="$(printf '%s'  "$start_body" | _json_field user_code)"
  verify_url="$(printf '%s' "$start_body" | _json_field verify_url)"
  interval="$(printf '%s'   "$start_body" | _json_field interval)"; interval="${interval:-5}"

  # 2. Send the user to the browser (already logged in there) to authorize.
  echo "Open this URL to authorize Claude Code on your Substrait account:"
  echo "    $verify_url"
  echo "Verification code: $user_code"
  substrait_open_url "$verify_url" && echo "(opened in your browser)"
  echo "Waiting for you to authorize in the browser…"

  # 3. Poll until approved (or the request expires server-side -> status:expired).
  local poll_body="$(printf '{"device_code":"%s"}' "$device_code")"
  while :; do
    sleep "$interval"
    substrait_anon_call POST "$portal/api/link/poll" \
      -H "Content-Type: application/json" --data "$poll_body" || continue
    [ "${SUBSTRAIT_STATUS:-}" = "200" ] || continue
    local status; status="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field status)"
    case "$status" in
      approved) break ;;
      pending)  continue ;;
      expired|*) die "link expired or was not approved in time — run /substrait:link again" ;;
    esac
  done

  # 4. Persist the personal token GLOBALLY — every project on this machine can use it.
  local token email
  token="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field token)" || die "no token in approval"
  email="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field email)"
  _write_global_config "$portal" "$token"
  echo "Linked this machine to your Substrait account${email:+ ($email)}."
  echo "In any project: /substrait:link picks (or creates) the app it deploys to."
}

cmd_save_account() {
  local portal="" token=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --portal-url) portal="$2"; shift 2 ;;
      --token) token="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  [ -n "$token" ] || die "--token is required (create one on the portal's Access tokens page, or use 'account')"
  [ "${token#sbt_}" != "$token" ] || die "that is not a personal token (sbt_…) — app tokens (sbd_…) go through 'save'"
  portal="${portal:-${SUBSTRAIT_PORTAL_URL:-}}"; [ -n "$portal" ] || die "$_PORTAL_REQUIRED_MSG"; portal="${portal%/}"

  # Verify the token before persisting it.
  substrait_anon_call GET "$portal/api/auth/me" -H "Authorization: Bearer $token" \
    || die "could not reach $portal"
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "token rejected (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local email; email="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field email)"
  _write_global_config "$portal" "$token"
  echo "Linked this machine to your Substrait account${email:+ ($email)}."
  echo "In any project: /substrait:link picks (or creates) the app it deploys to."
}

cmd_whoami() {
  local token portal email
  token="$(_account_token)" || {
    echo "No account link on this machine — run /substrait:login to authorize your account."
    exit 1
  }
  if [ -n "${SUBSTRAIT_PORTAL_URL:-}" ]; then
    portal="${SUBSTRAIT_PORTAL_URL%/}"
  else
    portal="$(_json_get "$SUBSTRAIT_GLOBAL_CONFIG" portal_url)" \
      || die "the account link is missing its portal URL — re-run /substrait:login --portal-url <your Substrait API URL>."
  fi
  substrait_anon_call GET "${portal%/}/api/auth/me" -H "Authorization: Bearer $token" \
    || die "could not reach $portal"
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    echo "This machine has an account token (${token:0:12}…) but $portal rejected it" \
         "(HTTP $SUBSTRAIT_STATUS) — it may have been revoked. Run /substrait:login to re-authorize."
    exit 1
  fi
  email="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field email)"
  echo "Authenticated to $portal as ${email:-your account} (personal token ${token:0:12}…)."
  if _upload_mode_disabled; then
    echo "Note: this workspace has creating new apps from Claude Code disabled" \
         "— existing linked apps still deploy."
  fi
}

# True (exit 0) when the /api/auth/me body currently in SUBSTRAIT_BODY says the active
# workspace has upload mode ("Coding on Claude Code") disabled — a per-tenant toggle
# that refuses NEW app creation from the CLI. The `upload` key only occurs inside
# `org.modes`, and _json_field can't extract booleans, hence the direct grep.
_upload_mode_disabled() {
  printf '%s' "$SUBSTRAIT_BODY" | grep -q '"upload"[[:space:]]*:[[:space:]]*false'
}

# ── Project binding on top of an account link (slug only, no secret) ────────────

cmd_apps() {
  local token; token="$(_account_token)" || die "no account link on this machine — run /substrait:login to authorize your account first."
  # Mode awareness for the pick-or-create step (stderr, so stdout stays pure
  # slug<TAB>name rows). Checked BEFORE the projects call — both share SUBSTRAIT_BODY.
  # Fail-open: an unreachable /auth/me must not break the listing.
  if SUBSTRAIT_TOKEN="$token" substrait_call GET /api/auth/me 2>/dev/null \
     && [ "${SUBSTRAIT_STATUS:-}" = "200" ] && _upload_mode_disabled; then
    echo "note: this workspace has new-app creation from Claude Code disabled —" \
         "link an existing app; 'create' will be refused." >&2
  fi
  SUBSTRAIT_TOKEN="$token" substrait_call GET /api/projects || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "could not list apps (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  # One object per line, then slug + display name per row (field order is
  # server-controlled; neither value carries escaped quotes).
  printf '%s' "$SUBSTRAIT_BODY" | sed 's/},[[:space:]]*{/}\
{/g' | awk '
    {
      slug=""; name=""
      if (match($0, /"slug"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"slug"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); slug=s }
      if (match($0, /"display_name"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"display_name"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); name=s }
      if (slug != "") printf "%s\t%s\n", slug, name
    }'
}

# _bind_project SLUG — write the slug-only project ref, verify it resolves (and that
# the account may deploy it), cache the host, and record the CLAUDE.md memo.
_bind_project() {
  local slug="$1" token="$2"
  _write_project_ref "$slug"
  SUBSTRAIT_TOKEN="$token" substrait_call GET /api/deploy/app || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "could not bind to '$slug' (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local host
  host="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field preview_hostname)"; host="${host:-${slug}.apps.substrait.build}"
  _write_project_ref "$slug" "$host"   # re-write with the discovered host
  substrait_write_memo ensure
  echo "Linked this project to $slug (https://$host). Run /substrait:deploy to ship it."
}

cmd_use() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) slug="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  [ -n "$slug" ] || die "--app SLUG is required (see 'apps' for the list)"
  local token; token="$(_account_token)" || die "no account link on this machine — run /substrait:login to authorize your account first."
  _bind_project "$slug" "$token"
}

cmd_create() {
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  [ -n "$name" ] || die "--name NAME is required"
  local token; token="$(_account_token)" || die "no account link on this machine — run /substrait:login to authorize your account first."
  # Escape the two JSON-special characters a display name could carry.
  local esc; esc="$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  SUBSTRAIT_TOKEN="$token" substrait_call POST /api/projects/create \
    -H "Content-Type: application/json" --data "{\"display_name\":\"$esc\"}" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "201" ]; then
    # 403 = creation refused by policy (workspace mode toggle, quota, or missing
    # permission) — the backend's `detail` is user-facing prose worth relaying as-is.
    local detail=""
    [ "${SUBSTRAIT_STATUS:-}" = "403" ] && detail="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail)"
    [ -n "$detail" ] && die "could not create app: $detail"
    die "could not create app (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  fi
  local slug; slug="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field slug)" || die "bad create response"
  echo "Created app '$name' ($slug)."
  _bind_project "$slug" "$token"
}

# ── Deploy-mode choice (upload = zip, connect = GitHub) ─────────────────────────

cmd_modes() {
  # State the agent reads before offering the mode choice in /substrait:deploy.
  # Works with either credential: /api/deploy/app now carries org_modes.
  substrait_call GET /api/deploy/app || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "could not read the linked app (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local mode chosen
  mode="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field mode)" || mode=""
  [ "$mode" = "connect" ] || mode="upload"
  echo "app_mode: $mode"
  # org_modes booleans — grep, since _json_field only extracts strings/numbers; the
  # `upload`/`connect` keys occur only inside org_modes with boolean values.
  if printf '%s' "$SUBSTRAIT_BODY" | grep -q '"upload"[[:space:]]*:[[:space:]]*false'; then
    echo "tenant_upload: disabled"
  else
    echo "tenant_upload: enabled"
  fi
  if printf '%s' "$SUBSTRAIT_BODY" | grep -q '"connect"[[:space:]]*:[[:space:]]*false'; then
    echo "tenant_connect: disabled"
  else
    echo "tenant_connect: enabled"
  fi
  chosen="$(_json_get "$SUBSTRAIT_CONFIG_FILE" deploy_mode)" || chosen=""
  echo "chosen: ${chosen:-unset}"
  # Local git state, for the GitHub-path setup assist (deploy.md step 1b): connect
  # mode needs an initialized repo with an origin remote and a pushed branch.
  # symbolic-ref (not rev-parse) so a freshly `git init`ed repo with no commits
  # still reports its unborn branch instead of erroring.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "git_repo: yes"
    echo "git_branch: $(git symbolic-ref --short -q HEAD || echo unknown)"
    echo "git_remote: $(git remote get-url origin 2>/dev/null || echo none)"
  else
    echo "git_repo: no"
  fi
}

cmd_repos() {
  # GitHub repos reachable through the caller's App installations, for the mode-3
  # switch: full_name<TAB>default_branch<TAB>installation_id per row.
  local token; token="$(_account_token)" || die "listing GitHub repos needs an account link — run /substrait:login first."
  SUBSTRAIT_TOKEN="$token" substrait_call GET /api/github/repos || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "could not list GitHub repos (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local rows
  rows="$(printf '%s' "$SUBSTRAIT_BODY" | sed 's/},[[:space:]]*{/}\
{/g' | awk '
    {
      fn=""; db=""; inst=""
      if (match($0, /"full_name"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"full_name"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); fn=s }
      if (match($0, /"default_branch"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"default_branch"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); db=s }
      if (match($0, /"installation_id"[[:space:]]*:[[:space:]]*[0-9]+/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"installation_id"[[:space:]]*:[[:space:]]*/,"",s); inst=s }
      if (fn != "") printf "%s\t%s\t%s\n", fn, db, inst
    }')"
  if [ -z "$rows" ]; then
    # No installations (or none with repos): surface the browser install step.
    local url=""
    if SUBSTRAIT_TOKEN="$token" substrait_call GET /api/github/connect \
       && [ "${SUBSTRAIT_STATUS:-}" = "200" ]; then
      url="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field url)" || url=""
    fi
    echo "No GitHub repos available — install the Substrait GitHub App on the repo first${url:+ ($url)}, then re-run this." >&2
    exit 1
  fi
  printf '%s\n' "$rows"
}

cmd_set_mode() {
  local mode="" repo="" branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  case "$mode" in upload|connect) : ;; *) die "--mode must be 'upload' or 'connect'" ;; esac
  local slug; slug="$(substrait_app_slug)" || die "this project isn't linked to an app yet — run /substrait:link first."
  # Connection management runs on /api/projects/* — account (sbt_) credential only.
  local token; token="$(_account_token)" || die "switching deploy modes needs the account link (personal sbt_ token) — run /substrait:login. App-scoped sbd_ deploy tokens can't manage connections."
  SUBSTRAIT_TOKEN="$token" substrait_call GET /api/deploy/app || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "could not read the linked app (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local app_id cur_mode
  app_id="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field id)" || die "bad app response"
  cur_mode="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field mode)" || cur_mode=""
  [ "$cur_mode" = "connect" ] || cur_mode="upload"

  if [ "$mode" = "$cur_mode" ]; then
    _write_deploy_mode "$mode"
    echo "Deploy mode recorded: $mode (already the app's state)."
    return 0
  fi

  local detail
  if [ "$mode" = "connect" ]; then
    [ -n "$repo" ] || die "--repo OWNER/REPO is required to switch to GitHub deploys (run 'repos' for the list)"
    # Resolve installation + default branch from the account's repo list.
    local row inst def_branch
    row="$(cmd_repos | awk -F'\t' -v r="$repo" '$1 == r {print; exit}')" || true
    [ -n "$row" ] || die "repo '$repo' isn't reachable through your GitHub App installations — run 'repos' for the list (or install the app on that repo first)."
    def_branch="$(printf '%s' "$row" | cut -f2)"
    inst="$(printf '%s' "$row" | cut -f3)"
    [ -n "$branch" ] || branch="$def_branch"
    SUBSTRAIT_TOKEN="$token" substrait_call POST "/api/projects/$app_id/connection" \
      -H "Content-Type: application/json" \
      --data "{\"installation_id\":$inst,\"repo_full_name\":\"$repo\",\"branch\":\"$branch\"}" || exit $?
    if [ "${SUBSTRAIT_STATUS:-}" != "201" ]; then
      # 403 = tenant toggle off; 409 = already connected; 422 = repo/installation
      # mismatch — the backend detail is user-facing prose, relay it.
      detail="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail)" || detail=""
      [ -n "$detail" ] && die "could not connect the app: $detail"
      die "could not connect the app (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
    fi
    _write_deploy_mode connect
    echo "Switched '$slug' to GitHub deploys from $repo@$branch. Push the code to that repo — /substrait:deploy then triggers a pull of the pushed branch."
  else
    SUBSTRAIT_TOKEN="$token" substrait_call DELETE "/api/projects/$app_id/connection" || exit $?
    if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
      detail="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail)" || detail=""
      [ -n "$detail" ] && die "could not disconnect the app: $detail"
      die "could not disconnect the app (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
    fi
    _write_deploy_mode upload
    echo "Switched '$slug' back to zip deploys — /substrait:deploy now uploads the working tree."
  fi
}

cmd_save() {
  local portal="" token=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --portal-url) portal="$2"; shift 2 ;;
      --token) token="$2"; shift 2 ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  [ -n "$token" ]  || die "--token is required (create one on the app's Deploy tab, or use 'login')"
  portal="${portal:-${SUBSTRAIT_PORTAL_URL:-}}"; [ -n "$portal" ] || die "$_PORTAL_REQUIRED_MSG"; portal="${portal%/}"

  _write_config "$portal" "$token"
  # Verify the token + discover the app it's bound to, then cache slug/host.
  substrait_call GET /api/deploy/app || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "token rejected (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local slug host
  slug="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field slug)"
  host="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field preview_hostname)"; host="${host:-${slug}.apps.substrait.build}"
  _write_config "$portal" "$token" "$slug" "$host"   # re-write with the discovered slug/host
  substrait_write_memo ensure
  echo "Linked this project to ${slug:-the app} (https://$host). Run /substrait:deploy to ship it."
}

cmd_status() {
  local portal token account t
  portal="$(substrait_portal_url 2>/dev/null)" || portal=""
  token="$(substrait_token 2>/dev/null)" || token=""
  if account="$(_account_token)"; then
    echo "Account linked on this machine (personal token ${account:0:12}…, portal $portal)."
  else
    echo "No account link on this machine."
  fi
  if [ -z "$token" ]; then
    echo "This project is not linked — run /substrait:link."
    return 0
  fi
  # Which credential is in effect for THIS project (project sbd_ token wins).
  local cred="account token"
  if t="$(_json_get "$SUBSTRAIT_CONFIG_FILE" token 2>/dev/null)" && [ -n "$t" ]; then cred="app deploy token"; fi
  if [ "$cred" = "account token" ] && ! substrait_app_slug >/dev/null 2>&1; then
    echo "This project is not bound to an app yet — run /substrait:link to pick one."
    return 0
  fi
  substrait_call GET /api/deploy/app
  if [ $? -eq 0 ] && [ "${SUBSTRAIT_STATUS:-}" = "200" ]; then
    local slug display host
    slug="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field slug)"
    display="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field display_name)"
    host="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field preview_hostname)"; host="${host:-${slug}.apps.substrait.build}"
    echo "Linked to $slug ($display) on $portal via $cred — https://$host"
  else
    echo "Configured for $portal, but the $cred was rejected (HTTP ${SUBSTRAIT_STATUS:-?}) — re-run /substrait:link."
  fi
}

case "${1:-status}" in
  account)      shift; cmd_account "$@" ;;
  save-account) shift; cmd_save_account "$@" ;;
  whoami)       shift; cmd_whoami "$@" ;;
  apps)         shift; cmd_apps "$@" ;;
  use)          shift; cmd_use "$@" ;;
  create)       shift; cmd_create "$@" ;;
  modes)        shift; cmd_modes "$@" ;;
  repos)        shift; cmd_repos "$@" ;;
  set-mode)     shift; cmd_set_mode "$@" ;;
  login)  shift; cmd_login "$@" ;;
  save)   shift; cmd_save "$@" ;;
  status) shift || true; cmd_status ;;
  *) die "unknown command: ${1}. Use account|save-account|whoami|apps|use|create|modes|repos|set-mode|login|save|status." ;;
esac
