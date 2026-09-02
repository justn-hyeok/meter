#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
arm_build_dir="$project_dir/.build/package-arm64/arm64-apple-macosx/release"
intel_build_dir="$project_dir/.build/package-x86_64/x86_64-apple-macosx/release"
dist_dir="$project_dir/dist"
app_dir="$project_dir/dist/Meter.app"

cd "$project_dir"
swift build -c release --product MeterApp --arch arm64 --scratch-path .build/package-arm64
swift build -c release --product MeterApp --arch x86_64 --scratch-path .build/package-x86_64

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
codesign --force --sign - "$temporary_app"
codesign --verify --strict --verbose=2 "$temporary_app"

if [ -e "$app_dir" ]; then
    mv "$app_dir" "$backup_app"
fi
mv "$temporary_app" "$app_dir"
rm -rf "$backup_app"

echo "$app_dir"
