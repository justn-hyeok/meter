#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_dir/Scripts/sign.sh"
. "$project_dir/Scripts/build-slice.sh"
dist_dir="$project_dir/dist"
app_dir="$project_dir/dist/Meter.app"

cd "$project_dir"
arm_build_dir=$(meter_build_slice MeterApp arm64 .build/package-arm64)
intel_build_dir=$(meter_build_slice MeterApp x86_64 .build/package-x86_64)

mkdir -p "$dist_dir"
temporary_dir=$(mktemp -d "$dist_dir/.meter-package.XXXXXX")
temporary_app="$temporary_dir/Meter.app"
contents_dir="$temporary_app/Contents"
backup_app="$dist_dir/.Meter.app.previous.$$"
trap 'rm -rf "$temporary_dir" "$backup_app"' EXIT HUP INT TERM

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
lipo -create "$arm_build_dir/MeterApp" "$intel_build_dir/MeterApp" -output "$contents_dir/MacOS/MeterApp"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"

chmod 755 "$contents_dir/MacOS/MeterApp"
plutil -lint "$contents_dir/Info.plist"
meter_sign "$temporary_app"

if [ -e "$app_dir" ]; then
    mv "$app_dir" "$backup_app"
fi
mv "$temporary_app" "$app_dir"
rm -rf "$backup_app"

echo "$app_dir"
