#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Starts (or verifies) the rootless Podman API socket used for Docker compatibility (DOCKER_HOST).
#
# Runs from postStartCommand, which already executes as the container's remoteUser -- no `su` needed here,
# same as claude-code-onboarding.sh. Idempotent: safe to run on every container start/attach.
#-------------------------------------------------------------------------------------------------------------
set -euo pipefail

# install.sh always sets this via containerEnv; the fallback only matters if someone invokes this by hand.
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/lib/rootless-podman/run}"
SOCKET_DIR="${RUNTIME_DIR}/podman"
SOCKET_PATH="${SOCKET_DIR}/podman.sock"
LOG_FILE="${RUNTIME_DIR}/podman-service.log"

mkdir -p "${SOCKET_DIR}"

# Already running and answering? Nothing to do.
if [ -S "${SOCKET_PATH}" ] && podman --url "unix://${SOCKET_PATH}" info >/dev/null 2>&1; then
    echo "rootless-podman: API socket already running at ${SOCKET_PATH}."
    exit 0
fi

# Stale socket file from a service that is no longer alive.
[ -e "${SOCKET_PATH}" ] && rm -f "${SOCKET_PATH}"

echo "rootless-podman: starting 'podman system service' ..."
nohup podman system service --time=0 "unix://${SOCKET_PATH}" >"${LOG_FILE}" 2>&1 &
disown

# Poll for the socket: podman forks and binds the socket asynchronously, not instantly.
for _ in $(seq 1 30); do
    [ -S "${SOCKET_PATH}" ] && break
    sleep 0.5
done

if [ ! -S "${SOCKET_PATH}" ]; then
    echo "(!) rootless-podman: socket did not appear at ${SOCKET_PATH} within 15s. Log:" >&2
    tail -20 "${LOG_FILE}" >&2 2>/dev/null || true
    exit 1
fi

echo "rootless-podman: API socket ready at ${SOCKET_PATH}."
