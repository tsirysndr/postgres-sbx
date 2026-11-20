module Test.Main where

import Prelude
import Bsdkrun.Options as Options
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Sbx.Postgres (profile)
import Sbx.Engine (runtimeVersionAllowed)
import Sbx.Profile (Os(..))

main :: Effect Unit
main = do
  unless (runtimeVersionAllowed "bsdkrun 0.12.1" && not (runtimeVersionAllowed "bsdkrun 0.12.0")) $ throw "image-store runtime requirement"
  let c = profile.defaults
  unless (profile.url "18" c 5432 == "postgres://postgres:postgres@127.0.0.1:5432/postgres") $ throw "url"
  unless (profile.image "18" == "postgres:18" && profile.image "ghcr.io/x/pg:1" == "ghcr.io/x/pg:1") $ throw "image"
  unless (profile.dataDir Linux == "/var/lib/postgresql") $ throw "data dir"
  let args = Options.buildCreateArgs (Options.linux (profile.image "18") # Options.withZfs [ "postgres-sbx@main:/var/lib/postgresql" ])
  unless (args == [ "linux", "postgres:18", "-d", "--zfs", "postgres-sbx@main:/var/lib/postgresql" ]) $ throw "zfs args"
  log "postgres-sbx tests passed"
