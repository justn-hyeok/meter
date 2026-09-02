#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir="$project_dir/dist"
version=$(plutil -extract CFBundleShortVersionString raw "$project_dir/Resources/Info.plist")
app_archive="$dist_dir/Meter-$version-macos-universal-unsigned.zip"
cli_archive="$dist_dir/meter-$version-macos-universal.zip"

"$project_dir/Scripts/package-app.sh"
"$project_dir/Scripts/package-cli.sh"

temporary_dir=$(mktemp -d "$dist_dir/.meter-release.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

(
    cd "$dist_dir"
    COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr Meter.app "$temporary_dir/$(basename "$app_archive")"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr meter "$temporary_dir/$(basename "$cli_archive")"
)
mv "$temporary_dir/$(basename "$app_archive")" "$app_archive"
mv "$temporary_dir/$(basename "$cli_archive")" "$cli_archive"

shasum -a 256 "$app_archive" "$cli_archive"
