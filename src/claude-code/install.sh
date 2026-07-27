#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Installs Claude Code with the installer Anthropic documents as recommended:
#
#   curl -fsSL https://claude.ai/install.sh | bash -s <channel|version>
#
# The native installer is per-user: it puts the launcher in ~/.local/bin/claude and the versions in
# ~/.local/share/claude/versions. We therefore run it as the container's remote user, not as root, and
# make ~/.local/bin discoverable instead of shadowing the launcher with a symlink in /usr/local/bin --
# replacing that launcher interferes with the auto-updater.
#
# Debian/Ubuntu only. See NOTES.md for the reasoning and for the egress-firewall recommendation.
#-------------------------------------------------------------------------------------------------------------
set -euo pipefail

VERSION="${VERSION:-latest}"
DISABLE_AUTOUPDATER="${DISABLEAUTOUPDATER:-false}"
AUTO_ONBOARDING="${AUTOONBOARDING:-true}"

INSTALLER_URL="https://claude.ai/install.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/usr/local/etc/claude-code"

if [ "$(id -u)" -ne 0 ]; then
    echo "(!) This feature needs to be installed as root. Run it in a devcontainer build, not by hand." >&2
    exit 1
fi

if ! type apt-get >/dev/null 2>&1; then
    echo "(!) This feature only supports Debian/Ubuntu-based images (no apt-get found)." >&2
    exit 1
fi

# The value is interpolated into a shell command below, so keep it to what a channel or semver can contain.
if ! printf '%s' "${VERSION}" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    echo "(!) Invalid 'version' option: '${VERSION}'. Expected 'latest', 'stable' or a version like '2.1.89'." >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------------------------------------
APT_UPDATED="false"
apt_install() {
    if [ "${APT_UPDATED}" = "false" ]; then
        if [ ! -d /var/lib/apt/lists ] || [ -z "$(ls -A /var/lib/apt/lists 2>/dev/null)" ]; then
            apt-get update -y
        fi
        APT_UPDATED="true"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

install_if_missing() {
    local missing="" cmd pkg
    while [ "$#" -gt 0 ]; do
        cmd="${1%%:*}"
        pkg="${1##*:}"
        type "${cmd}" >/dev/null 2>&1 || missing="${missing} ${pkg}"
        shift
    done
    # shellcheck disable=SC2086
    [ -n "${missing}" ] && apt_install ${missing}
    return 0
}

# ---------------------------------------------------------------------------------------------------------
# Resolve the user to install for: whoever will be using the container.
# ---------------------------------------------------------------------------------------------------------
USERNAME=""
for candidate in "${_REMOTE_USER:-}" "${_CONTAINER_USER:-}" vscode node codespace; do
    if [ -n "${candidate}" ] && id -u "${candidate}" >/dev/null 2>&1; then
        USERNAME="${candidate}"
        break
    fi
done
USERNAME="${USERNAME:-root}"

USER_HOME="$(getent passwd "${USERNAME}" | cut -d: -f6)"
if [ -z "${USER_HOME}" ] || [ ! -d "${USER_HOME}" ]; then
    echo "(!) Could not determine a home directory for '${USERNAME}'." >&2
    exit 1
fi

echo "Installing Claude Code ('${VERSION}') for user '${USERNAME}' (home: ${USER_HOME}) ..."

# jq is not optional: both the settings merge below and the onboarding script that runs on every
# container start use it to patch JSON config non-destructively.
#
# bubblewrap (bwrap) and socat back Claude Code's sandboxed Bash tool. That sandbox is not something this
# feature turns on -- it is gated by the CLI's own `sandbox.enabled`/`sandbox.failIfUnavailable` settings,
# which can end up true from a user's or org's own settings.json, or from Anthropic's own default rollout,
# entirely outside this feature's control. Without these two packages, a session that needs the sandbox
# fails hard with "Sandbox is required but failed to initialize: ... socat not installed." instead of
# quietly falling back, so both are installed unconditionally rather than guessed at.
install_if_missing curl:curl bash:bash jq:jq bwrap:bubblewrap socat:socat
apt_install ca-certificates

# ---------------------------------------------------------------------------------------------------------
# Run the official installer as the target user
#
# `su -` starts a *login* shell, which deliberately begins from a clean environment. Behind a build-time
# HTTP proxy that is fatal: Docker exposes the proxy to RUN through HTTP_PROXY/HTTPS_PROXY, apt picks it up
# because it runs as root in that environment, and then the installer's curl -- one `su -` away -- does not,
# and the build dies on "Could not resolve host: claude.ai". So re-export the proxy variables across the
# boundary. Values are single-quoted for the shell `su -c` hands the command to; embedded quotes are escaped
# rather than assumed absent.
# ---------------------------------------------------------------------------------------------------------
PROXY_EXPORTS=""
for proxy_var in HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy; do
    proxy_value="${!proxy_var-}"
    [ -n "${proxy_value}" ] || continue
    proxy_value="$(printf '%s' "${proxy_value}" | sed "s/'/'\\\\''/g")"
    PROXY_EXPORTS="${PROXY_EXPORTS}export ${proxy_var}='${proxy_value}'; "
done
if [ -n "${PROXY_EXPORTS}" ]; then
    echo "Forwarding the build-time proxy configuration to the installer."
fi

run_as_user() {
    if [ "${USERNAME}" = "root" ]; then
        # No `su`, so this branch keeps the current environment and needs no help.
        env HOME="${USER_HOME}" bash -lc "$1"
    else
        su - "${USERNAME}" -c "${PROXY_EXPORTS}$1"
    fi
}

run_as_user "set -e; curl -fsSL '${INSTALLER_URL}' | bash -s '${VERSION}'"

CLAUDE_BIN="${USER_HOME}/.local/bin/claude"
if [ ! -x "${CLAUDE_BIN}" ]; then
    echo "(!) Installation finished but '${CLAUDE_BIN}' is missing or not executable." >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------------------------
# Shell setup, written once and installed in two places.
#
# 1. `~/.local/bin` on PATH. Deliberately no /usr/local/bin/claude symlink: the native installer owns
#    ~/.local/bin/claude and shadowing it confuses `claude update` and `claude doctor`.
# 2. Empty credentials dropped. "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}" in devcontainer.json expands to an
#    EMPTY string when the host has no such variable -- the variable still ends up defined in the
#    container, and Claude Code would see a blank credential instead of falling back to browser login.
#
# /etc/profile.d covers login shells, the system rc files cover interactive non-login ones; neither covers
# the other, hence both. Kept POSIX so the same text works in bash, zsh and dash.
# ---------------------------------------------------------------------------------------------------------
SHELL_SNIPPET="$(cat <<'EOF'
# Added by the 'claude-code' dev container feature.
if [ -n "${HOME:-}" ] && [ -d "${HOME}/.local/bin" ]; then
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) ;;
        *) PATH="${HOME}/.local/bin:${PATH}" ;;
    esac
    export PATH
fi
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then unset CLAUDE_CODE_OAUTH_TOKEN; fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then unset ANTHROPIC_API_KEY; fi
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then unset ANTHROPIC_AUTH_TOKEN; fi
EOF
)"

mkdir -p /etc/profile.d
printf '%s\n' "${SHELL_SNIPPET}" > /etc/profile.d/claude-code.sh
chmod 0644 /etc/profile.d/claude-code.sh

for rc in /etc/bash.bashrc /etc/bashrc /etc/zsh/zshenv; do
    if [ -f "${rc}" ] && ! grep -q 'claude-code dev container feature' "${rc}" 2>/dev/null; then
        printf '\n%s\n' "${SHELL_SNIPPET}" >> "${rc}"
    fi
done

# ---------------------------------------------------------------------------------------------------------
# ~/.claude/settings.json. The native installer writes this file itself (autoUpdatesChannel), so entries
# are merged in rather than replacing it.
# ---------------------------------------------------------------------------------------------------------
SETTINGS_DIR="${USER_HOME}/.claude"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

set_settings_env() {
    local key="$1" value="$2" tmp
    mkdir -p "${SETTINGS_DIR}"
    [ -f "${SETTINGS_FILE}" ] || printf '{}\n' > "${SETTINGS_FILE}"
    tmp="$(mktemp)"
    jq --arg k "${key}" --arg v "${value}" '.env = ((.env // {}) + {($k): $v})' "${SETTINGS_FILE}" > "${tmp}"
    mv "${tmp}" "${SETTINGS_FILE}"
}

if [ "${DISABLE_AUTOUPDATER}" = "true" ]; then
    set_settings_env DISABLE_AUTOUPDATER 1
fi

if [ -d "${SETTINGS_DIR}" ]; then
    chown -R "${USERNAME}:$(id -gn "${USERNAME}")" "${SETTINGS_DIR}"
fi

# ---------------------------------------------------------------------------------------------------------
# Onboarding. A CLAUDE_CODE_OAUTH_TOKEN alone drops you on the interactive theme/login screen on a fresh
# install (anthropics/claude-code#8938); hasCompletedOnboarding in ~/.claude.json is what makes it stick.
#
# Applied twice on purpose: once here so a container that never runs postStartCommand is still usable, and
# again on every container start, because ~/.claude.json can live on a volume that does not exist yet at
# build time.
# ---------------------------------------------------------------------------------------------------------
mkdir -p "${CONFIG_DIR}"
printf '%s\n' "${AUTO_ONBOARDING}" > "${CONFIG_DIR}/auto-onboarding"
chmod 0444 "${CONFIG_DIR}/auto-onboarding"

install -m 0755 "${SCRIPT_DIR}/scripts/claude-code-onboarding.sh" /usr/local/bin/claude-code-onboarding.sh

if [ "${AUTO_ONBOARDING}" = "true" ]; then
    run_as_user '/usr/local/bin/claude-code-onboarding.sh'
    chown "${USERNAME}:$(id -gn "${USERNAME}")" "${USER_HOME}/.claude.json" 2>/dev/null || true
fi

rm -rf /var/lib/apt/lists/*

# Smoke test. `claude --version` has to actually run: a CLI that cannot start -- because a runtime
# dependency is missing, say -- must fail the build here rather than bake a broken `claude` into the image
# and report success.
if ! VERSION_OUTPUT="$(run_as_user 'claude --version' 2>&1)"; then
    echo "(!) claude-code: installed, but 'claude --version' failed to run. Last lines:" >&2
    printf '%s\n' "${VERSION_OUTPUT}" | tail -5 | sed 's/^/    /' >&2
    exit 1
fi

INSTALLED_VERSION="$(printf '%s' "${VERSION_OUTPUT}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

echo "Claude Code installed: ${INSTALLED_VERSION:-unknown}"
echo "Done."
