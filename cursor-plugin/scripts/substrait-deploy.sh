#!/usr/bin/env bash
# Package the current project (source only) and deploy it to its linked Substrait app.
#   --watch   poll the deploy until it finishes and print the preview URL
# The app is determined by the deploy token in .substrait/config.json (run /substrait:link
# first). Run from the project root (the dir containing backend/, frontend/, cicd/).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

die() { echo "Error: $*" >&2; exit 1; }

WATCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$(substrait_token 2>/dev/null)" ] || die "not linked — run /substrait:link first."
[ -d backend ] || die "no backend/ here — run this from the project root (the dir with backend/, cicd/)."

# package DEST — zip the project root, source only. Prefers `zip`; on a stock Windows /
# Git Bash machine (which has no `zip`) it stages a clean copy with `tar` — reusing the
# same exclude list — and compresses it with PowerShell's Compress-Archive. Returns 2 when
# no packager is available so the caller can give an actionable error.
package() {
  local dest="$1"
  if command -v zip >/dev/null 2>&1; then
    zip -rq "$dest" . \
      -x '.git/*' '*/.git/*' \
         'node_modules/*' '*/node_modules/*' \
         '.venv/*' '*/.venv/*' 'venv/*' '*/venv/*' \
         '__pycache__/*' '*/__pycache__/*' '*.pyc' \
         'dist/*' '*/dist/*' 'build/*' '*/build/*' \
         '.substrait/*' '.DS_Store' '*/.DS_Store'
    return $?
  fi
  local ps; ps="$(command -v powershell.exe || command -v pwsh.exe || command -v pwsh || true)"
  if [ -n "$ps" ] && command -v tar >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    local stage; stage="$(mktemp -d)" || return 1
    tar -cf - \
      --exclude='./.git' --exclude='*/.git' --exclude='./node_modules' --exclude='*/node_modules' \
      --exclude='./.venv' --exclude='*/.venv' --exclude='./venv' --exclude='*/venv' \
      --exclude='__pycache__' --exclude='*.pyc' --exclude='./dist' --exclude='*/dist' \
      --exclude='./build' --exclude='*/build' --exclude='./.substrait' --exclude='.DS_Store' . \
      | tar -xf - -C "$stage" || { rm -rf "$stage"; return 1; }
    "$ps" -NoProfile -NonInteractive -Command \
      "Compress-Archive -Path '$(cygpath -w "$stage")\\*' -DestinationPath '$(cygpath -w "$dest")' -Force" \
      || { rm -rf "$stage"; return 1; }
    rm -rf "$stage"
    return 0
  fi
  return 2
}

# 1. Zip the project root, source only. The platform discards build artifacts anyway,
#    and the 16 MB cap is easy to blow with node_modules/.venv present.
zip_path="$(mktemp -t substrait-XXXXXX).zip"
trap 'rm -f "$zip_path"' EXIT
echo "Packaging (source only)…"
package "$zip_path"; pkg_rc=$?
[ "$pkg_rc" -eq 2 ] && die "no 'zip' command found and no PowerShell fallback available — install zip (or run from an environment that has it) and retry."
[ "$pkg_rc" -ne 0 ] && die "packaging failed"

size=$(wc -c < "$zip_path" | tr -d ' ')
max=$((16 * 1024 * 1024))
if [ "$size" -gt "$max" ]; then
  die "zip is $((size/1024/1024)) MB (max 16 MB). Exclude build output / large assets and retry."
fi
echo "Packaged $((size/1024)) KB."

# 2. Deploy the token's app (the app is inferred server-side from the token).
echo "Deploying…"
substrait_call POST /api/deploy \
  -F "file=@$zip_path;type=application/zip;filename=upload.zip" \
  -F "backend_stack=fastapi" || exit $?
case "${SUBSTRAIT_STATUS:-}" in
  200|201|202) : ;;
  *) die "deploy failed (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY" ;;
esac

run_id="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field run_id)"
# host lives under the nested "project" object; a flat first-match grep finds it (it's the
# only preview_hostname/slug in the body), falling back to the slug-derived hostname.
host="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field preview_hostname)"
[ -n "$host" ] || { slug="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field slug)"; host="${slug}.apps.substrait.build"; }
echo "Deploy queued — run #$run_id."

if [ "$WATCH" -ne 1 ]; then
  echo "Track it in the portal; once live it'll be at https://$host"
  exit 0
fi

# 3. Poll the deploy status until this run reaches a terminal state.
echo "Watching deploy… (Ctrl-C to stop watching; the deploy keeps running)"
deadline=$(( $(date +%s) + 900 ))   # 15 min ceiling
last=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 8
  substrait_call GET /api/deploy/status || continue
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || continue
  # Split the array into one object per line, then find the row whose id == run_id and
  # print its state; fall back to the first (most recent) row's state if no id matches.
  state="$(printf '%s' "$SUBSTRAIT_BODY" | sed 's/},[[:space:]]*{/}\
{/g' | awk -v rid="$run_id" '
    { id=""; st="";
      if (match($0,/"id"[[:space:]]*:[[:space:]]*"?[^",}]+/)) { s=substr($0,RSTART,RLENGTH); sub(/.*:[[:space:]]*"?/,"",s); id=s }
      if (match($0,/"state"[[:space:]]*:[[:space:]]*"[^"]*"/)) { s=substr($0,RSTART,RLENGTH); sub(/.*:[[:space:]]*"/,"",s); sub(/"$/,"",s); st=s }
      if (NR==1) first=st
      if (id==rid) { print st; found=1; exit } }
    END { if (!found) print first }')"
  if [ "$state" != "$last" ] && [ -n "$state" ]; then echo "  • $state"; last="$state"; fi
  case "$state" in
    PREVIEW_LIVE) echo "✅ Live: https://$host"; exit 0 ;;
    FAILED|ERROR) die "deploy failed (state $state). Check the portal logs for run #$run_id." ;;
  esac
done
echo "Still running after 15 min — check the portal for run #$run_id (https://$host when live)."
