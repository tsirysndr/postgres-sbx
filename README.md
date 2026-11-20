# postgres-sbx

PostgreSQL in a [bsdkrun](https://github.com/tsirysndr/bsdkrun) microVM, with
**branchable data**: the data directory is a ZFS branch you fork copy-on-write,
switch between, and throw away, like `git branch` for your database. Drizzle
Studio, drizzle-kit, [pgroll](https://pgroll.com) migrations, `psql` and
[pgcli](https://www.pgcli.com) are all wired to it.

```sh
postgres-sbx start                 # boots PostgreSQL 18 in a VM, port 5432 on 127.0.0.1
postgres-sbx checkout -b feature   # fork the data, mount the fork
postgres-sbx migrate up            # try a pgroll migration on it
postgres-sbx studio                # look at it in Drizzle Studio
postgres-sbx checkout main         # back to the untouched data
postgres-sbx branch -d feature     # done with it
```

The sandbox uses one ZFS volume named `postgres-sbx` and records its settings
under `~/.config/postgres-sbx`. Linux servers run as containers in the shared
Docker VM. FreeBSD/NetBSD servers run inside the tool's BSD VM. Parallel
instances share the pool but use separate datasets and database processes.
Host tools connect through each server's own forwarded port.

Written in PureScript on the [bsdkrun PureScript
SDK](https://github.com/tsirysndr/bsdkrun-purescript).

## Requirements

| What | Why |
| --- | --- |
| [bsdkrun](https://github.com/tsirysndr/bsdkrun#install) 0.12.1 or newer | runs the VM and the ZFS volume (`brew install tsirysndr/tap/bsdkrun`) |
| macOS on Apple Silicon, or Linux with KVM | what bsdkrun supports |
| Node.js 22 or newer | runs the tool, drizzle-kit and Studio |
| `uv` or `pipx` (optional) | runs `pgcli` without installing it by hand |
| Homebrew (optional) | `postgres-sbx setup` installs pgroll with it; otherwise the release binary goes to `~/.local/bin` |

`postgres-sbx doctor` checks all of it.

## Install

From a checkout, with the
[bsdkrun-purescript](https://github.com/tsirysndr/bsdkrun-purescript) SDK next
to it (see `spago.yaml` to point at the git repository instead):

```sh
npm install        # also builds (spago)
npm link           # puts `postgres-sbx` on your PATH
postgres-sbx doctor
```

### Single binary

```sh
npm run build:bin  # needs bun; writes dist/postgres-sbx
```

The binary bundles the tool, the SDK and the `pg` driver. drizzle-kit cannot be
bundled (it ships esbuild's native binary and runs as its own process), so
`studio` and `drizzle` look for a `drizzle-kit` on PATH when run from the
binary: `npm i -g drizzle-kit drizzle-orm pg`. pgroll and pgcli are external
tools either way.

## Commands

```
start      Start the sandbox, creating the VM and its data volume on first run
stop       Stop the VM (data stays on its branch)
status     Show the VM, the mounted branch and the connection URL
ssh        Open a shell in the VM (alias: shell)
exec       Run a command in the VM with your stdin, stdout and stderr bound to it (-t for a PTY)
log        Show the VM console log, -f to follow (alias: logs)
branch     List data branches, create one (copy-on-write) or delete one
checkout   Switch the data directory to BRANCH, -b to create it first (alias: switch)
psql       Open psql on the sandbox database
pgcli      Open pgcli (auto-completion, syntax highlighting) on the sandbox database
url        Print the connection URL
studio     Open Drizzle Studio on the sandbox database
drizzle    Run drizzle-kit with DATABASE_URL pointing at the sandbox
doctor     Check bsdkrun, the hypervisor, Node, drizzle-kit, pgcli and pgroll
destroy    Remove the VM and the data volume with every branch (asks first)

Migrations:
migrate    Schema migrations with pgroll: init, new, up, start, complete, rollback, status, pull, baseline
pgroll     Run pgroll with the sandbox URL (any pgroll arguments)
setup      Install pgroll on this host and initialise it in the sandbox
```

Every command has `--help`.

## Starting

```sh
postgres-sbx start                              # linux, postgres:18
postgres-sbx start linux 16-alpine              # any tag of the postgres image
postgres-sbx start linux ghcr.io/you/pg:dev     # or a full image reference
postgres-sbx start freebsd 15.1                 # PostgreSQL 18 from pkg
postgres-sbx start netbsd                       # PostgreSQL 18 from pkgsrc
```

| Option | Default | |
| --- | --- | --- |
| `--port, -p PORT` | 5432 | host port forwarded to the server; change it on a later start (the VM is recreated, the data stays) |
| `--user NAME` | postgres | superuser |
| `--password SECRET` | postgres | its password |
| `--db NAME` | postgres | database created on first start |
| `--cpus N` | 2 | changeable on a later start |
| `--mem MIB` | 1024 | changeable on a later start |
| `--branch, -b BRANCH` | the current one | data branch to mount |
| `--size SIZE` | 10G | data volume size when it is created (sparse) |
| `-d, --detach` | off | quiet start: no VM console or provisioning output, only the status lines |

The first `start` creates the volume and the VM and waits for the server to
accept connections. Later starts resume the same VM; the OS, version and credentials are fixed
for the life of the sandbox (`destroy` to change them), while `--port`,
`--cpus` and `--mem` can be changed on any start.
While it starts, the VM console and, on BSD, the package installation stream
to the terminal; `start -d` keeps the start quiet.
Credentials and the database are applied when a data branch is first
initialised: on Linux through the image's `POSTGRES_*` environment, on BSD by
the provisioning script.

On Linux the server is a **container in bsdkrun's shared Docker engine VM**
(`bsdkrun-docker`), not a VM of its own: one VM serves every Linux sandbox on
the host, and a second database costs a container. `start` creates the engine
the first time (2 vCPU, 2048 MiB; `bsdkrun docker start --cpus N --mem M`
sizes it), attaches the data volume to it (a new disk needs the engine
restarted once; its other containers come back by themselves), and runs
`postgres:18` with the branch bind-mounted at the data directory and the host port
published on 127.0.0.1. The container is disposable and recreated from the
recorded settings whenever `--port` or the branch change; `stop` stops the
container only, the engine stays for the others. `--cpus` and `--mem` size a
BSD VM and are not applied to the container: the engine's kernel has no CPU
scheduler limits, so the engine's own size is the limit.

On FreeBSD and NetBSD the root disk is grown to make room for the packages
(NetBSD reboots once after resizing; `start` rides that out), then the first
start installs the server with `pkg` / `pkgin` (bootstrapped from the pkgsrc
CDN on a fresh NetBSD guest), runs `initdb` on the data branch, opens `listen_addresses` and
`pg_hba.conf` for the host, and creates the role and database. The same script
runs on every start and is idempotent. These guests are scripted but have had
less exercise than Linux; `postgres-sbx log` shows what happened.

## Branches

The data directory lives on a ZFS branch inside the sandbox's volume. Branches
are ZFS clones: forking is instant and costs nothing until the branches diverge.

```sh
postgres-sbx branch                 # list; * marks the mounted one (also: branch ls)
postgres-sbx branch staging         # fork and start a parallel instance
postgres-sbx branch hotfix --from main
postgres-sbx checkout staging       # stop, remount, start: ~40s on Linux
postgres-sbx checkout -b try-this   # fork and switch in one go
postgres-sbx branch -d try-this     # delete (also: branch rm NAME); not main, not the mounted one
```

`checkout` restarts the server on the other branch, so connections drop. A
branch keeps everything its parent had at fork time, credentials included.
Forking while the VM is stopped boots a short-lived FreeBSD helper to do it
(about 15 seconds).

## Drizzle Studio and drizzle-kit

Both run on the host, from this package's `node_modules`.

```sh
postgres-sbx studio                 # https://local.drizzle.studio, server on 127.0.0.1:4983
postgres-sbx studio --port 5000 --host 0.0.0.0
postgres-sbx drizzle push           # drizzle-kit push against the sandbox
postgres-sbx drizzle generate
postgres-sbx drizzle migrate
```

`drizzle` runs drizzle-kit in the current directory with `DATABASE_URL` set to
the sandbox, so a project's `drizzle.config.ts` can read
`process.env.DATABASE_URL`. If the directory has no drizzle config, one that
points at the sandbox is supplied (`~/.config/postgres-sbx/drizzle.config.ts`,
dialect `postgresql`, no schema).

## Migrations with pgroll

[pgroll](https://pgroll.com) does zero-downtime, reversible schema migrations:
`start` creates the new schema version beside the old one, `complete` retires
the old one. `postgres-sbx migrate` wraps it with the sandbox URL and the
`migrations/` directory filled in.

```sh
postgres-sbx setup                  # installs pgroll (brew or ~/.local/bin), runs pgroll init
postgres-sbx migrate new add_users  # migrations/01_add_users.yaml (interactive; --empty for a stub)
postgres-sbx migrate up             # apply what is outstanding in migrations/ and complete it
postgres-sbx migrate status
postgres-sbx migrate start migrations/02_rename.yaml   # expand phase only
postgres-sbx migrate complete       # or: migrate rollback
postgres-sbx migrate pull           # write the sandbox's history to migrations/
postgres-sbx migrate baseline 01_initial
postgres-sbx pgroll latest schema   # anything else, straight to pgroll
```

New migrations are numbered (`01_`, `02_`, ...) so they apply in order. This
pairs with branches: fork, migrate, inspect, and either keep the branch or go
back.

```sh
postgres-sbx checkout -b migration-test
postgres-sbx migrate up
postgres-sbx pgcli                  # look around
postgres-sbx checkout main          # nothing happened to main
```

`migrate init` is safe to repeat; `setup` runs it for you when the sandbox is
up.

## Clients

```sh
postgres-sbx psql                   # psql inside the VM, already logged in
postgres-sbx pgcli                  # pgcli on the host via uvx or pipx, URL filled in
postgres-sbx url                    # postgres://postgres:postgres@127.0.0.1:5432/postgres
postgres-sbx ssh                    # a shell in the VM
```

## Where things live

| | |
| --- | --- |
| `~/.config/postgres-sbx/state.json` | OS, version, port, credentials, branch, resources |
| `~/.config/postgres-sbx/drizzle.config.ts` | written by `studio` / `drizzle` |
| `bsdkrun ps -a`, `bsdkrun zfs ls postgres-sbx` | the VM and the volume, bsdkrun's own records |
| `/var/lib/postgresql` (Linux), `/var/db/postgres` (FreeBSD), `/var/pgsql` (NetBSD) | the branch's mountpoint in the guest |

`postgres-sbx destroy` removes all of it after confirmation (`--yes` to skip).

## Troubleshooting

- `postgres-sbx doctor` — bsdkrun, the hypervisor, Node, drizzle-kit, pgcli, pgroll.
- `postgres-sbx log -f` — the guest console; `log --boot` for bsdkrun's own boot log when a VM dies early.
- `postgres-sbx status` — whether the server accepts connections on the forwarded port.
- A VM named `postgres-sbx` that the tool did not create: `bsdkrun rm -f postgres-sbx`.

## Development

```sh
npm install
npm test            # unit tests (profile, argv)
npm run build
node bin/postgres-sbx.js --help
```

`src/Sbx/Postgres.purs` is the PostgreSQL profile: image, ports, credentials,
data directory, provisioning scripts, readiness probe, clients, drizzle
dialect, pgroll. `Sbx.App`, `Sbx.Cli`, `Sbx.Native`, `Sbx.State` and
`Sbx.Profile` are shared verbatim with mariadb-sbx and sqlite-sbx.

MIT license.

## Parallel branches

`postgres-sbx branch NAME` clones the data with ZFS copy-on-write and starts a
parallel instance. The original keeps running and remains selected. Forks
inherit the source's OS, version, database and credentials; later writes stay
inside their own dataset. You can fork a fork with `--from`.

```sh
postgres-sbx branch feature
postgres-sbx branch experiment --from feature
postgres-sbx branch staging --port 15432
postgres-sbx --branch feature url
postgres-sbx --branch feature status
postgres-sbx --branch feature stop
postgres-sbx --branch feature start
postgres-sbx checkout feature       # select its server; the others keep running
postgres-sbx checkout main
postgres-sbx branch -d experiment   # stop its instance and delete its dataset
```

The allocator skips occupied host ports and ports reserved by stopped instances.
BSD server forks also check guest listeners. `--port` selects an explicit port;
collisions fail before a new dataset is created. A stopped fork retains its
port, and a busy port on restart is reported rather than silently connecting
to another service. Put the global `--branch NAME` option **before** the command
to target an instance without changing your selection.

Linux instances are separate containers in the shared Docker VM, each mounting
only its own dataset. FreeBSD/NetBSD instances use separate PostgreSQL or MariaDB
processes inside the existing BSD VM, with separate data directories, ports,
PID files, sockets and logs. One VM owns the ZFS pool: the disk is never imported
into multiple VMs at once. Platform support is unchanged: DuckDB on BSD remains
embedded file access, and SQLite's available engines remain Linux-only.

`checkout` selects an existing parallel instance; for branches without an
instance it retains the original parent-server mount-switching behavior.
`checkout -b NAME` retains that behavior too. `branch` lists datasets and parallel
instances with their status and ports. `branch -d NAME` removes only that fork;
`destroy` removes the parent sandbox and all its parallel instances. A failed
fork startup retains its data and settings so `--branch NAME start` can retry.

Snapshots of running databases are crash-consistent. The fork performs normal
WAL/redo recovery on startup; it does not copy the source process's locks or run
a second server over the same writable directory. This provides independent
data, not a security boundary between processes sharing a BSD VM.

## CI and releases

Local test commands require Bun in addition to Node.js and the PureScript tools.

GitHub Actions runs PureScript unit tests, Bun CI checks, and live Linux
sandbox tests on Ubuntu with KVM through the custom `.fluentci/test` module.
The live suite connects with the host database driver, checks port forwarding,
ZFS branch isolation, data persistence across restarts, and cleanup. Command
output streams continuously, with a heartbeat for long operations; diagnostics
are uploaded even on failure. Live tests require KVM and are never skipped.

```sh
npm ci
npm test
npm run build:bin
npm run test:e2e                # Linux containers; installed bsdkrun >= 0.12.1 and Docker CLI
SBX_E2E_OS=freebsd npm run test:e2e
SBX_E2E_OS=netbsd npm run test:e2e
fluentci run test unit          # FluentCI 0.17.8
fluentci run --workflow test    # Ubuntu x86_64, sudo and /dev/kvm; installs bsdkrun
```

The workflows use `setup-fluentci@next` with a pinned CLI and the locked
`setup-purescript@v0.2.0` module for PureScript, Spago, Node and Bun. CI
orchestration, installation checks, release validation and cleanup live in
`src/Ci` as PureScript; Node FFI supplies process, filesystem and driver calls.

Pushing a version tag such as `v0.1.0` triggers release tests, then builds
standalone binaries for macOS ARM64, Linux x86_64 and Linux ARM64. The release
job verifies the tag against `package.json` and the embedded CLI version,
checks executable architectures, and uploads three `.tar.gz` archives and
`SHA256SUMS` to GitHub Releases. The Release workflow can also be dispatched
manually with an existing matching tag. Publishing uses the workflow's
`GITHUB_TOKEN`; no additional repository secret is required.
