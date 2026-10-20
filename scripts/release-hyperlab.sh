#!/usr/bin/env bash
# Build the hyperlab fork's macOS universal binary and publish it as a GitHub
# release on hyperlab-sh/editxr. Same build as scripts/release.sh, but ad-hoc
# signed and not notarised (no Developer ID): fine for curl downloads, which
# carry no quarantine flag.
#
# Usage:  scripts/release-hyperlab.sh vX.Y.Z-hyperlab.N
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release-hyperlab.sh vX.Y.Z-hyperlab.N}"
REPO="hyperlab-sh/editxr"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SWIFT="$DEVELOPER_DIR/usr/bin/swift"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree is dirty; commit first" >&2
  exit 1
fi

echo "==> Building universal release ($VERSION)"
"$SWIFT" build -c release --scratch-path .build-arm64
"$SWIFT" build -c release --scratch-path .build-x86 \
  -Xswiftc -target -Xswiftc x86_64-apple-macosx12.0 \
  -Xcc -target -Xcc x86_64-apple-macosx12.0 \
  -Xlinker -arch -Xlinker x86_64
BIN=".build-universal/editxr"
mkdir -p .build-universal
lipo -create .build-arm64/release/editxr .build-x86/release/editxr -output "$BIN"
lipo -info "$BIN"
codesign --force --sign - "$BIN"

OUT="editxr-$VERSION-macos-universal"
rm -rf dist && mkdir -p dist/stage
cp "$BIN" dist/stage/editxr
( cd dist/stage && zip -q "../$OUT.zip" editxr )
( cd dist && shasum -a 256 "$OUT.zip" > "$OUT.zip.sha256" )

echo "==> Tagging and publishing $VERSION to $REPO"
git tag -a "$VERSION" -m "editxr $VERSION"
git push origin HEAD "$VERSION"
gh release create "$VERSION" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "editxr $VERSION" \
  --notes "hyperlab fork of pixdeo/editxr: adds --mirror=<path> (buffer follows to a file; SIGUSR1 saves) and inline image/Mermaid rendering via the Kitty graphics protocol. macOS universal, ad-hoc signed." \
  "dist/$OUT.zip" "dist/$OUT.zip.sha256"
echo "==> Done: https://github.com/$REPO/releases/tag/$VERSION"
