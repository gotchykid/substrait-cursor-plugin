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

# 1. Zip the project root, source only. The platform discards build artifacts anyway,
#    and the 16 MB cap is easy to blow with node_modules/.venv present.
zip_path="$(mktemp -t substrait-XXXXXX).zip"
trap 'rm -f "$zip_path"' EXIT
echo "Packaging (source only)…"
zip -rq "$zip_path" . \
  -x '.git/*' '*/.git/*' \
     'node_modules/*' '*/node_modules/*' \
     '.venv/*' '*/.venv/*' 'venv/*' '*/venv/*' \
     '__pycache__/*' '*/__pycache__/*' '*.pyc' \
     'dist/*' '*/dist/*' 'build/*' '*/build/*' \
     '.substrait/*' '.DS_Store' '*/.DS_Store' \
  || die "zip failed"

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

run_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("run_id",""))' "$SUBSTRAIT_BODY" 2>/dev/null)"
host="$(python3 -c 'import json,sys; p=json.loads(sys.argv[1]).get("project",{}); print(p.get("preview_hostname") or (p.get("slug","")+".apps.substrait.build"))' "$SUBSTRAIT_BODY" 2>/dev/null)"
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
  state="$(python3 - "$SUBSTRAIT_BODY" "$run_id" <<'PY'
import json, sys
deps = json.loads(sys.argv[1]); rid = sys.argv[2]
row = next((d for d in deps if str(d.get("id")) == str(rid)), (deps[0] if deps else None))
print(row.get("state", "") if row else "")
PY
)"
  if [ "$state" != "$last" ] && [ -n "$state" ]; then echo "  • $state"; last="$state"; fi
  case "$state" in
    PREVIEW_LIVE) echo "✅ Live: https://$host"; exit 0 ;;
    FAILED|ERROR) die "deploy failed (state $state). Check the portal logs for run #$run_id." ;;
  esac
done
echo "Still running after 15 min — check the portal for run #$run_id (https://$host when live)."
