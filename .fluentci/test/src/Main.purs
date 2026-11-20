module Main (all, unit, e2e) where

import Prelude
import Data.Either (either)
import Data.Maybe (Maybe, fromMaybe)
import Effect (Effect)
import Effect.Exception (throw)
import FluentCI.Plugin as P

run :: P.Pipeline -> Effect String
run plan = P.stdout plan >>= either (throw <<< P.errorMessage) pure

-- | Install bsdkrun and KVM access on Ubuntu, run unit tests, build the binary and run live Quack/ZFS tests.
-- | @param directory Project checkout directory; defaults to the current directory.
-- | @param bsdkrunVersion Official bsdkrun release to install; defaults to v0.12.0.
all :: { directory :: Maybe String, bsdkrunVersion :: Maybe String } -> Effect String
all args = run $ P.pipeline "duckdb-sbx-test"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "bash", "scripts/ci/install-bsdkrun.sh", fromMaybe "v0.12.0" args.bsdkrunVersion ]
  # P.exec [ "npm", "test" ]
  # P.exec [ "npm", "run", "build:bin" ]
  # P.exec [ "bash", "scripts/ci/e2e.sh" ]

-- | Run PureScript unit tests and mocked CLI lifecycle tests without installing a VM runtime.
-- | @param directory Project checkout directory; defaults to the current directory.
unit :: { directory :: Maybe String } -> Effect String
unit args = run $ P.pipeline "duckdb-sbx-unit"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "npm", "test" ]

-- | Run real VM, password, port, persistence and ZFS branch tests using an installed bsdkrun.
-- | @param directory Project checkout directory; defaults to the current directory.
e2e :: { directory :: Maybe String } -> Effect String
e2e args = run $ P.pipeline "duckdb-sbx-e2e"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "bash", "scripts/ci/e2e.sh" ]
