#!/usr/bin/env bash
# Browse the Substrait API Library — the design-time catalog of APIs an app can be
# built against: `internal` entries (admin-registered company API specs) and `app`
# entries (deployed Substrait apps' endpoint inventories).
#
#   list [--q TERM] [--tag TAG]      the whole catalog (JSON, printed verbatim)
#   show KIND SLUG                   one entry's detail (KIND = internal|app);
#                                    includes its endpoint summary + auth notes
#   spec SLUG [--out FILE]           an internal entry's full OpenAPI document;
#                                    --out writes it to FILE instead of stdout
#
# Output is the API's JSON body untouched — the calling agent parses JSON natively,
# and the pure-shell _json_field helper can't walk arrays anyway.
#
# Reads need an ACCOUNT credential (personal access token, sbt_): the library is
# user-scoped, so an app-scoped deploy token (sbd_) is rejected by the server.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

die() { echo "Error: $*" >&2; exit 1; }

# URL-encode just enough for query values (space and the JSON-ish specials that could
# appear in a search term). Pure shell, same portability constraints as _json_field.
_urlenc() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/&/%26/g' \
    -e 's/#/%23/g' -e 's/+/%2B/g' -e 's/?/%3F/g' -e 's|/|%2F|g'
}

# _check_auth — explain a 401/403 in library terms before dumping the body.
_check_auth() {
  case "${SUBSTRAIT_STATUS:-}" in
    401|403)
      echo "The library needs an ACCOUNT link (personal access token). An app deploy" >&2
      echo "token can't browse it — run /substrait:link and authorize your account." >&2
      ;;
  esac
}

cmd_list() {
  local q="" tag="" qs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --q)   q="${2:-}"; shift 2 ;;
      --tag) tag="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$q" ] && qs="?q=$(_urlenc "$q")"
  if [ -n "$tag" ]; then
    if [ -n "$qs" ]; then qs="$qs&tag=$(_urlenc "$tag")"; else qs="?tag=$(_urlenc "$tag")"; fi
  fi
  substrait_call GET "/api/library$qs" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _check_auth
    echo "Library list failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_show() {
  local kind="${1:-}" slug="${2:-}"
  case "$kind" in internal|app) ;; *) die "usage: show internal|app SLUG" ;; esac
  [ -n "$slug" ] || die "usage: show internal|app SLUG"
  # The API's collection segments are plural for apps, singular-adjective for internal.
  local seg="internal"; [ "$kind" = "app" ] && seg="apps"
  substrait_call GET "/api/library/$seg/$slug" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _check_auth
    echo "Library entry '$slug' failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_spec() {
  local slug="${1:-}"; shift || true
  [ -n "$slug" ] || die "usage: spec SLUG [--out FILE]"
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  substrait_call GET "/api/library/internal/$slug/spec" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _check_auth
    echo "Spec for '$slug' failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$SUBSTRAIT_BODY" > "$out" || die "could not write $out"
    echo "Wrote the OpenAPI spec for '$slug' to $out."
  else
    printf '%s\n' "$SUBSTRAIT_BODY"
  fi
}

case "${1:-list}" in
  list) shift || true; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  spec) shift; cmd_spec "$@" ;;
  *) die "unknown command: ${1}. Use list|show|spec." ;;
esac
