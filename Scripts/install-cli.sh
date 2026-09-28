#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_dir/Scripts/sign.sh"
install_prefix=${PREFIX:-"$HOME/.local"}

cd "$project_dir"
swift build -c release --product meter
binary_dir=$(swift build -c release --show-bin-path)
install -d "$install_prefix/bin"
install -m 755 "$binary_dir/meter" "$install_prefix/bin/meter"
# The installed CLI reads the keychain too, so it needs the same stable identity.
meter_sign "$install_prefix/bin/meter"

echo "$install_prefix/bin/meter"
