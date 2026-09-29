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
if git show-ref --verify --quiet "refs/tags/v$version"; then
    echo "error: tag v$version already exists" >&2
    exit 1
fi
remote_tag=$(git ls-remote --tags origin "refs/tags/v$version") || {
    echo "error: could not check the remote tag" >&2
    exit 1
}
[ -z "$remote_tag" ] || { echo "error: remote tag v$version already exists" >&2; exit 1; }

echo "==> $current -> $version"
if [ "$current" != "$version" ]; then
    plutil -replace CFBundleShortVersionString -string "$version" Resources/Info.plist
    plutil -replace CFBundleVersion -string "$((build + 1))" Resources/Info.plist
    /usr/bin/sed -i '' "s/static let version = \"$current\"/static let version = \"$version\"/" Sources/MeterCLI/MeterCLI.swift
fi
grep -q "static let version = \"$version\"" Sources/MeterCLI/MeterCLI.swift || {
    echo "error: CLI version does not match $version" >&2
    exit 1
}
published=$(git tag --sort=-version:refname --list 'v[0-9]*' | head -1)
if [ -n "$published" ]; then
    previous=${published#v}
    /usr/bin/sed -i '' \
        -e "s/v$previous/v$version/g" \
        -e "s/$previous-macos-universal/$version-macos-universal/g" \
        README.md README.ko.md
fi

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
default_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
[ -n "$default_branch" ] || { echo "error: no default branch" >&2; exit 1; }
git add -A
git diff --cached --check
git commit -q -m "Release Meter $version"
git push -q origin HEAD:"$default_branch"
git tag -a "v$version" -m "Meter $version"
git push -q origin "v$version"

published_notes=$(mktemp)
trap 'rm -f "$published_notes"' EXIT HUP INT TERM
cat "$notes" >"$published_notes"
printf '\n## SHA-256\n\n```text\n' >>"$published_notes"
(
    cd dist
    shasum -a 256 "Meter-$version-macos-universal-app.zip" \
        "meter-$version-macos-universal-cli.zip"
) >>"$published_notes"
printf '```\n' >>"$published_notes"
gh release create "v$version" \
    "dist/Meter-$version-macos-universal-app.zip" \
    "dist/meter-$version-macos-universal-cli.zip" \
    --title "Meter $version" --notes-file "$published_notes"

# The installed CLI is part of the release too: the app went to 0.4.14 while the `meter`
# on PATH sat at 0.3.0, and nothing noticed.
echo "==> local CLI"
"$project_dir/Scripts/install-cli.sh" >/dev/null
"${PREFIX:-$HOME/.local}/bin/meter" --version
