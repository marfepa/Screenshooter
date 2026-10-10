#!/usr/bin/env bash
# Regenera AppIcon.appiconset (10 PNG) y AppIcon.icns desde design/icon/*.svg.
# Las fuentes van a sangre; aquí se aplica la máscara squircle macOS (824x824, rx 185, offset 100).
# Tamaños <= 64 px usan icon-small.svg; el resto icon-1024.svg.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RSVG=/opt/homebrew/bin/rsvg-convert
[ -x "$RSVG" ] || RSVG="$(command -v rsvg-convert)"
SET="$ROOT/Screenshooter/Resources/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CLIP='<clipPath id="squircle"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath><g clip-path="url(#squircle)">'
for n in icon-1024 icon-small; do
  # Envuelve <g id="art"> con el clipPath para obtener la variante enmascarada.
  sed -e "s|<g id=\"art\">|$CLIP<g id=\"art\">|" -e 's|^  </g>$|  </g></g>|' \
    "$ROOT/design/icon/$n.svg" > "$WORK/$n-masked.svg"
done

render() { # nombre px
  local src=icon-1024; [ "$2" -le 64 ] && src=icon-small
  "$RSVG" -w "$2" -h "$2" "$WORK/$src-masked.svg" -o "$SET/$1"
}
render icon_16x16.png 16;       render icon_16x16@2x.png 32
render icon_32x32.png 32;       render icon_32x32@2x.png 64
render icon_128x128.png 128;    render icon_128x128@2x.png 256
render icon_256x256.png 256;    render icon_256x256@2x.png 512
render icon_512x512.png 512;    render icon_512x512@2x.png 1024

ICONSET="$WORK/AppIcon.iconset"; mkdir "$ICONSET"
cp "$SET"/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$ROOT/Screenshooter/Resources/AppIcon.icns"
echo "OK: 10 PNG + AppIcon.icns"
