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
# Piping straight into tail threw away the exit status, so a failing suite still released.
test_log=$(mktemp)
if ! swift test >"$test_log" 2>&1; then
    tail -40 "$test_log" >&2
    rm -f "$test_log"
    echo "error: tests failed" >&2
    exit 1
fi
tail -1 "$test_log"
rm -f "$test_log"

echo "==> artifacts"
package_log=$(mktemp)
if ! "$project_dir/Scripts/package-release.sh" >"$package_log" 2>&1; then
    tail -40 "$package_log" >&2
    rm -f "$package_log"
    echo "error: packaging failed" >&2
    exit 1
fi
tail -2 "$package_log"
rm -f "$package_log"

echo "==> publish"
# Everything goes in. The list of folders here once left out Tests/, so from 0.4.3 on the
# suite that passed above was never the one committed, and v0.4.16's did not even compile.
git add -A
git commit -q -m "Release Meter $version" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag -a "v$version" -m "Meter $version"
git push -q origin HEAD
git push -q origin "v$version"
gh release create "v$version" \
    "dist/Meter-$version-macos-universal-app.zip" \
    "dist/meter-$version-macos-universal-cli.zip" \
    --title "Meter $version" --notes-file "$notes"

# The installed CLI is part of the release too: the app went to 0.4.14 while the `meter`
# on PATH sat at 0.3.0, and nothing noticed.
echo "==> local CLI"
"$project_dir/Scripts/install-cli.sh" >/dev/null
"${PREFIX:-$HOME/.local}/bin/meter" --version

