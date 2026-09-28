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

for product in meter MeterApp; do
    binary="$project_dir/.build/debug/$product"
    if [ -f "$binary" ]; then
        meter_sign "$binary"
    fi
done
