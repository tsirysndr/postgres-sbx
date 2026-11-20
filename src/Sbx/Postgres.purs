module Sbx.Postgres (profile) where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object
import Sbx.Profile (ClientCmd(..), FancyCmd(..), Os(..), Profile, shellQuote, withBsdPath)

profile :: Profile
profile =
  { tool: "postgres-sbx"
  , product: "PostgreSQL"
  , guestPort: 5432
  , defaultTag: "18"
  , image: \tag -> if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag else "postgres:" <> tag
  , hasCredentials: true
  , defaults: { user: "postgres", password: "postgres", db: "postgres" }
  , dataDir: case _ of
      -- PGDATA sits under it on every image generation (`data` before 18,
      -- `18/docker` from 18 on), which is also the path the image documents
      -- for a volume.
      Linux -> "/var/lib/postgresql"
      FreeBSD -> "/var/db/postgres"
      NetBSD -> "/var/pgsql"
  , rootfsVolume: false
  , tools: Nothing
  -- The pkg/pkgsrc server packages (llvm for JIT among them) need about
  -- 2 GiB beyond the base image's root disk.
  , rootDisk: case _ of
      Linux -> Nothing
      _ -> Just "10G"
  , env: \c -> Object.fromFoldable
      [ "POSTGRES_USER" /\ c.user
      , "POSTGRES_PASSWORD" /\ c.password
      , "POSTGRES_DB" /\ c.db
      ]
  , command: Nothing
  , provision: case _ of
      Linux -> Nothing
      FreeBSD -> Just freebsd
      NetBSD -> Just netbsd
  , ready: \_ c -> withBsdPath ("pg_isready -q -h 127.0.0.1 -U " <> shellQuote c.user)
  , client: Guest \_ c -> withBsdPath ("PGPASSWORD=" <> shellQuote c.password <> " psql -h 127.0.0.1 -U " <> shellQuote c.user <> " -d " <> shellQuote c.db)
  , clientName: "psql"
  , fancy: { name: "pgcli", cmd: HostTool \c port -> [ "pgcli", url c port ] }
  , url
  , studioSupported: const true
  , dialect: "postgresql"
  , driver: "pg"
  , migrations: Just
      { name: "pgroll"
      , brew: "xataio/pgroll/pgroll"
      , repo: "xataio/pgroll"
      , asset: \h -> "pgroll." <> h.os <> "." <> h.arch
      , urlFlag: "--postgres-url"
      , envVar: "PGROLL_PG_URL"
      -- the image has no TLS; pgx would otherwise try it first
      , url: \c port -> url c port <> "?sslmode=disable"
      , dir: "migrations"
      }
  }

url :: { user :: String, password :: String, db :: String } -> Int -> String
url c port = "postgres://" <> c.user <> ":" <> c.password <> "@127.0.0.1:" <> show port <> "/" <> c.db

-- Both scripts are idempotent: they install the server once, initialise the
-- cluster once per data branch, and otherwise just make sure it is running
-- and that the requested role and database exist.
-- SQL applied as the superuser; `\gexec` runs the generated CREATE DATABASE.
sql :: String
sql = String.joinWith "\n"
  [ "cat > /tmp/sbx.sql <<'SQL'"
  , "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${SBX_USER}') THEN CREATE ROLE \"${SBX_USER}\" LOGIN SUPERUSER; END IF; END $$;"
  , "ALTER ROLE \"${SBX_USER}\" WITH PASSWORD '${SBX_PASSWORD}';"
  , "SELECT 'CREATE DATABASE \"${SBX_DB}\" OWNER \"${SBX_USER}\"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${SBX_DB}')\\gexec"
  , "SQL"
  , "sed -i.bak -e \"s/\\${SBX_USER}/$SBX_USER/g\" -e \"s/\\${SBX_PASSWORD}/$SBX_PASSWORD/g\" -e \"s/\\${SBX_DB}/$SBX_DB/g\" /tmp/sbx.sql"
  ]

freebsd :: String
freebsd = String.joinWith "\n"
  [ "set -e"
  , "export PATH=/usr/local/bin:/usr/local/sbin:$PATH"
  , "pkg info -e postgresql18-server >/dev/null 2>&1 || env ASSUME_ALWAYS_YES=yes pkg install -y postgresql18-server"
  , "pkg clean -ay >/dev/null 2>&1 || true"
  -- Not enabled at boot: rc would start it before bsdkrun mounts the ZFS
  -- branch, on the bare mountpoint. Provisioning starts it after the mount.
  , "sysrc -x postgresql_enable >/dev/null 2>&1 || true"
  , "chown postgres:postgres /var/db/postgres"
  , "data=/var/db/postgres/data18"
  , "if [ ! -f \"$data/PG_VERSION\" ]; then"
  , "  service postgresql initdb >/dev/null"
  , "  echo \"listen_addresses = '*'\" >> \"$data/postgresql.conf\""
  , "  printf 'host all all 0.0.0.0/0 scram-sha-256\\nhost all all ::/0 scram-sha-256\\n' >> \"$data/pg_hba.conf\""
  , "fi"
  , "service postgresql onestatus >/dev/null 2>&1 || service postgresql onestart >/dev/null"
  , sql
  , "su -m postgres -c 'psql -q -v ON_ERROR_STOP=1 -d postgres -f /tmp/sbx.sql'"
  ]

netbsd :: String
netbsd = String.joinWith "\n"
  [ "set -e"
  , "export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH"
  -- A fresh guest has pkg_add but no pkgin, and no PKG_PATH: point pkg_add
  -- at the pkgsrc CDN for this release (a -current guest uses its <major>.0
  -- packages, with a harmless platform warning) and install pkgin with it.
  , "A=$(uname -p); [ \"$A\" = x86_64 ] && A=amd64"
  , "export PKG_PATH=\"https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/$A/$(uname -r | cut -d. -f1).0/All/\""
  , "command -v pkgin >/dev/null 2>&1 || pkg_add pkgin"
  , "pkg_info -qe postgresql18-server || pkgin -y install postgresql18-server"
  , "pkgin clean >/dev/null 2>&1 || true"
  , "cp -f /usr/pkg/share/examples/rc.d/pgsql /etc/rc.d/pgsql"
  -- Not enabled at boot: rc would start it before bsdkrun mounts the ZFS
  -- branch and initdb on the bare mountpoint. Provisioning starts it after
  -- the mount.
  , "{ grep -v '^pgsql=YES' /etc/rc.conf || true; } > /etc/rc.conf.new && mv /etc/rc.conf.new /etc/rc.conf"
  -- pkgsrc's rc script keeps the cluster under pgsql_home (/usr/pkg/pgsql by
  -- default): point it at the ZFS branch.
  , "grep -q '^pgsql_home=' /etc/rc.conf || echo 'pgsql_home=/var/pgsql' >> /etc/rc.conf"
  -- NetBSD ships 10 semaphore sets / 60 semaphores; PostgreSQL needs more
  -- than that for its default max_connections.
  , "sysctl -w kern.ipc.semmni=256 kern.ipc.semmns=4096 >/dev/null"
  , "grep -q '^kern.ipc.semmni' /etc/sysctl.conf || printf 'kern.ipc.semmni=256\\nkern.ipc.semmns=4096\\n' >> /etc/sysctl.conf"
  , "chown pgsql:pgsql /var/pgsql"
  , "data=/var/pgsql/data"
  , "if [ ! -f \"$data/PG_VERSION\" ]; then"
  , "  /etc/rc.d/pgsql oneinitdb >/dev/null"
  , "  echo \"listen_addresses = '*'\" >> \"$data/postgresql.conf\""
  , "  printf 'host all all 0.0.0.0/0 scram-sha-256\\nhost all all ::/0 scram-sha-256\\n' >> \"$data/pg_hba.conf\""
  , "fi"
  , "/etc/rc.d/pgsql onestatus >/dev/null 2>&1 || /etc/rc.d/pgsql onestart >/dev/null"
  , sql
  , "su -m pgsql -c 'psql -q -v ON_ERROR_STOP=1 -d postgres -f /tmp/sbx.sql'"
  ]
