#!/usr/bin/env bash
# build-dev.sh — build the redin binary with all dev features compiled in.
#
# This is the everyday dev build. The release-stripped variant is just
# `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
# without any -define flags.
#
# Forwards "$@" so callers can append extra flags, e.g.:
#   ./build-dev.sh -define:REDIN_AGENT=true     # dev + agent channel
#   ./build-dev.sh -o:speed                     # optimized dev build
set -e

# Without the odin-http submodule the Odin compiler reports an opaque
# "Empty directory: lib:odin-http" / "Path does not exist" error.
# Surface a single clear instruction instead.
if [ ! -e lib/odin-http/client/client.odin ]; then
    echo "error: lib/odin-http is not initialized." >&2
    echo "       run: git submodule update --init --recursive" >&2
    exit 1
fi

exec odin build src/cmd/redin \
    -collection:lib=lib -collection:luajit=vendor/luajit \
    -define:REDIN_DEV=true \
    -define:REDIN_PROFILE=true \
    -define:REDIN_TRACK_MEM=true \
    -out:build/redin "$@"
