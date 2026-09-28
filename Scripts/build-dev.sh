#!/bin/sh
# Builds the debug products and signs them with a stable identity.
#
# `swift build` leaves binaries ad-hoc signed, so each rebuild is a new identity to the
# keychain and every run re-asks for permission. Signing after the build keeps the
# "Always Allow" grant, which matters because Meter reads credentials other apps own.
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_dir/Scripts/sign.sh"

cd "$project_dir"
swift build "$@"

# Ask the toolchain where the products landed rather than assuming .build/debug: the
# passthrough above accepts flags such as -c release, and a hardcoded path would either
# sign a stale binary or silently sign nothing while reporting success.
binary_dir=$(swift build "$@" --show-bin-path)

for product in meter MeterApp; do
    binary="$binary_dir/$product"
    if [ ! -f "$binary" ]; then
        echo "error: $product not found in $binary_dir" >&2
        exit 1
    fi
    meter_sign "$binary"
done
