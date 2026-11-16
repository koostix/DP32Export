#!/bin/sh
# Builds the app and the CLI, ad-hoc signs the local copy, and opens it.
# Apple Silicon will not run an unsigned binary; an ad-hoc signature is enough locally.
set -eu
cd "$(dirname "$0")/.."
sh scripts/package.sh "$@"
open "build/DP32 Export.app"
