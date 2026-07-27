#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Installs rootless Podman (podman, uidmap, slirp4netns, fuse-overlayfs, catatonit, podman-docker), reserves
# a subuid/subgid range for the target user, configures fuse-overlayfs as the storage driver, and installs
# the postStartCommand script that starts `podman system service` for Docker API compatibility.
#
# Debian/Ubuntu only. See NOTES.md for the runArgs the CONSUMER must still add (--device=/dev/fuse and
# --device=/dev/net/tun) -- the feature cannot declare those reliably via feature metadata, see NOTES.md
# "Why /dev/fuse and /dev/net/tun are not automatic".
#-------------------------------------------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_BASE="/var/lib/rootless-podman"
RUNTIME_DIR="${RUNTIME_BASE}/run"
SUBID_START=200000
SUBID_COUNT=65536

if [ "$(id -u)" -ne 0 ]; then
    echo "(!) This feature needs to be installed as root. Run it in a devcontainer build, not by hand." >&2
    exit 1
fi

if ! type apt-get >/dev/null 2>&1; then
    echo "(!) This feature only supports Debian/Ubuntu-based images (no apt-get found)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------------------------
# Packages. All in the default Debian/Ubuntu repos on every release the Dev Container base images use:
# podman, uidmap (newuidmap/newgidmap), slirp4netns, fuse-overlayfs, catatonit, passt.
#
# passt (which provides the `pasta` binary) is required even though slirp4netns is also installed: Podman
# 5.x prefers `pasta` for rootless networking and only falls back to slirp4netns if pasta is absent from
# PATH -- without it, `podman run` fails outright with "could not find pasta ... exec: pasta not found".
# Verified by actually running `podman run hello-world` rootless with only slirp4netns installed (fails)
# and with passt added (succeeds).
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
# Resolve the user to install for -- generic, not hardcoded to "vscode". Rootless Podman for root is
# meaningless, so (unlike claude-code) there is no root fallback: fail loudly instead of silently installing
# something that does not do what the feature promises.
# ---------------------------------------------------------------------------------------------------------
USERNAME=""
for candidate in "${_REMOTE_USER:-}" "${_CONTAINER_USER:-}" vscode node codespace; do
    if [ -n "${candidate}" ] && id -u "${candidate}" >/dev/null 2>&1; then
        USERNAME="${candidate}"
        break
    fi
done

if [ -z "${USERNAME}" ] || [ "${USERNAME}" = "root" ]; then
    echo "(!) rootless-podman: no non-root remote user found; rootless Podman needs a non-root user to be meaningful." >&2
    exit 1
fi

USER_HOME="$(getent passwd "${USERNAME}" | cut -d: -f6)"
if [ -z "${USER_HOME}" ] || [ ! -d "${USER_HOME}" ]; then
    echo "(!) Could not determine a home directory for '${USERNAME}'." >&2
    exit 1
fi
USER_GROUP="$(id -gn "${USERNAME}")"

echo "Installing rootless Podman for user '${USERNAME}' ..."

install_if_missing podman:podman newuidmap:uidmap slirp4netns:slirp4netns fuse-overlayfs:fuse-overlayfs pasta:passt
# catatonit ships no long-lived command to probe with `type`; check the package directly.
dpkg -s catatonit >/dev/null 2>&1 || apt_install catatonit

# ---------------------------------------------------------------------------------------------------------
# podman-docker: a transitional Debian/Ubuntu package that installs /usr/bin/docker as a thin wrapper
# execing podman, plus /etc/containers/nodocker (suppresses podman's "Emulate Docker CLI using podman"
# warning). Tools that only know how to shell out to a `docker` binary -- notably `@devcontainers/cli`
# itself, which is how this repo's own dev container runs the feature test matrix -- work against podman
# through this without any DOCKER_HOST/socket involvement. Only installed if `docker` is not already on
# PATH, so this stays a no-op alongside docker-in-docker/docker-outside-of-docker (NOTES.md already tells
# consumers not to combine those with this feature; a real docker binary always wins here).
# ---------------------------------------------------------------------------------------------------------
type docker >/dev/null 2>&1 || apt_install podman-docker

# ---------------------------------------------------------------------------------------------------------
# Reserve a subuid/subgid range. Idempotent: if the user already has an entry (some base images/useradd
# defaults assign one automatically), it is left alone rather than appending a second, possibly colliding
# range. If the fixed range we would reserve is already taken by someone else, fail loudly instead of
# silently corrupting user-namespace mappings.
# ---------------------------------------------------------------------------------------------------------
if grep -q "^${USERNAME}:" /etc/subuid 2>/dev/null; then
    echo "rootless-podman: '${USERNAME}' already has a subuid range, leaving it as-is."
else
    if grep -q ":${SUBID_START}:" /etc/subuid 2>/dev/null; then
        echo "(!) rootless-podman: subuid range starting at ${SUBID_START} is already taken by another user." >&2
        exit 1
    fi
    usermod --add-subuids "${SUBID_START}-$((SUBID_START + SUBID_COUNT - 1))" "${USERNAME}"
fi
if grep -q "^${USERNAME}:" /etc/subgid 2>/dev/null; then
    echo "rootless-podman: '${USERNAME}' already has a subgid range, leaving it as-is."
else
    if grep -q ":${SUBID_START}:" /etc/subgid 2>/dev/null; then
        echo "(!) rootless-podman: subgid range starting at ${SUBID_START} is already taken by another user." >&2
        exit 1
    fi
    usermod --add-subgids "${SUBID_START}-$((SUBID_START + SUBID_COUNT - 1))" "${USERNAME}"
fi

# ---------------------------------------------------------------------------------------------------------
# Storage config: fuse-overlayfs as the overlay mount program (rootless overlay without native kernel
# support requires it). Left alone if a storage.conf already exists -- non-destructive, like the jq-merge
# pattern used elsewhere in this repo, just without a merge tool for a non-JSON format.
# ---------------------------------------------------------------------------------------------------------
if [ -f /etc/containers/storage.conf ]; then
    echo "rootless-podman: /etc/containers/storage.conf already exists, leaving it untouched."
else
    mkdir -p /etc/containers
    printf '%s\n' \
        '[storage]' \
        'driver = "overlay"' \
        '' \
        '[storage.options]' \
        '' \
        '[storage.options.overlay]' \
        'mount_program = "/usr/bin/fuse-overlayfs"' \
        > /etc/containers/storage.conf
fi

# ---------------------------------------------------------------------------------------------------------
# Runtime base directory. Deliberately NOT under the user's home: this feature must work for any remoteUser,
# not just vscode, so the home path is unknown at authoring time -- but devcontainer-feature.json needs a
# literal, static path for containerEnv. A path outside HOME sidesteps that constraint entirely.
#
# The actual "run" subdirectory is NOT created/chowned here on purpose. Dev Container CLI's
# updateRemoteUserUID (on by default on Linux hosts) changes the remote user's UID at CONTAINER START,
# after this build-time script already ran -- a directory chowned to the build-time UID would end up owned
# by a UID that no longer belongs to anyone, and the (now different) user could not write to it. So this
# only prepares a sticky, world-writable base; rootless-podman-start.sh creates and owns "run" fresh on
# every container start, once the user's final UID is already in effect.
# ---------------------------------------------------------------------------------------------------------
mkdir -p "${RUNTIME_BASE}"
chmod 1777 "${RUNTIME_BASE}"

# ---------------------------------------------------------------------------------------------------------
# Run as the target user. See claude-code/install.sh for the reasoning on why `su -` starts a login shell
# with a clean environment and why proxy vars must be re-exported across that boundary.
# ---------------------------------------------------------------------------------------------------------
PROXY_EXPORTS=""
for proxy_var in HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy; do
    proxy_value="${!proxy_var-}"
    [ -n "${proxy_value}" ] || continue
    proxy_value="$(printf '%s' "${proxy_value}" | sed "s/'/'\\\\''/g")"
    PROXY_EXPORTS="${PROXY_EXPORTS}export ${proxy_var}='${proxy_value}'; "
done

run_as_user() {
    # XDG_RUNTIME_DIR is set explicitly here (not just via containerEnv) because `su -` starts a login
    # shell with a clean environment, and podman would otherwise default to a path under $HOME.
    su - "${USERNAME}" -c "${PROXY_EXPORTS}export XDG_RUNTIME_DIR='${RUNTIME_DIR}'; $1"
}

# Reinitialize storage under the new config now, as the target user, rather than lazily on first `podman run`.
# The runtime dir only needs to exist for this and the smoke test below; it is removed again at the very end
# so the image does not ship it pre-owned by a UID that updateRemoteUserUID may later replace.
mkdir -p "${RUNTIME_DIR}"
chown "${USERNAME}:${USER_GROUP}" "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}"
run_as_user 'podman system migrate' || true

install -m 0755 "${SCRIPT_DIR}/scripts/rootless-podman-start.sh" /usr/local/bin/rootless-podman-start.sh

rm -rf /var/lib/apt/lists/*

# Smoke test. Deliberately only `podman --version`: a real `podman info`/`podman run` needs /dev/fuse and
# /dev/net/tun, which are not present during `docker build` (no --device at build time) even on a correctly
# configured consumer container. Testing more than "the binary runs for this user" here would make the build
# fail on images that are otherwise correctly set up -- see NOTES.md.
if ! VERSION_OUTPUT="$(run_as_user 'podman --version' 2>&1)"; then
    echo "(!) rootless-podman: installed, but 'podman --version' failed to run. Last lines:" >&2
    printf '%s\n' "${VERSION_OUTPUT}" | tail -5 | sed 's/^/    /' >&2
    exit 1
fi

rm -rf "${RUNTIME_DIR}"

echo "Rootless Podman installed: ${VERSION_OUTPUT}"
echo "Done."
