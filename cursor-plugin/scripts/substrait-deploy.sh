#!/usr/bin/env bash
# Package the current project (source only) and deploy it to its linked Substrait app.
#   --watch          poll the deploy until it finishes and print the preview URL
#   --stack <name>   override the recorded backend stack (default: auto-detected from
#                    backend/ — e.g. fastapi, python, node, go, rust, ruby, java, php, dotnet)
# The platform is stack-agnostic (any Dockerfile that EXPOSEs 8000 + serves /health works);
# the stack is just a label shown in the portal. The app is determined by the deploy token
# in .substrait/config.json (run /substrait:link first). Run from the project root (the dir
# containing backend/, frontend/, cicd/).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

die() { echo "Error: $*" >&2; exit 1; }

WATCH=0
STACK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=1; shift ;;
    --stack) shift; STACK="${1:-}"; [ -n "$STACK" ] || die "--stack needs a value (e.g. node, go, fastapi)"; shift ;;
    --stack=*) STACK="${1#*=}"; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

# detect_stack — best-effort guess of the backend stack from declaration files, so the
# label shown in the portal reflects what was actually shipped without the user passing
# --stack. Scans backend/ first (where the contract puts the backend), then the repo root.
# Pure file checks (+ one grep) so it stays dependency-free on Git Bash. Prints "other"
# when nothing matches; the platform accepts any short lowercase label regardless.
detect_stack() {
  local d
  for d in backend .; do
    [ -d "$d" ] || continue
    if [ -f "$d/go.mod" ]; then echo go; return; fi
    if [ -f "$d/Cargo.toml" ]; then echo rust; return; fi
    if [ -f "$d/requirements.txt" ] || [ -f "$d/pyproject.toml" ]; then
      if grep -qi 'fastapi' "$d/requirements.txt" "$d/pyproject.toml" 2>/dev/null; then echo fastapi; else echo python; fi
      return
    fi
    if [ -f "$d/Gemfile" ]; then echo ruby; return; fi
    if [ -f "$d/composer.json" ]; then echo php; return; fi
    if [ -f "$d/pom.xml" ] || [ -f "$d/build.gradle" ] || [ -f "$d/build.gradle.kts" ]; then echo java; return; fi
    if ls "$d"/*.csproj >/dev/null 2>&1; then echo dotnet; return; fi
    if [ -f "$d/package.json" ]; then echo node; return; fi
  done
  echo other
}

[ -n "$(substrait_token 2>/dev/null)" ] || die "not linked — run /substrait:link first."
[ -d backend ] || die "no backend/ here — run this from the project root (the dir with backend/, cicd/)."

# Compliance preflight — fail fast & locally on the cheap, high-value parts of the deploy
# contract before we package and upload anything. This MIRRORS the server's authoritative
# check (`infra.validate_app`): a backend Dockerfile is required; a frontend one too when
# a frontend/ is shipped; k8s/ is platform-owned and must not be present. The server still
# runs the full (incl. behavioural) validation in VALIDATING — this just turns the common
# failures into an actionable local error instead of a failed remote run.
#   BACKEND_DOCKERFILES : cicd/Dockerfile.backend, cicd/Dockerfile, backend/Dockerfile
#   FRONTEND_DOCKERFILES: cicd/Dockerfile.frontend, frontend/Dockerfile
compliance_preflight() {
  local f
  local backend_df=""
  for f in cicd/Dockerfile.backend cicd/Dockerfile backend/Dockerfile; do
    if [ -f "$f" ]; then backend_df="$f"; break; fi
  done
  [ -n "$backend_df" ] || die "not Substrait-compliant: no backend Dockerfile found — every app must ship one of cicd/Dockerfile.backend, cicd/Dockerfile or backend/Dockerfile (start from the scaffold's cicd/Dockerfile.backend). It must EXPOSE 8000, serve GET /health, and your API under /api. Fix this and re-run /substrait:deploy."

  if [ -d frontend ]; then
    local frontend_df=""
    for f in cicd/Dockerfile.frontend frontend/Dockerfile; do
      if [ -f "$f" ]; then frontend_df="$f"; break; fi
    done
    [ -n "$frontend_df" ] || die "not Substrait-compliant: frontend/ is present but ships no Dockerfile — add one of cicd/Dockerfile.frontend or frontend/Dockerfile (start from the scaffold's cicd/Dockerfile.frontend). It must serve the built SPA on port 80. Fix this and re-run /substrait:deploy."
  fi

  [ -d k8s ] || return 0
  die "not Substrait-compliant: a k8s/ directory is present — the platform owns the Kubernetes manifests and discards anything you ship there. Remove k8s/ and re-run /substrait:deploy."
}

echo "Checking Substrait compliance…"
compliance_preflight
echo "Compliance OK."

# Resolve the backend stack label: explicit --stack wins, else auto-detect. Lowercased to
# match the server's accepted shape (a short lowercase slug).
[ -n "$STACK" ] || STACK="$(detect_stack)"
STACK="$(printf '%s' "$STACK" | tr '[:upper:]' '[:lower:]')"
echo "Backend stack: $STACK"

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
  -F "backend_stack=$STACK" || exit $?
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

# 3. Poll the deploy status until this run reaches a terminal state, streaming the run's
#    event log alongside. The events carry the actual build/migration/smoke-test detail
#    (incl. an 80-line pod-log tail on failures), so when a deploy breaks the error lands
#    right here in the transcript where the coding agent can read it and fix the app —
#    no portal round-trip. A backend that predates the events endpoint 404s; we silently
#    degrade to state-only watching.
echo "Watching deploy… (Ctrl-C to stop watching; the deploy keeps running)"
deadline=$(( $(date +%s) + 900 ))   # 15 min ceiling
last=""
last_seq=0

# print_events — fetch this run's events newer than $last_seq, print them, advance
# $last_seq. Heartbeat rows ("BUILD_BACKEND: active (45s/600s)") are elided — they would
# swamp the transcript and the status poll already shows phase changes. Same flat-grep
# JSON parsing as the status poll: field order is server-controlled (level precedes
# message), and message is the one field that may carry escaped quotes/newlines (log
# tails), so it gets an escape-aware match + unescape.
print_events() {
  [ -n "$run_id" ] || return 0
  substrait_call GET "/api/deploy/runs/$run_id/events?after_seq=$last_seq" || return 0
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || return 0
  local rows max
  rows="$(printf '%s' "$SUBSTRAIT_BODY" | sed 's/},[[:space:]]*{/}\
{/g')"
  # rows are seq-ascending, so the last seq in the body is the high-water mark.
  max="$(printf '%s' "$rows" | grep -o '"seq"[[:space:]]*:[[:space:]]*[0-9][0-9]*' | grep -o '[0-9][0-9]*$' | tail -1)"
  printf '%s\n' "$rows" | awk '
    {
      lvl=""; msg=""
      if (match($0, /"level"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"level"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); lvl=s }
      if (match($0, /"message"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"message"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); msg=s }
      if (msg == "") next
      if (msg ~ /\([0-9]+s\/[0-9]+s\)$/) next     # elide heartbeats
      gsub(/\\r/, "", msg)
      gsub(/\\n/, "\n        ", msg)              # keep log tails aligned under their event
      gsub(/\\t/, "    ", msg)
      gsub(/\\"/, "\"", msg)
      if (lvl == "error")                        printf "    ✗ %s\n", msg
      else if (lvl == "warn" || lvl == "warning") printf "    ! %s\n", msg
      else                                        printf "      %s\n", msg
    }'
  [ -n "$max" ] && last_seq="$max"
}

while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 8
  print_events
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
  # Terminal states: drain any events written after our last fetch (the failure detail
  # usually lands in the same instant as the state flip) before reporting.
  case "$state" in
    PREVIEW_LIVE) print_events; echo "✅ Live: https://$host"; exit 0 ;;
    FAILED|ERROR)
      print_events
      die "deploy failed (state $state) — the ✗ events above say why. Fix the app and re-run /substrait:deploy (full log in the portal, run #$run_id)." ;;
  esac
done
echo "Still running after 15 min — check the portal for run #$run_id (https://$host when live)."
