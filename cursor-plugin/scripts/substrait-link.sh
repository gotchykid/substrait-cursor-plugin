#!/usr/bin/env bash
# Link the current project to a Substrait app.
#   login  [--portal-url URL]               browser flow: pick the app while logged in,
#                                           the deploy token is fetched automatically
#   save   --token TOKEN [--portal-url URL] fallback: paste an sbd_ token (headless/CI)
#   status                                  show the configured portal + bound app
#
# A deploy token is APP-scoped — it determines which app this project deploys to. The
# `login` flow mints one for the app you pick in the browser; `save` takes one you minted
# by hand on the app's Deploy tab. Config is per-project in ./.substrait/config.json
# (gitignored).
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
  python3 - "$SUBSTRAIT_CONFIG_FILE" "${portal%/}" "$token" "$slug" "$host" <<'PY'
import json, sys
path, portal, token, slug, host = sys.argv[1:6]
cfg = {"portal_url": portal, "token": token}
if slug: cfg["slug"] = slug
if host: cfg["host"] = host
json.dump(cfg, open(path, "w"), indent=2)
PY
  chmod 600 "$SUBSTRAIT_CONFIG_FILE"
  if [ -f .gitignore ] && ! grep -qx '.substrait/' .gitignore 2>/dev/null; then
    printf '\n# Substrait CLI link state\n.substrait/\n' >> .gitignore
  elif [ ! -f .gitignore ]; then
    printf '# Substrait CLI link state\n.substrait/\n' > .gitignore
  fi
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
  echo "Linked this project to ${slug:-the app}${host:+ (https://$host)}. Run /substrait:deploy to ship it."
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
  python3 - "$SUBSTRAIT_CONFIG_FILE" "$SUBSTRAIT_BODY" <<'PY'
import json, sys
path, body = sys.argv[1], sys.argv[2]
cfg = json.load(open(path)); p = json.loads(body)
cfg["slug"] = p["slug"]
cfg["host"] = p.get("preview_hostname") or (p["slug"] + ".apps.substrait.build")
json.dump(cfg, open(path, "w"), indent=2)
print(f"Linked this project to {p['slug']} (https://{cfg['host']}). Run /substrait:deploy to ship it.")
PY
}

cmd_status() {
  local portal token
  portal="$(substrait_portal_url 2>/dev/null)" || portal=""
  token="$(substrait_token 2>/dev/null)" || token=""
  if [ -z "$portal" ] || [ -z "$token" ]; then
    echo "This project is not linked — run /substrait:link."
    return 0
  fi
  substrait_call GET /api/deploy/app
  if [ $? -eq 0 ] && [ "${SUBSTRAIT_STATUS:-}" = "200" ]; then
    python3 - "$SUBSTRAIT_BODY" "$portal" <<'PY'
import json, sys
p = json.loads(sys.argv[1])
host = p.get("preview_hostname") or (p["slug"] + ".apps.substrait.build")
print(f"Linked to {p['slug']} ({p.get('display_name','')}) on {sys.argv[2]} — https://{host}")
PY
  else
    echo "Configured for $portal, but the token was rejected (HTTP ${SUBSTRAIT_STATUS:-?}) — re-run /substrait:link."
  fi
}

case "${1:-status}" in
  login)  shift; cmd_login "$@" ;;
  save)   shift; cmd_save "$@" ;;
  status) shift || true; cmd_status ;;
  *) die "unknown command: ${1}. Use login|save|status." ;;
esac
