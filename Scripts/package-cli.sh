#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_dir/Scripts/sign.sh"
. "$project_dir/Scripts/build-slice.sh"
dist_dir="$project_dir/dist"
cli_path="$dist_dir/meter"

cd "$project_dir"
arm_build_dir=$(meter_build_slice meter arm64 .build/package-arm64)
intel_build_dir=$(meter_build_slice meter x86_64 .build/package-x86_64)

mkdir -p "$dist_dir"
temporary_dir=$(mktemp -d "$dist_dir/.meter-cli-package.XXXXXX")
temporary_cli="$temporary_dir/meter"
backup_cli="$dist_dir/.meter.previous.$$"
trap 'rm -rf "$temporary_dir" "$backup_cli"' EXIT HUP INT TERM

lipo -create "$arm_build_dir/meter" "$intel_build_dir/meter" -output "$temporary_cli"
chmod 755 "$temporary_cli"
meter_sign "$temporary_cli"

if [ -e "$cli_path" ]; then
    mv "$cli_path" "$backup_cli"
fi
mv "$temporary_cli" "$cli_path"
rm -rf "$backup_cli"

echo "$cli_path"
