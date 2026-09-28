#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir="$project_dir/dist"
version=$(plutil -extract CFBundleShortVersionString raw "$project_dir/Resources/Info.plist")
# The suffixes are not decoration. macOS filesystems are case-insensitive by default, so
# "Meter-<v>-macos-universal.zip" and "meter-<v>-macos-universal.zip" are one file, and the
# CLI archive silently overwrote the app's.
app_archive="$dist_dir/Meter-$version-macos-universal-app.zip"
cli_archive="$dist_dir/meter-$version-macos-universal-cli.zip"

if [ "$(basename "$app_archive" | tr 'A-Z' 'a-z')" = "$(basename "$cli_archive" | tr 'A-Z' 'a-z')" ]; then
    echo "error: archive names collide on a case-insensitive filesystem" >&2
    exit 1
fi

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

# Each archive must contain what its name claims; the collision above produced an app
# archive holding the CLI binary and nothing complained.
unzip -l "$app_archive" | grep -q "Meter.app/Contents/MacOS/MeterApp" || {
    echo "error: $app_archive does not contain the app bundle" >&2
    exit 1
}
unzip -l "$cli_archive" | grep -qE " meter$" || {
    echo "error: $cli_archive does not contain the CLI binary" >&2
    exit 1
}

shasum -a 256 "$app_archive" "$cli_archive"
