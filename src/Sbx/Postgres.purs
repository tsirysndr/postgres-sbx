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
  , defaultTag: "17"
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
  , "pkg info -e postgresql17-server >/dev/null 2>&1 || env ASSUME_ALWAYS_YES=yes pkg install -y postgresql17-server"
  , "sysrc postgresql_enable=YES >/dev/null"
  , "chown postgres:postgres /var/db/postgres"
  , "data=/var/db/postgres/data17"
  , "if [ ! -f \"$data/PG_VERSION\" ]; then"
  , "  service postgresql initdb >/dev/null"
  , "  echo \"listen_addresses = '*'\" >> \"$data/postgresql.conf\""
  , "  printf 'host all all 0.0.0.0/0 scram-sha-256\\nhost all all ::/0 scram-sha-256\\n' >> \"$data/pg_hba.conf\""
  , "fi"
  , "service postgresql status >/dev/null 2>&1 || service postgresql start >/dev/null"
  , sql
  , "su -m postgres -c 'psql -q -v ON_ERROR_STOP=1 -f /tmp/sbx.sql'"
  ]

netbsd :: String
netbsd = String.joinWith "\n"
  [ "set -e"
  , "export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH"
  , "pkg_info -qe postgresql17-server || pkgin -y install postgresql17-server"
  , "cp -f /usr/pkg/share/examples/rc.d/pgsql /etc/rc.d/pgsql"
  , "grep -q '^pgsql=YES' /etc/rc.conf || echo 'pgsql=YES' >> /etc/rc.conf"
  , "chown pgsql:pgsql /var/pgsql"
  , "data=/var/pgsql/data"
  , "if [ ! -f \"$data/PG_VERSION\" ]; then"
  , "  /etc/rc.d/pgsql initdb >/dev/null"
  , "  echo \"listen_addresses = '*'\" >> \"$data/postgresql.conf\""
  , "  printf 'host all all 0.0.0.0/0 scram-sha-256\\nhost all all ::/0 scram-sha-256\\n' >> \"$data/pg_hba.conf\""
  , "fi"
  , "/etc/rc.d/pgsql status >/dev/null 2>&1 || /etc/rc.d/pgsql start >/dev/null"
  , sql
  , "su -m pgsql -c 'psql -q -v ON_ERROR_STOP=1 -f /tmp/sbx.sql'"
  ]
