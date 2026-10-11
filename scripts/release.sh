#!/usr/bin/env bash
# Compila Screenshooter (Release, universal arm64 + x86_64), lo empaqueta en un .dmg
# con su checksum SHA-256 y, con --publish, crea la GitHub Release con `gh`.
# Uso: scripts/release.sh [--publish] [--prerelease]    (RELEASE_TAG=vX.Y.Z[-sufijo] opcional)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { echo "Uso: $0 [--publish] [--prerelease]" >&2; exit 1; }

PUBLISH=0
PRERELEASE=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --prerelease) PRERELEASE=1 ;;
    *) usage ;;
  esac
done

cd "$ROOT"
PLIST="$ROOT/Screenshooter/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
TAG="${RELEASE_TAG:-v$VERSION}"
if [ "$TAG" != "v$VERSION" ] && [[ "$TAG" != "v$VERSION-"* ]]; then
  echo "Error: RELEASE_TAG='$TAG' no coincide con la versión del Info.plist (esperado v$VERSION o v$VERSION-sufijo)." >&2
  exit 1
fi

BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
DMG="$BUILD/Screenshooter-$VERSION.dmg"
SHA="$DMG.sha256"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/screenshooter-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Versión $VERSION (tag $TAG)"
echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild Release (universal)"
xcodebuild -project Screenshooter.xcodeproj -scheme Screenshooter -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

APP="$DERIVED/Build/Products/Release/Screenshooter.app"
[ -d "$APP" ] || { echo "Error: no se encontró $APP" >&2; exit 1; }

echo "==> codesign --verify"
codesign --verify --deep --strict --verbose=2 "$APP"

EXEC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")"
ARCHS_FOUND="$(lipo -archs "$EXEC")"
echo "==> Arquitecturas: $ARCHS_FOUND"
for a in arm64 x86_64; do
  case " $ARCHS_FOUND " in
    *" $a "*) ;;
    *) echo "Error: el binario no contiene $a." >&2; exit 1 ;;
  esac
done

echo "==> Creando DMG"
ditto "$APP" "$STAGE/Screenshooter.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG" "$SHA"
hdiutil create -volname "Screenshooter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

(cd "$BUILD" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$SHA")")
echo "==> $DMG"
cat "$SHA"

if [ "$PUBLISH" -eq 1 ]; then
  echo "==> Publicando release $TAG"
  EXTRA=()
  [ "$PRERELEASE" -eq 1 ] && EXTRA+=(--prerelease)
  gh release create "$TAG" "$DMG" "$SHA" --title "Screenshooter $VERSION" --generate-notes ${EXTRA[@]+"${EXTRA[@]}"}
fi
