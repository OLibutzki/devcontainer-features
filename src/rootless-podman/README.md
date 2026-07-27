
# Rootless Podman (rootless-podman)

Installs rootless Podman as a Docker-compatible container engine (DOCKER_HOST, testcontainers, docker CLI via podman-docker) without requiring a privileged container.

## Example Usage

```json
"features": {
    "ghcr.io/olibutzki/devcontainer-features/rootless-podman:0": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|


> **Experimental (`0.x`).** Breaking changes are likely: behavior may change in any release before
> `1.0.0`. Pin the exact patch version, never the rolling `:0` tag.

## What this feature does

Installs [Podman](https://podman.io) to run **rootless** — as the container's remote user, not root — and
configures it as a drop-in, Docker-compatible engine:

* Packages: `podman`, `uidmap` (`newuidmap`/`newgidmap`), `slirp4netns` and `passt` (rootless networking —
  Podman 5.x prefers `pasta`, from `passt`, and only falls back to `slirp4netns` if it is missing),
  `fuse-overlayfs` (overlay storage without native kernel support) and `catatonit` (Podman's default init).
* Reserves a subuid/subgid range for the remote user in `/etc/subuid`/`/etc/subgid` — idempotent, so a range
  already assigned by the base image or `common-utils` is left untouched.
* Writes `/etc/containers/storage.conf` with `driver = "overlay"` and
  `mount_program = "/usr/bin/fuse-overlayfs"`, unless one already exists.
* Sets `XDG_RUNTIME_DIR` and `DOCKER_HOST` to a fixed path (`/var/lib/rootless-podman/run`), *not* under the
  remote user's home directory — see "Why this lives outside `$HOME`" below.
* Installs a `postStartCommand` script that starts `podman system service` in the background on every
  container start/attach (idempotent — a no-op if the socket is already answering).

There is deliberately **no version option**: Debian/Ubuntu ship one Podman version per release, and pinning
a different one would mean a third-party repository, which is out of scope here.

## Example

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "remoteUser": "vscode",
    "features": {
        "ghcr.io/olibutzki/devcontainer-features/rootless-podman:0.0.2": {}
    },
    // Required for rootless Podman to actually start containers -- see below for why the feature
    // cannot add these two lines itself.
    "runArgs": [
        "--device=/dev/fuse",
        "--device=/dev/net/tun"
    ]
}
```

Without `--device=/dev/fuse`, `podman run` fails with `fuse: device not found`. Without
`--device=/dev/net/tun`, rootless networking via `slirp4netns` fails with
`open(/dev/net/tun): No such file or directory`.

## Why `/dev/fuse` and `/dev/net/tun` are not automatic

The feature already declares `capAdd: ["SYS_ADMIN"]` and the two `securityOpt` entries it needs
(`seccomp=unconfined`, `apparmor=unconfined`) directly in `devcontainer-feature.json` — those are regular,
aggregating top-level Feature properties, so no consumer action is needed for them.

`systempaths=unconfined` is **deliberately not** among them. That option removes Docker's default masking
and read-only binds on `/proc` and `/sys` — exposing host-global kernel tunables such as
`/proc/sys/kernel/core_pattern` (a classic container→host escalation primitive), `/proc/sysrq-trigger`
(host DoS) and `/proc/kcore` (raw kernel memory). Rootless Podman does not need any of that: it creates its
user/mount namespaces and mounts `fuse-overlayfs` without writing to those paths. Un-masking them only
widens the container→host attack surface, so the entry was dropped. If a future Podman release genuinely
needs one masked path, add that single path back — never re-enable the blanket `systempaths=unconfined`.

## Security posture — what this feature costs you

State it plainly, because a control you misjudge is worse than none. `capAdd: SYS_ADMIN` plus
`seccomp=unconfined` and `apparmor=unconfined` **materially lower the isolation between this container and
the host.** `SYS_ADMIN` is the most powerful Linux capability, and with both mandatory-access-control
profiles off, a process that reaches **root inside the container** (note: the `vscode` user on the standard
Dev Container base images has passwordless `sudo`) has a broad kernel attack surface. This is close to what
`privileged: true` would grant on the capability/profile axis — the feature avoids `privileged` on the
*device* axis, not this one.

Whether that root-in-container position can actually reach the *host* depends on the outer engine:

* **With user-namespace remapping** (rootless Docker/Podman daemon, or `userns-remap` on a rootful daemon),
  container-root maps to an unprivileged host UID, which neutralises most `SYS_ADMIN`-based escapes. **This
  is the recommended way to run any container that uses this feature.**
* **Without it** (a default rootful Docker daemon, common on Linux CI runners and WSL2), container-root *is*
  host-root, and the grants above are a real escape surface.

Do not install this feature on a host that runs untrusted or multi-tenant workloads unless the outer engine
is userns-remapped. It is built for a single-developer dev container, where the trust boundary is the
developer's own machine.

Device access is different. Bind-mounting a device node (`"mounts": ["source=/dev/fuse,target=/dev/fuse,type=bind"]`)
makes the file *visible* inside the container, but the container engine's device cgroup still blocks
`open()`/`ioctl()` on it with `Operation not permitted` — only `--device` (or the much broader
`privileged: true`) makes the engine add the matching device cgroup allow-rule. The Feature metadata schema
has no top-level key for individual device rules, and this feature does not set `privileged: true`: that
would hand out access to every device on the host, which defeats the point of a *rootless* feature. So the
two `--device` lines stay a **consumer-side `runArgs` entry**, the same pattern this repo already uses for
forwarding `CLAUDE_CODE_OAUTH_TOKEN` in `claude-code`.

CI verifies that this actually works, not just that it installs: the `device_access` test scenario adds
both `--device` lines and runs a real `podman run hello-world` — the same runArgs a consumer adds. The
default test scenario (no `runArgs`) only checks installation artifacts, since without the devices a real
container start would fail regardless of whether the feature is set up correctly.

## `docker` CLI compatibility

The feature also installs `podman-docker`, a Debian/Ubuntu transitional package that puts `/usr/bin/docker`
in place as a thin wrapper execing `podman`, plus an empty `/etc/containers/nodocker` marker file (without
it, every `docker` invocation prints "Emulate Docker CLI using podman. Create /etc/containers/nodocker to
quiet msg." on stderr). This is for tools that shell out to a `docker` binary directly rather than talking
to the Docker API socket -- for example `@devcontainers/cli`, which is how this collection's own dev
container runs the feature test matrix against rootless Podman instead of docker-in-docker. Installation is
skipped if a real `docker` is already on `PATH`, so this stays inert alongside
docker-in-docker/docker-outside-of-docker (see "Don't combine" below).

## Docker / Testcontainers compatibility

`DOCKER_HOST` points at the rootless Podman API socket, and `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` /
`TESTCONTAINERS_RYUK_DISABLED=true` are set so [Testcontainers](https://testcontainers.com) talks to that
socket instead of expecting a Docker daemon. (Ryuk, Testcontainers' cleanup sidecar, needs privileges
rootless Podman does not grant, so it is disabled — containers this feature starts are not
auto-reaped between runs.)

### Why this lives outside `$HOME`

`containerEnv` values in a Feature must be literal, static strings — they cannot reference `$HOME` or the
consumer's `remoteUser` (which this feature does not and cannot know at authoring time; it works with any
`remoteUser`, not just `vscode`). Putting the runtime directory under `/var/lib/rootless-podman` instead of
`~/.local/share/containers/runtime` sidesteps that constraint, at the cost of the directory not living on
any volume you might mount over the user's home.

### Why the runtime directory is created at container start, not at build time

Only the base path (`/var/lib/rootless-podman`, mode `1777`) is created during the image build. The actual
`run` subdirectory is created — and owned — by the `postStartCommand` script every time the container
starts, not by `install.sh`. This matters because Dev Container CLI's `updateRemoteUserUID` (on by default
on Linux hosts, though not on Docker Desktop for Mac/Windows) changes the remote user's UID *after* the
image is built, to match the local user. A directory chowned at build time would end up owned by a UID
nobody uses anymore, and `mkdir`/`podman system service` would then fail with `Permission denied` on first
container start — which is exactly what happened in CI before this was fixed. Creating the directory fresh
in `postStartCommand`, once the user's final UID is already in effect, avoids that entirely.

## Don't combine with docker-in-docker / docker-outside-of-docker

Both of those features also set `DOCKER_HOST`. Feature `containerEnv` values are merged in installation
order (and a consumer's own `containerEnv` wins over any feature), so combining them means whichever value
applies last silently overrides this feature's socket path. Pick one container engine per devcontainer.

## Persistence

No volume is set up for Podman's storage: it lives under the container's root filesystem and is discarded
on rebuild, same as any other container-local state. That is deliberate — mounting it would require knowing
the remote user's home directory, which this feature does not assume. If you need images/containers to
survive rebuilds, mount a volume over `/var/lib/rootless-podman` yourself.

## OS support

Debian/Ubuntu-based **Dev Container** images — CI covers `mcr.microsoft.com/devcontainers/base:ubuntu` and
`:debian`. A non-apt base fails the build with a clear message.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/olibutzki/devcontainer-features/blob/main/src/rootless-podman/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
