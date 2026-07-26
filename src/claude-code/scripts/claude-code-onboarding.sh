#!/usr/bin/env bash
# Marks onboarding as complete so a CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY login starts a session
# instead of dropping into the interactive theme/login screen.
#
# See https://github.com/anthropics/claude-code/issues/8938 -- the token alone is not enough on a fresh
# install; `hasCompletedOnboarding: true` in ~/.claude.json is what makes it take effect.
#
# Runs as the remote user: once at build time from install.sh, and again on every container start, because
# ~/.claude.json may live on a volume that only exists at runtime. Idempotent and non-destructive: it
# merges one key with jq and never touches permission or credential settings.
set -euo pipefail

# install.sh writes this; "false" means the user opted out via the autoOnboarding option.
CONFIG_FILE="/usr/local/etc/claude-code/auto-onboarding"
if [ -r "$CONFIG_FILE" ] && [ "$(cat "$CONFIG_FILE")" != "true" ]; then
    exit 0
fi

mark_onboarded() {
    local config_file="$1" tmp
    mkdir -p "$(dirname "$config_file")"

    if [ ! -f "$config_file" ]; then
        echo '{}' >"$config_file"
    fi

    # Already marked, or the file is not valid JSON we should be rewriting.
    if jq -e '.hasCompletedOnboarding == true' "$config_file" >/dev/null 2>&1; then
        return 0
    fi
    if ! jq -e . "$config_file" >/dev/null 2>&1; then
        echo "claude-code: $config_file is not valid JSON; leaving it alone." >&2
        return 0
    fi

    tmp="$(mktemp "${config_file}.XXXXXX")"
    jq '.hasCompletedOnboarding = true' "$config_file" >"$tmp"
    # Preserve the original mode where there was one; credentials can end up in this file.
    chmod 600 "$tmp"
    mv "$tmp" "$config_file"
}

mark_onboarded "${HOME}/.claude.json"

# The docs are ambiguous about whether CLAUDE_CONFIG_DIR relocates ~/.claude.json or only the ~/.claude
# directory, so patch both candidates when the variable is set.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${CLAUDE_CONFIG_DIR}" != "${HOME}" ]; then
    mark_onboarded "${CLAUDE_CONFIG_DIR}/.claude.json"
fi
