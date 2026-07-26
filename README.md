# Dev Container Features

Dev container features published to GitHub Container Registry, following the
[devcontainers/feature-starter](https://github.com/devcontainers/feature-starter) conventions.

| Feature | Version | Description |
| --- | --- | --- |
| [`claude-code`](src/claude-code) | `0.0.2` | Installs Anthropic's Claude Code CLI with the recommended native installer — no Node.js required. |

> **The 0.x stream is experimental.** Expect breaking changes: options can be renamed, removed or have
> their defaults reversed in any release before `1.0.0`. Semver puts no compatibility promise on 0.x, so a
> patch bump may well break you. Pin the exact patch version, never the rolling `:0` / `:0.0` tags.

## Usage

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "remoteUser": "vscode",
    "features": {
        "ghcr.io/olibutzki/devcontainer-features/claude-code:0.0.2": {}
    },
    // Sign in automatically when the host has a token; falls back to browser
    // login when it does not. Safe to commit — see the notes.
    "remoteEnv": {
        "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
    },
    // Without this you sign in again after every rebuild.
    "mounts": [
        "source=claude-code-config-${devcontainerId},target=/home/vscode/.claude,type=volume"
    ]
}
```

The mount target must match your `remoteUser`'s home directory — see
[the feature's notes](src/claude-code/NOTES.md#persist-authentication-and-settings-across-rebuilds) for the
`CLAUDE_CONFIG_DIR` alternative and why the feature does not declare the mount itself.

The `remoteEnv` line has to live in `devcontainer.json`, because a feature cannot substitute a *host* value
(`${localEnv:...}` in a feature's `containerEnv` fails the Docker build, and `remoteEnv` is not a feature
property). Everything that makes that line actually work is handled by the feature:

* sets `hasCompletedOnboarding` in `~/.claude.json`, so a token login does not stall on the interactive
  setup screen ([anthropics/claude-code#8938](https://github.com/anthropics/claude-code/issues/8938));
* drops the credential when it arrives empty, so the same committed config also works for teammates who
  have no token on their host;
* sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, so the token authenticates Claude Code but is stripped from
  the environment of the subprocesses it spawns — the Bash tool, hooks and MCP servers — instead of being
  readable by anything the agent runs.

Details in [Signing in with a token](src/claude-code/NOTES.md#signing-in-with-a-token-claude_code_oauth_token).

The feature also installs Anthropic's editor integrations where the editor supports them: the
`anthropic.claude-code` VS Code extension and the `com.anthropic.code.plugin` JetBrains plugin
(*Claude Code [Beta]*, for IntelliJ IDEA and other IntelliJ-based IDEs).

## Relationship to the official Anthropic feature

Anthropic publishes [`ghcr.io/anthropics/devcontainer-features/claude-code`](https://github.com/anthropics/devcontainer-features/tree/main/src/claude-code).
This feature exists because that one installs via `npm` on a bootstrapped **Node 18**, while the
[setup docs](https://code.claude.com/docs/en/setup) now label the **native installer** as recommended and
the npm package requires **Node 22+**. It also exposes no options, so pinning a CLI version means
[dropping down to a Dockerfile](https://code.claude.com/docs/en/devcontainer#enforce-organization-policy).

Upstream's last commit is 25 June 2025 and issue
[#26 "Deprecated?"](https://github.com/anthropics/devcontainer-features/issues/26) (August 2025) is still
unanswered. Check those links before choosing — if upstream resumes maintenance, prefer it.

## Network egress is not part of this feature

This feature installs a CLI. It does not restrict where that CLI can connect, and Anthropic
[warns](https://code.claude.com/docs/en/devcontainer) that with `--dangerously-skip-permissions` a dev
container will not stop a malicious project from exfiltrating anything reachable inside it — including the
credentials in `~/.claude`.

For that boundary, use the template:

```
ghcr.io/olibutzki/devcontainer-templates/egress-firewall:0.0.1
```

```bash
devcontainer templates apply -t ghcr.io/olibutzki/devcontainer-templates/egress-firewall:0.0.1 -w .
```

It puts the dev container on a Docker network declared `internal: true` — no default route to the internet
at all — with a Squid sidecar as the only gateway, filtering HTTPS by hostname. That is stronger than the
in-container iptables script in Anthropic's reference container, which has to grant the workload container
`NET_ADMIN`/`NET_RAW`: the very capabilities needed to flush the rules confining it. It is a *template*
rather than a feature because a second container on a private network is a topology a feature cannot
create from inside an already-composed container.

The domains to allow, and the build-time caveat, are listed in
[`src/claude-code/NOTES.md`](src/claude-code/NOTES.md#restricting-network-egress).

## Repository layout

```
├── src/
│   └── claude-code/            # devcontainer-feature.json, install.sh, NOTES.md
├── test/
│   └── claude-code/            # test.sh + scenario tests
└── .github/workflows/
    ├── release.yaml            # publishes to ghcr.io (run manually from the Actions tab)
    └── test.yaml               # runs `devcontainer features test` on every push/PR
```

`src/<feature>/README.md` is **generated** from `devcontainer-feature.json` + `NOTES.md` by the release
workflow. Do not hand-edit it; edit `NOTES.md` instead.

## Distribution

Features publish to `ghcr.io/<owner>/devcontainer-features/<feature-id>` via the **Release dev container
features & Generate Documentation** workflow. Bump the `version` field in the feature's
`devcontainer-feature.json` (semver), then trigger the workflow manually on `main`.

First-time repository setup:

* The first publish creates the package as **private**. Open *Packages → devcontainer-features/claude-code
  → Package settings* and make it public, or grant the consuming repositories read access.
* Under *Settings → Actions → General → Workflow permissions*, allow read/write **and** enable *Allow
  GitHub Actions to create and approve pull requests*, otherwise the documentation PR step fails.

## Local development

```bash
npm install -g @devcontainers/cli

# autogenerated tests (default options)
devcontainer features test --skip-scenarios -f claude-code -i mcr.microsoft.com/devcontainers/base:ubuntu .

# scenario tests
devcontainer features test -f claude-code --skip-autogenerated --skip-duplicated .

# preview the generated docs
devcontainer features generate-docs -p ./src -n olibutzki/devcontainer-features \
    --github-owner olibutzki --github-repo devcontainer-features
```

## License

[MIT](LICENSE)
