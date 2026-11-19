#!/bin/bash
# Cuts a release: tags the current main with the next version and pushes both.
# The version and notes come from scripts/next-release.py (Conventional Commits);
# the notes become the tag message, and the tag starts the GitHub release build.
#
#   ./scripts/release.sh [--yes] [remote]   # remote defaults to origin
set -euo pipefail
cd "$(dirname "$0")/.."

YES=false
[ "${1:-}" = "--yes" ] && { YES=true; shift; }
REMOTE="${1:-origin}"

[ "$(git branch --show-current)" = main ] || { echo "Release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first" >&2; exit 1; }
git fetch --quiet --tags "$REMOTE" main
BEHIND="$(git rev-list --count "HEAD..$REMOTE/main")"
[ "$BEHIND" = 0 ] || { echo "main is $BEHIND commits behind $REMOTE; pull first" >&2; exit 1; }

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
VERSION="$(python3 scripts/next-release.py "$NOTES")"
[ -n "$VERSION" ] || { echo "Nothing new since the last release"; exit 0; }

echo "Imla $VERSION"
echo
cat "$NOTES"
echo
if ! $YES; then
    read -r -p "Tag v$VERSION and push to $REMOTE? [y/N] " answer
    [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Cancelled"; exit 1; }
fi

# Verbatim, so the notes' "## " headings aren't stripped as comments.
git tag --annotate --cleanup=verbatim --file "$NOTES" "v$VERSION"
git push "$REMOTE" main "v$VERSION"
echo "Pushed v$VERSION. GitHub builds the release when the tag reaches it."
