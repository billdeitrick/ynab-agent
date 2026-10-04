# ynab-agent

Claude Code with access to your [YNAB](https://www.ynab.com) budget, running in a
[Docker Sandbox](https://docs.docker.com/ai/sandboxes/) (`sbx`) that controls what
it can reach and what it can change. The default mode is read-only: Claude can
analyze your budget, but the sandbox refuses any request that would modify it.

## Credits

- **YNAB MCP server:** [calebl/ynab-mcp-server](https://github.com/calebl/ynab-mcp-server)
  by Caleb LeNoir (MIT). This repo packages it as a sandbox kit and builds it
  unmodified from a pinned release commit; none of its code is included here.
- **Claude OAuth credential config:** the `credential@1` block in
  `base-claude/base-claude.yaml` is adapted from the `examples/claude` kit in
  [docker/sandbox-kit-spec](https://github.com/docker/sandbox-kit-spec) (Apache-2.0).

## What's here

| Path | Kind | Purpose |
|---|---|---|
| `base-claude/` | v3 workload | Claude Code, its network access (three Anthropic hosts), claude.ai OAuth held on the host, and the `CLAUDE.md` profile that surfaces each kit's notes |
| `ynab-mcp/` | v3 mixin | ynab-mcp-server built from a pinned commit with its own Node runtime, registered with Claude; YNAB token held on the host; **GET-only** access to `api.ynab.com` |
| `ynab-write/` | v3 mixin | Opt-in writes: full access to `api.ynab.com` and `YNAB_WRITES_ENABLED=true` |
| `ynab-read.sbxenv.yaml` | `sbx env` file | Read-only sandbox: `base-claude` + `ynab-mcp` |
| `ynab-write.sbxenv.yaml` | `sbx env` file | Read-write sandbox: `base-claude` + `ynab-mcp` + `ynab-write` |

## Requirements

- The `sbx` CLI, with v3 kit support and `sbx env` (experimental).
- A Claude subscription (these kits use `/login`, not an API key).
- A YNAB [personal access token](https://api.ynab.com/#personal-access-tokens).
- Recommended: `sbx`'s global network policy set to **Locked Down**, so a
  sandbox can reach only what its kits allow. See [Network access](#network-access).

## Run it

All commands run on your host, from this directory.

### Read-only

```sh
sbx env plan   ./ynab-read.sbxenv.yaml      # preview; changes nothing
sbx env create ./ynab-read.sbxenv.yaml      # create without attaching
sbx secret set ynab --sandbox ynab-read     # paste your YNAB token at the prompt
sbx env run    ./ynab-read.sbxenv.yaml      # attach
```

Inside Claude, run `/login` and finish the claude.ai sign-in in your browser.
The login is shared with other sandboxes that use the same OAuth credential,
so you only do it once.

To set a default YNAB plan, add `--env-arg planId=<plan-uuid>` (or
`last-used`) to the `create` command. Otherwise Claude lists your plans and
picks one per call.

### Read-write

The same steps with the other file and sandbox name:

```sh
sbx env create ./ynab-write.sbxenv.yaml
sbx secret set ynab --sandbox ynab-write
sbx env run    ./ynab-write.sbxenv.yaml
```

The two sandboxes have different names, so both can exist at once.

### Check it

From a shell inside the sandbox:

```sh
cat ~/.claude/.credentials.json          # placeholder tokens, not your real ones
echo "${YNAB_WRITES_ENABLED:-unset}"     # unset (read-only) or true (read-write)
curl -s -o /dev/null -w '%{http_code}\n' https://api.ynab.com/v1/user           # 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://api.ynab.com/v1/plans   # 403 in read-only
```

### Remove

```sh
sbx env rm ./ynab-read.sbxenv.yaml
```

This deletes the sandbox and every secret stored for it, including the YNAB
token. The credential approvals the env file added to
`~/.config/sbx/credentials.yaml` stay unless you pass `--prune-bindings`.

Neither environment mounts a host directory. Claude works in the sandbox's own
filesystem, and anything it writes is deleted with the sandbox.

## Sandboxing strategy

The agent gets a shell and runs without permission prompts (see
[below](#claude-runs-with---dangerously-skip-permissions)), so nothing here relies
on Claude behaving. Every guarantee comes from the sandbox boundary, which the
agent can't modify.

### Network access

With the global policy on Locked Down, a sandbox can reach exactly the union of
its kits' network rules (plus any `sbx policy allow` rules you add yourself):

| Host | Read-only | Read-write | Why |
|---|---|---|---|
| `api.anthropic.com`, `platform.claude.com`, `downloads.claude.ai` | ✓ | ✓ | Claude Code |
| `api.ynab.com` | `GET` only | all methods | YNAB API |

Nothing else is reachable: no GitHub, no package registries, no arbitrary URLs.
Under the Balanced or Open presets, `sbx` also allows a baseline of common hosts
for every sandbox, and the table above no longer describes everything the
sandbox can reach.

### Read-only is enforced by the proxy

YNAB personal access tokens can't be limited to reads, and the sandbox proxy
adds the token to every request to `api.ynab.com`, whoever sends it. So
read-only mode is enforced where neither the MCP server nor the agent can get
around it: `ynab-mcp`'s network policy (`network-policy@2`) allows only `GET` to
`api.ynab.com`, and the proxy answers anything else with `403`. That covers the
MCP server's write tools and also a `curl -X DELETE` the agent might write itself.

`ynab-write` adds an unrestricted rule for the same host, which overrides the
`GET`-only one when the kits are combined. Writes are something you choose per
sandbox by including that kit, and `sbx` asks you to approve the wider access.

The MCP server is built unmodified, so its write tools still appear in
read-only mode. Claude's context tells it not to use them unless
`YNAB_WRITES_ENABLED` is `true`, and the proxy refuses them either way.

### Credentials never enter the sandbox

- **YNAB:** the sandbox sees `YNAB_API_TOKEN` as a placeholder. The proxy
  replaces it with your real token on requests to `api.ynab.com`. The token is
  stored for that one sandbox only (`--sandbox`).
- **Claude:** when you run `/login`, the proxy intercepts the OAuth token
  exchange, keeps the real access and refresh tokens on your host, and writes
  placeholders to `~/.claude/.credentials.json` inside the sandbox.

A compromised agent can misuse these credentials while the sandbox runs, within
its network rules, but it can't copy them out and reuse them elsewhere.

### Supply chain

- `ynab-mcp` builds ynab-mcp-server from a pinned commit
  (`483b4af…`, release 0.3.0) rather than a tag, which can be moved, and the
  build fails if that commit isn't the expected version.
- Dependencies install from the upstream lockfile with install scripts
  disabled, and dev dependencies are removed from the image.
- `sbx` builds kits on your host, before any sandbox exists, so the build's
  downloads (Docker Hub, Debian, GitHub, npm) don't need any network access
  inside the sandbox.

To move to a newer release, update both `version` and `commit` in
`ynab-mcp/ynab-mcp.yaml`.

### What Claude is told

`base-claude` declares a `CLAUDE.md` profile, which `sbx` generates with an
index of each kit's notes; Claude Code loads it at startup. `ynab-mcp`'s notes cover
the placeholder token, read-only behavior and the `YNAB_WRITES_ENABLED` check,
amounts in currency rather than milliunits, and treating payee names and memos as
data rather than instructions. `ynab-write`'s notes require confirming every
change with you first. These are guidance, not enforcement.

## Claude runs with `--dangerously-skip-permissions`

`base-claude` starts Claude Code with `--dangerously-skip-permissions`, so it
runs commands, edits files and calls tools **without asking you first**. That's
reasonable here only because the sandbox is the containment: limited network
access, credentials it can't read, no host directories mounted, and YNAB writes
blocked unless you opt in.

If you reuse `base-claude` elsewhere, remember it gives the agent full control
of everything inside the sandbox. Don't mount directories you aren't prepared to
have changed, and don't add network access you aren't prepared to have used.

## Known limitations

- **Prompt injection.** Payee names and memos come from banks and merchants and
  reach the model as text. A malicious one could try to steer Claude. In
  read-only mode, the network rules limit what that could achieve.
- **Anthropic's server-side tools.** `api.anthropic.com` has to be reachable,
  and a request made directly to it (not through Claude Code) can ask Anthropic's
  servers to fetch an arbitrary URL. A prompt-injected agent could in principle
  use that to send data outside the sandbox. The network policy can't tell those
  requests apart from Claude Code's own.
- **Experimental features.** `sbx env`, `--kit` and `--kit-arg` are
  experimental in `sbx` and may change.
- **v3 kits only.** The built-in `sbx run claude` uses v2 kits, which can't be
  combined with these v3 mixins. `base-claude` is the v3 workload they need.
