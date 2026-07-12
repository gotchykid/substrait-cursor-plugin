#!/usr/bin/env bash
# Link Claude Code to Substrait — either your ACCOUNT (once per machine) or this
# PROJECT to one app.
#
# Account (personal access token, sbt_ — global ~/.substrait/config.json):
#   account      [--portal-url URL]         browser flow: authorize the CLI as you;
#                                           the personal token is fetched automatically
#   save-account --token TOKEN [--portal-url URL]  fallback: paste an sbt_ token minted
#                                           on the portal's Access tokens page
# Project (with an account link in place — no per-project secret):
#   apps                                    list your apps (slug + name), to pick from
#   use    --app SLUG                       bind this project to an existing app
#   create --name NAME                      create a new empty app and bind to it
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

# _write_config PORTAL TOKEN [SLUG] [HOST] — write .substrait/config.json (0600) and
# make sure .substrait/ is gitignored. SLUG/HOST are cached for friendlier messages.
_write_config() {
  local portal="$1" token="$2" slug="${3:-}" host="${4:-}"
  mkdir -p .substrait
  umask 177
  # Build the JSON by hand (no python): these are values we control — a portal URL, an
  # sbd_ token, a slug and a hostname — none of which contain JSON-special characters.
  { printf '{\n  "portal_url": "%s",\n  "token": "%s"' "${portal%/}" "$token"
    [ -n "$slug" ] && printf ',\n  "slug": "%s"' "$slug"
    [ -n "$host" ] && printf ',\n  "host": "%s"' "$host"
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
  local slug="$1" host="${2:-}"
  mkdir -p .substrait
  umask 177
  { printf '{\n  "slug": "%s"' "$slug"
    [ -n "$host" ] && printf ',\n  "host": "%s"' "$host"
    printf '\n}\n'
  } > "$SUBSTRAIT_CONFIG_FILE"
  chmod 600 "$SUBSTRAIT_CONFIG_FILE"
  if [ -f .gitignore ] && ! grep -qx '.substrait/' .gitignore 2>/dev/null; then
    printf '\n# Substrait CLI link state\n.substrait/\n' >> .gitignore
  elif [ ! -f .gitignore ]; then
    printf '# Substrait CLI link state\n.substrait/\n' > .gitignore
  fi
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
  portal="${portal:-${SUBSTRAIT_PORTAL_URL:-$SUBSTRAIT_DEFAULT_PORTAL}}"; portal="${portal%/}"

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
  portal="${portal:-${SUBSTRAIT_PORTAL_URL:-$SUBSTRAIT_DEFAULT_PORTAL}}"; portal="${portal%/}"

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
  portal="${portal:-$SUBSTRAIT_DEFAULT_PORTAL}"

  # Verify the token before persisting it.
  substrait_anon_call GET "$portal/api/auth/me" -H "Authorization: Bearer $token" \
    || die "could not reach $portal"
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || die "token rejected (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local email; email="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field email)"
  _write_global_config "$portal" "$token"
  echo "Linked this machine to your Substrait account${email:+ ($email)}."
  echo "In any project: /substrait:link picks (or creates) the app it deploys to."
}

# ── Project binding on top of an account link (slug only, no secret) ────────────

cmd_apps() {
  local token; token="$(_account_token)" || die "no account link on this machine — run /substrait:link and authorize your account first."
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
  local token; token="$(_account_token)" || die "no account link on this machine — run /substrait:link and authorize your account first."
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
  local token; token="$(_account_token)" || die "no account link on this machine — run /substrait:link and authorize your account first."
  # Escape the two JSON-special characters a display name could carry.
  local esc; esc="$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  SUBSTRAIT_TOKEN="$token" substrait_call POST /api/projects/create \
    -H "Content-Type: application/json" --data "{\"display_name\":\"$esc\"}" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "201" ] || die "could not create app (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY"
  local slug; slug="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field slug)" || die "bad create response"
  echo "Created app '$name' ($slug)."
  _bind_project "$slug" "$token"
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
  portal="${portal:-$SUBSTRAIT_DEFAULT_PORTAL}"

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
  apps)         shift; cmd_apps "$@" ;;
  use)          shift; cmd_use "$@" ;;
  create)       shift; cmd_create "$@" ;;
  login)  shift; cmd_login "$@" ;;
  save)   shift; cmd_save "$@" ;;
  status) shift || true; cmd_status ;;
  *) die "unknown command: ${1}. Use account|save-account|apps|use|create|login|save|status." ;;
esac
