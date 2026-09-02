#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install_prefix=${PREFIX:-"$HOME/.local"}

cd "$project_dir"
swift build -c release --product meter
binary_dir=$(swift build -c release --show-bin-path)
install -d "$install_prefix/bin"
install -m 755 "$binary_dir/meter" "$install_prefix/bin/meter"

echo "$install_prefix/bin/meter"
