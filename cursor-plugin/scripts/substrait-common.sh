#!/usr/bin/env bash
# Shared helpers for the Substrait plugin's link/deploy scripts. Sourced, not run —
# so it sets no shell options of its own and never exits the caller.
#
# A deploy token is APP-scoped, so config is PER-PROJECT: it lives in this project's
# .substrait/config.json (gitignored), written by `substrait-link.sh`. Resolution order:
#   portal URL : $SUBSTRAIT_PORTAL_URL  ->  .substrait/config.json "portal_url"
#   token      : $SUBSTRAIT_TOKEN       ->  .substrait/config.json "token"

SUBSTRAIT_CONFIG_FILE="${SUBSTRAIT_CONFIG_FILE:-.substrait/config.json}"
# The hosted Substrait API. Used unless overridden (self-hosted portal) via
# $SUBSTRAIT_PORTAL_URL, a config portal_url, or `substrait-link.sh save --portal-url`.
SUBSTRAIT_DEFAULT_PORTAL="https://api.substrait.build"

# _json_get FILE KEY -> prints the string value, or exits 1 if absent. Uses python3
# (always present in a Claude Code env) so we need no jq dependency.
_json_get() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        v = json.load(f).get(sys.argv[2])
except Exception:
    sys.exit(1)
if v is None:
    sys.exit(1)
print(v)
PY
}

# _json_field KEY — read a JSON object from stdin, print obj[KEY]. Exit 1 if absent/null.
# Used to pull fields out of API response bodies (the device-link start/poll payloads).
# Uses `python3 -c` (not a heredoc) so stdin stays free for the piped JSON data.
_json_field() {
  python3 -c 'import json,sys
try: v = json.load(sys.stdin).get(sys.argv[1])
except Exception: sys.exit(1)
sys.exit(1) if v is None else print(v)' "$1" 2>/dev/null
}

substrait_portal_url() {
  if [ -n "${SUBSTRAIT_PORTAL_URL:-}" ]; then printf '%s' "${SUBSTRAIT_PORTAL_URL%/}"; return 0; fi
  local v; if v="$(_json_get "$SUBSTRAIT_CONFIG_FILE" portal_url)"; then printf '%s' "${v%/}"; return 0; fi
  printf '%s' "$SUBSTRAIT_DEFAULT_PORTAL"   # hosted default — no need to ask
}

substrait_token() {
  if [ -n "${SUBSTRAIT_TOKEN:-}" ]; then printf '%s' "$SUBSTRAIT_TOKEN"; return 0; fi
  _json_get "$SUBSTRAIT_CONFIG_FILE" token
}

# substrait_call METHOD PATH [extra curl args...]
# Performs the request and sets two globals in the CURRENT shell:
#   SUBSTRAIT_BODY    — the response body
#   SUBSTRAIT_STATUS  — the HTTP status code
# Returns 2 if unconfigured, else curl's exit code.
#
# IMPORTANT: call this as a plain statement, e.g.
#       substrait_call GET /api/deploy/app || exit $?
# NEVER inside a command substitution ( x="$(substrait_call ...)" ) — that runs it in a
# subshell, so the globals it sets would not reach the caller. (That was the original bug.)
substrait_call() {
  local method="$1" path="$2"; shift 2
  local base token tmp
  base="$(substrait_portal_url)" || {
    echo "Not linked yet — run /substrait:link to set this project's portal URL and token." >&2; return 2; }
  token="$(substrait_token)" || {
    echo "No deploy token configured — run /substrait:link." >&2; return 2; }
  tmp="$(mktemp)" || return 1
  SUBSTRAIT_STATUS="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer $token" "$base$path" "$@" 2>/dev/null)"
  local rc=$?
  SUBSTRAIT_BODY="$(cat "$tmp")"
  rm -f "$tmp"
  return $rc
}

# substrait_anon_call METHOD URL [extra curl args...]
# An UNAUTHENTICATED request to an absolute URL — used by the browser device-link flow
# (start/poll carry no token; the token is what the flow is fetching). Sets the same
# SUBSTRAIT_BODY / SUBSTRAIT_STATUS globals as substrait_call (so don't call it inside a
# command substitution). Returns curl's exit code.
substrait_anon_call() {
  local method="$1" url="$2"; shift 2
  local tmp; tmp="$(mktemp)" || return 1
  SUBSTRAIT_STATUS="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$url" "$@" 2>/dev/null)"
  local rc=$?
  SUBSTRAIT_BODY="$(cat "$tmp")"
  rm -f "$tmp"
  return $rc
}

# substrait_open_url URL — best-effort open in the user's browser; silent if no opener.
substrait_open_url() {
  if command -v open >/dev/null 2>&1; then open "$1" >/dev/null 2>&1   # macOS
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1  # Linux
  elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$1" >/dev/null 2>&1  # WSL
  else return 1; fi
}
