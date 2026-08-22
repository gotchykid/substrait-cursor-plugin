#!/usr/bin/env bash
# sessionStart hook for the `substrait` Cursor plugin: notify-only update check.
#
# The Cursor twin of substrait-plugin/scripts/substrait-update-check.sh. Once per 24h
# (throttled, fail-silent) it asks GitHub whether a newer version of the bundled
# substrait-app skill has been published, and if so emits a one-line nudge to update the
# plugin from the Cursor marketplace. It NEVER mutates the plugin's files. Any
# network/parse error exits 0 so it never blocks a session.
#
# Version source of truth is the PLUGIN RELEASE version in .cursor-plugin/plugin.json
# (a sortable UTC stamp) — bumped on ANY plugin change (commands, scripts, skill,
# hooks); publish-cursor.sh refuses to publish without it. The skill's SKILL.md
# `version:` is the SCAFFOLD version and is only a fallback here.
#
# Differences from the Claude Code hook: (a) the published files live in the Cursor
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
LOCAL_MANIFEST="$ROOT/.cursor-plugin/plugin.json"
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
_plugin_version() {  # reads plugin.json "version" from stdin (flat, server-controlled)
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

RAW_BASE="https://raw.githubusercontent.com/substrait-build/substrait-cursor-plugin/main/cursor-plugin"

# Prefer the plugin release version; fall back to the skill (scaffold) version when
# either side predates the plugin.json version field.
local_ver=""; [ -f "$LOCAL_MANIFEST" ] && local_ver="$(_plugin_version < "$LOCAL_MANIFEST")"
remote_ver="$(curl -fsS --max-time 5 "$RAW_BASE/.cursor-plugin/plugin.json" 2>/dev/null | _plugin_version)"
if [ -z "$local_ver" ] || [ -z "$remote_ver" ]; then
  local_ver="$(_skill_version < "$LOCAL_SKILL")"
  remote_ver="$(curl -fsS --max-time 5 "$RAW_BASE/skills/substrait-app/SKILL.md" 2>/dev/null | _skill_version)"
fi
[ -n "$local_ver" ] || exit 0
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
