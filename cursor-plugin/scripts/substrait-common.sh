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

# _json_field KEY — read a JSON object from stdin, print obj[KEY]. Exit 1 if absent.
# Used to pull fields out of API response bodies (the device-link start/poll payloads)
# and config files. Pure shell on purpose: the only guaranteed runtime here is the bash
# that's already executing this script (Git Bash on Windows), so we depend on nothing
# beyond grep/sed/head — no python3 (absent, or a silent App-Execution-Alias stub, on many
# Windows and Node-only dev machines) and no jq. The values we parse are simple and
# server-controlled (tokens, slugs, hostnames, URLs, integers, enum states, run ids) with
# no nested quotes or escapes, so a flat first-match extractor is reliable. Captures stdin
# into a var first so it can make two passes (string value, then number value).
_json_field() {
  local key="$1" body out
  body="$(cat)"
  out="$(printf '%s' "$body" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1)"
  if [ -n "$out" ]; then printf '%s' "$out" | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'; return 0; fi
  out="$(printf '%s' "$body" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*-\?[0-9][0-9.eE+-]*" | head -1)"
  if [ -n "$out" ]; then printf '%s' "$out" | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*//'; return 0; fi
  return 1
}

# _json_get FILE KEY -> prints the value, or exits 1 if the file or key is absent.
_json_get() { [ -f "$1" ] || return 1; _json_field "$2" < "$1"; }

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
