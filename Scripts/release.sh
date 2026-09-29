#!/bin/sh
# Cuts a release: bumps the version everywhere, builds and verifies the artifacts, then
# tags and publishes. Written because the same ten steps by hand is where the 0.4.0
# archive ended up holding the wrong binary.
#
#   Scripts/release.sh 0.4.3 dist/release-notes-v0.4.3.md
set -eu

version=$1
notes=$2

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

[ -f "$notes" ] || { echo "error: notes file $notes not found" >&2; exit 1; }

current=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
build=$(plutil -extract CFBundleVersion raw Resources/Info.plist)
[ "$current" != "$version" ] || { echo "error: already at $version" >&2; exit 1; }

echo "==> $current -> $version"
plutil -replace CFBundleShortVersionString -string "$version" Resources/Info.plist
plutil -replace CFBundleVersion -string "$((build + 1))" Resources/Info.plist
/usr/bin/sed -i '' "s/static let version = \"$current\"/static let version = \"$version\"/" Sources/MeterCLI/MeterCLI.swift
/usr/bin/sed -i '' "s/$current/$version/g" README.md README.ko.md

echo "==> tests"
swift test 2>&1 | tail -1

echo "==> artifacts"
"$project_dir/Scripts/package-release.sh" | tail -2

echo "==> publish"
git add -A Sources Resources README.md README.ko.md Scripts
git commit -q -m "Release Meter $version" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag -a "v$version" -m "Meter $version"
git push -q origin HEAD
git push -q origin "v$version"
gh release create "v$version" \
    "dist/Meter-$version-macos-universal-app.zip" \
    "dist/meter-$version-macos-universal-cli.zip" \
    --title "Meter $version" --notes-file "$notes"
