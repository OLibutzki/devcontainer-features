# Egress firewall

> **Generated from an experimental 0.x Template (`egress-firewall` 0.0.1).**
> These files are now yours and will not change under you — but if you re-apply
> or upgrade the Template, expect breaking changes while it is still on `0.x`:
> service and network names, this directory's layout, and the enforcement
> mechanism itself are all still subject to change.

This dev container has no route to the internet. Every outbound connection goes
through a Squid sidecar that allows only the hosts listed in
[`allowed-domains.txt`](./allowed-domains.txt) and refuses everything else.

```
        ┌──────────────────────── egress-external (bridge) ─────────► internet
        │
   ┌────┴──────┐
   │  egress   │  squid :3128 — default deny, allowlist by hostname
   │ (sidecar) │  HTTP: matches the request host
   │           │  HTTPS: matches the CONNECT host, then tunnels without decrypting
   └────┬──────┘
        │
        │  egress-internal   (internal: true — no gateway, no route off-host)
        │
   ┌────┴──────┐
   │    dev    │  your dev container
   │           │  HTTP_PROXY / HTTPS_PROXY → http://egress:3128
   └───────────┘
```

**Why this holds.** The dev container sits on a Docker network declared
`internal: true`, so Docker gives it no default route. Setting `HTTP_PROXY` is
not what restricts it — the missing route is. A process that unsets the proxy
variables does not escape the allowlist; it just loses the only path that
works. That is the difference between this and a plain proxy configuration.

## Adding a host

Edit `allowed-domains.txt`, one entry per line, then reload:

```bash
docker compose -f .devcontainer/docker-compose.yml restart egress
```

No rebuild is needed — the file is bind-mounted. Squid reads the ACL file only
at startup, so the restart is what makes the change take effect.

A **leading dot matches subdomains**, a bare entry does not:

| Entry | Matches | Does not match |
|---|---|---|
| `github.com` | `github.com` | `api.github.com` |
| `.github.com` | `github.com`, `api.github.com`, `raw.github.com` | — |

This is the single most common source of "I allowlisted it and it still doesn't
work".

## Finding out what was blocked

Every decision is logged to the sidecar's stdout. When something inside the
container fails to connect, the log names the host it wanted:

```bash
docker compose -f .devcontainer/docker-compose.yml logs egress | grep TCP_DENIED
```

Follow it live while you reproduce:

```bash
docker compose -f .devcontainer/docker-compose.yml logs -f egress
```

This turns "the tool mysteriously hangs" into a specific hostname you can make
a decision about, which is the point of the whole arrangement.

Mechanically, Squid writes to files under `/var/log/squid/` and the
`ubuntu/squid` entrypoint tails them to the container's stdout. Squid cannot
write to `/dev/stdout` directly — it drops to the unprivileged `proxy` user,
which cannot reopen Docker's stdout pipe, and dies with a `FATAL` if you tell
it to. If you swap `squidImage` for an image without that entrypoint, expect
`docker compose logs egress` to go quiet and read the log files instead.

## Verifying it is on

```bash
bash .devcontainer/egress/verify-egress.sh
```

Four checks: the proxy variables are set, an allowlisted host is reachable, a
non-allowlisted host is refused, and — the one that matters — bypassing the
proxy reaches nothing. Run it after any change to the Compose file.

## Build time is not covered

Dev Container **Features**, base image layers, and anything else pulled by the
devcontainer CLI or the Docker daemon are fetched over the *host* network,
before the restricted container exists. They are not filtered.

The allowlist covers what runs **inside** the started container: `postCreateCommand`,
`npm install`, `pip install`, your agent, your tests. If you need the build
itself constrained, that is a separate mechanism (a build-time proxy or a
pre-vetted base image), not this one.

## Limitations

Stated plainly, because a security control you misjudge is worse than none.

- **No SSH.** `git@github.com:...` will not work — use HTTPS remotes. Squid
  could tunnel port 22 via CONNECT, but that needs a `ProxyCommand` on the
  client and a wider `Safe_ports`; it is deliberately not enabled here.
- **No ICMP, no raw sockets, no arbitrary TCP.** Only HTTP and HTTPS, only
  through the proxy. `ping`, `dig` against external resolvers, and database
  connections to external hosts all fail.
- **DNS is a residual channel.** The container still reaches Docker's embedded
  resolver at `127.0.0.11`, which forwards to the host's resolvers. Name
  resolution therefore still succeeds even where connections do not, and a
  determined process could tunnel data out over DNS queries. This setup does
  not close that. It restricts *connections*, not *all information flow*.
- **Granularity is the domain.** Allowlisting `github.com` allowlists all of
  GitHub, including repositories you did not intend. Filtering by URL path
  would require TLS interception (SSL bump), which was deliberately avoided so
  that no CA has to be trusted inside the container.
- **A compromised host Docker daemon is out of scope**, as is anything with
  access to the Docker socket. Do not mount the Docker socket into this
  container and expect the firewall to still mean anything.

## docker-in-docker in this repository

This project adds the `docker-in-docker` Feature, because its test suite builds
and runs real containers. That is *not* the socket mount the previous section
warns about — there is no path to the host daemon here. The inner daemon runs in
this container's network namespace, so the containers it starts inherit the same
dead end: their default route is this container, which has no route off
`egress-internal`. Their traffic reaches the same Squid and the same allowlist.

Two consequences worth knowing:

- The proxy is addressed as `http://10.99.0.2:3128`, not `http://egress:3128`.
  Inner containers are not on the Compose network and cannot resolve the service
  name; a pinned address works from both sides.
- `privileged: true` is required by the Feature. It hands out capabilities
  inside this container's namespaces — it does not conjure an interface that
  reaches the internet, so the boundary is unchanged. `verify-egress.sh` is
  what settles that; run it after any change here.

### Why the feature tests work in here

The builds those tests run are *proxied* — they happen on the inner daemon,
inside the boundary — and that is a stricter environment than the host. It
found a real bug, fixed in `claude-code` 0.0.2: `install.sh` runs the native
installer through `su - "${USERNAME}"`, a login shell starts from a clean
environment, so `HTTP_PROXY` never reached `curl` and the build died on
`Could not resolve host: claude.ai`. `apt-get` in the same build worked, because
it runs as root in the RUN environment — which is what made it confusing.

`post-create.sh` writes the `proxies` block in `~/.docker/config.json`; that is
what makes the Docker CLI pass the proxy into every build as an implicit build
arg. Without it the inner builds have no proxy to forward and the failure comes
back.

So run the matrix in here — it exercises a path the host cannot:

```bash
devcontainer features test --skip-scenarios -f claude-code -i mcr.microsoft.com/devcontainers/base:ubuntu .
devcontainer features test -f claude-code --skip-autogenerated --skip-duplicated .
```

## Files

| File | Purpose |
|---|---|
| `allowed-domains.txt` | The allowlist. This is the file you edit. |
| `squid.conf` | The policy: default deny, allow allowlisted hosts, log everything. |
| `verify-egress.sh` | Proves enforcement from inside the container. |
| `../docker-compose.yml` | The network topology that makes the policy unavoidable. |
