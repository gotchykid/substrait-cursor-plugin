#!/usr/bin/env bash
# sessionStart hook for the `substrait` Cursor plugin: notify-only update check.
#
# The Cursor twin of substrait-plugin/scripts/substrait-update-check.sh. Once per 24h
# (throttled, fail-silent) it asks GitHub whether a newer version of the bundled
# substrait-app skill has been published, and if so emits a one-line nudge to update the
# plugin from the Cursor marketplace. It NEVER mutates the plugin's files. Any
# network/parse error exits 0 so it never blocks a session.
#
# Version source of truth is the `version:` in skills/substrait-app/SKILL.md (a sortable
# UTC stamp). We compare the installed copy against the one published in the public Cursor
# distribution repo.
#
# Differences from the Claude Code hook: (a) the published SKILL.md lives in the Cursor
# repo; (b) sessionStart returns Cursor's {"additional_context": ...} schema instead of
# Claude's hookSpecificOutput.additionalContext.
#
# To disable: remove/disable the substrait plugin's sessionStart hook.
set -u

# The installed plugin root: Cursor may export CURSOR_PLUGIN_ROOT; otherwise derive it from
# this script's location (scripts/ sits directly under the plugin root).
ROOT="${CURSOR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}"
[ -n "$ROOT" ] || exit 0
LOCAL_SKILL="$ROOT/skills/substrait-app/SKILL.md"
[ -f "$LOCAL_SKILL" ] || exit 0

# Stamp in a writable cache dir — the installed plugin dir may be read-only.
STAMP="${TMPDIR:-/tmp}/substrait-cursor-update-check"

# Throttle: at most one check per 24h.
now="$(date +%s 2>/dev/null)" || exit 0
if [ -f "$STAMP" ]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  case "$last" in ""|*[!0-9]*) last=0 ;; esac
  [ "$((now - last))" -ge 86400 ] || exit 0
fi
echo "$now" > "$STAMP" 2>/dev/null || true

_skill_version() {  # reads SKILL.md frontmatter `version:` from stdin
  sed -n 's/^version:[[:space:]]*//p' | head -1 | tr -d '[:space:]'
}

local_ver="$(_skill_version < "$LOCAL_SKILL")"
[ -n "$local_ver" ] || exit 0

# Published SKILL.md in the public Cursor distribution repo (short timeout, fail-silent).
RAW="https://raw.githubusercontent.com/gotchykid/substrait-cursor-plugin/main/cursor-plugin/skills/substrait-app/SKILL.md"
remote_ver="$(curl -fsS --max-time 5 "$RAW" 2>/dev/null | _skill_version)"
[ -n "$remote_ver" ] || exit 0

# Nothing to do if already current.
[ "$remote_ver" != "$local_ver" ] || exit 0
# Upgrade-only: skip unless remote sorts strictly after local (zero-padded stamps).
greater="$(printf '%s\n%s\n' "$local_ver" "$remote_ver" | sort | tail -1)"
[ "$greater" = "$remote_ver" ] || exit 0

# sessionStart: inject a note so the agent surfaces the nudge to the user. Built with
# printf (no python) — the message has no JSON-special characters that need escaping.
msg="A newer substrait Cursor plugin is available ($local_ver -> $remote_ver). Let the user know they can update it from the Cursor marketplace (the \`substrait\` plugin)."
printf '{"additional_context":"%s"}\n' "$msg"
exit 0
