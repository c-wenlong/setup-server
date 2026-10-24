# Security Policy

## Supported versions

This repo has no releases and no version numbers. Only the `main` branch is
supported: fixes land there, and a deployment is expected to re-run the
service's `setup.sh` from an up-to-date checkout.

| Branch | Supported |
| ------ | ------------------ |
| `main` | :white_check_mark: |
| anything else | :x: |

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a security problem.

Use GitHub's [private vulnerability reporting](https://github.com/c-wenlong/setup-server/security/advisories/new)
instead. GitHub only offers that form on public repositories; while this repo
is private, contact the maintainer directly (the email on the
[c-wenlong](https://github.com/c-wenlong) profile). Include:

- Which service directory is affected (or "repo-wide")
- A description of the issue and what an attacker could do with it
- Steps to reproduce, ideally as commands
- Your OS and Tailscale version

This is a personal project maintained by one person, so an acknowledgement may
take a few days.

## Scope notes

These are specific to how this repo works. Read them before reporting, because
some of them describe intended behaviour.

### The tailnet is the security boundary

Services bind `127.0.0.1` and are published tailnet-only through
`tailscale serve`. Tailscale device auth is deliberately the authentication
layer, so several services run with no login of their own (code-server and the
Syncthing GUI, for example). "Service X has no password" is a documented design
decision, not a vulnerability.

What *is* in scope: anything that puts a service on a LAN or public interface,
anything that leaks the tailnet boundary, and any path where `setup.sh` widens
exposure without saying so.

### `.env` files hold real, generated secrets

`setup.sh` generates admin passwords, database passwords and API tokens into
each service's `.env` on first run. `*/.env` is gitignored and must stay that
way.

**Never paste `.env` contents, tokens, password hashes or Syncthing device
identities into an issue, a PR, or pasted test output.** Redact them. If you
believe a secret was committed, report it privately rather than opening an
issue that points at it.

### Sanctioned non-loopback listeners

Three listeners in this repo are deliberately not on loopback. They are
documented, not oversights:

| Listener | Why | Bound to |
| --- | --- | --- |
| AdGuard Home DNS `:53` (tcp + udp) | Serve proxies HTTP, not UDP DNS | This node's tailnet IP, resolved at deploy time with `tailscale ip -4` |
| Syncthing BEP `:22000` (tcp + quic) | Peers dial the node directly, and QUIC is UDP | This node's tailnet IP, same resolution |
| gnome-remote-desktop RDP `:3389` | The daemon imports only GLib listener helpers that take no address, so no config makes it loopback-only | Wildcard, mitigated by nftables |

The first two stay tailnet-only and the live suites assert that. The third is
the exception worth understanding: an nftables table (`inet remote_desktop`,
its own unit, enabled by `services/remote-desktop/setup.sh`) is the only mitigation, and
it is verified by measured behaviour rather than by config. See the
remote-desktop row in [DIRECTORY.md](DIRECTORY.md) for exactly what was
measured. A report showing that table failing open is very much in scope.

### Out of scope

- Vulnerabilities in the upstream projects being deployed (Immich, Seafile,
  Vaultwarden and so on). Report those to their maintainers. A stale pinned
  version in a `docker-compose.yml` here is in scope.
- The `ollama` listener on `*:11434` noted in [DIRECTORY.md](DIRECTORY.md). No
  script in this repo installs or configures ollama; services here only point
  at an existing one. It is recorded as a loose end on the maintainer's box.
- Anything that requires already being on the tailnet **and** already having
  the credentials from a `.env`.
