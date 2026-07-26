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
# Minimum supported Claude Code version.
#
# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB, which this feature sets via containerEnv, arrived in 2.1.83. On an
# older release the variable is silently ignored: Claude Code still authenticates with the token, but every
# subprocess it spawns inherits the credential. Installing an older version would therefore hand out a
# configuration that looks hardened and is not, so refuse rather than warn.
# ---------------------------------------------------------------------------------------------------------
MIN_VERSION="2.1.83"

# version_lt A B -> true when A is strictly older than B.
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

too_old() {
    echo "(!) claude-code: version '$1' is older than the minimum supported ${MIN_VERSION}." >&2
    echo "    This feature sets CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 so the credential is stripped from the" >&2
    echo "    environment of the subprocesses Claude Code spawns. That variable does nothing before" >&2
    echo "    ${MIN_VERSION}, so an older pin would silently leak the token to every command the agent runs." >&2
    echo "    Use 'latest', 'stable', or an exact version >= ${MIN_VERSION}." >&2
    exit 1
}

# Reject an out-of-range pin before downloading anything. Channels ('latest'/'stable') resolve at install
# time and are checked against the installed version further down instead.
if printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' && version_lt "${VERSION}" "${MIN_VERSION}"; then
    too_old "${VERSION}"
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
# bubblewrap is not optional either: this feature sets CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1, and Claude Code
# implements the scrub by running subprocesses under bwrap. Without it, `claude` refuses to start at all
# ("bubblewrap is required for subprocess env scrubbing and isolation"), which fails the build.
#
# The supported Dev Container base images already ship bwrap, so this is a no-op there. It is kept for
# images built from a custom Dockerfile on a Debian/Ubuntu base, which often do not.
install_if_missing curl:curl bash:bash jq:jq bwrap:bubblewrap
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
# Make ~/.local/bin discoverable, including for login shells that do not source the user's rc files.
# Deliberately no /usr/local/bin/claude symlink: the native installer owns ~/.local/bin/claude and
# shadowing it confuses `claude update` and `claude doctor`.
# ---------------------------------------------------------------------------------------------------------
PROFILE_SNIPPET='/etc/profile.d/claude-code.sh'
mkdir -p /etc/profile.d
cat > "${PROFILE_SNIPPET}" <<'EOF'
# Added by the 'claude-code' dev container feature.
if [ -n "${HOME:-}" ] && [ -d "${HOME}/.local/bin" ]; then
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) ;;
        *) PATH="${HOME}/.local/bin:${PATH}" ;;
    esac
    export PATH
fi

# Forwarding a credential with "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}" in devcontainer.json expands to an
# EMPTY string when the host has no such variable -- the variable still ends up defined in the container.
# Claude Code would then see a credential that is present but blank instead of falling back to browser
# login, so drop empty ones.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then unset CLAUDE_CODE_OAUTH_TOKEN; fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then unset ANTHROPIC_API_KEY; fi
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then unset ANTHROPIC_AUTH_TOKEN; fi
EOF
chmod 0644 "${PROFILE_SNIPPET}"

for rc in /etc/bash.bashrc /etc/bashrc /etc/zsh/zshenv; do
    if [ -f "${rc}" ] && ! grep -q 'claude-code dev container feature' "${rc}" 2>/dev/null; then
        cat >> "${rc}" <<'EOF'

# Added by the 'claude-code' dev container feature.
if [ -n "${HOME:-}" ] && [ -d "${HOME}/.local/bin" ]; then
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) ;;
        *) export PATH="${HOME}/.local/bin:${PATH}" ;;
    esac
fi
# An unset host variable forwarded via ${localEnv:...} arrives as an empty string; drop it so Claude Code
# falls back to browser login rather than seeing a blank credential.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then unset CLAUDE_CODE_OAUTH_TOKEN; fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then unset ANTHROPIC_API_KEY; fi
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then unset ANTHROPIC_AUTH_TOKEN; fi
EOF
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
    if [ ! -f "${SETTINGS_FILE}" ]; then
        printf '{\n  "env": {\n    "%s": "%s"\n  }\n}\n' "${key}" "${value}" > "${SETTINGS_FILE}"
        return 0
    fi
    install_if_missing jq:jq
    if type jq >/dev/null 2>&1; then
        tmp="$(mktemp)"
        jq --arg k "${key}" --arg v "${value}" '.env = ((.env // {}) + {($k): $v})' "${SETTINGS_FILE}" > "${tmp}"
        mv "${tmp}" "${SETTINGS_FILE}"
    elif type python3 >/dev/null 2>&1; then
        python3 - "${SETTINGS_FILE}" "${key}" "${value}" <<'EOF'
import json, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    settings = json.load(fh)
settings.setdefault("env", {})[key] = value
with open(path, "w") as fh:
    json.dump(settings, fh, indent=2)
EOF
    else
        echo "(!) Could not merge ${key} into ${SETTINGS_FILE}: neither jq nor python3 available." >&2
        exit 1
    fi
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

# Smoke test. `claude --version` has to actually run: a CLI that cannot start -- because a dependency of
# the subprocess scrub is missing, say -- must fail the build here rather than bake a broken `claude` into
# the image and report success.
if ! VERSION_OUTPUT="$(run_as_user 'claude --version' 2>&1)"; then
    echo "(!) claude-code: installed, but 'claude --version' failed to run. Last lines:" >&2
    printf '%s\n' "${VERSION_OUTPUT}" | tail -5 | sed 's/^/    /' >&2
    exit 1
fi

INSTALLED_VERSION="$(printf '%s' "${VERSION_OUTPUT}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

# Catches what the pre-check cannot: a 'latest'/'stable' channel that resolved to something older than the
# minimum. Only enforced when the version actually parsed.
if [ -n "${INSTALLED_VERSION}" ] && version_lt "${INSTALLED_VERSION}" "${MIN_VERSION}"; then
    too_old "${INSTALLED_VERSION}"
fi

echo "Claude Code installed: ${INSTALLED_VERSION:-unknown}"
echo "Done."
