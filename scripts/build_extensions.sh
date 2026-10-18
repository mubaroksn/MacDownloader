#!/usr/bin/env bash
# Packages the browser extension for every browser from the single ChromeExtension/ source.
#
#   dist/MacDownloader-ChromeExtension-<v>.zip   Chrome, Edge, Brave, Arc, Dia, Opera, Vivaldi
#   dist/MacDownloader-Firefox-<v>.zip           Firefox (unsigned; CI signs it into an .xpi
#                                                when AMO_JWT_ISSUER / AMO_JWT_SECRET are set)
#
# Firefox differences live only in the manifest: an event-page background instead of a
# service worker, plus the add-on id and data-collection declaration AMO requires.
set -euo pipefail

VERSION="${VERSION:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/dist}"
mkdir -p "$OUT"

# Browser extension versions must be 1-4 dot-separated integers.
EXT_VERSION="$(printf '%s' "$VERSION" | sed -E 's/[^0-9.].*$//')"
[[ -n "$EXT_VERSION" ]] || EXT_VERSION="1.0.0"

stage() { # $1 = folder name, $2 = browser (chrome|firefox)
  local dir="$OUT/ext/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$ROOT/ChromeExtension/." "$dir/"
  python3 - "$dir/manifest.json" "$EXT_VERSION" "$2" <<'PY'
import json, sys
path, version, browser = sys.argv[1:]
m = json.load(open(path))
m["version"] = version
if browser == "firefox":
    # Event page instead of a service worker; it can't importScripts, so list the helpers.
    m["background"] = {"scripts": ["strings.js", "i18n.js", "background.js"]}
    m["browser_specific_settings"] = {
        "gecko": {
            "id": "macdownloader@mubaroksn.github.io",
            "strict_min_version": "140.0",
            "data_collection_permissions": {"required": ["none"]},
        },
        "gecko_android": {"strict_min_version": "142.0"},
    }
json.dump(m, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY
  echo "$dir"
}

CHROME_DIR="$(stage ChromeExtension chrome)"
FIREFOX_DIR="$(stage FirefoxExtension firefox)"

rm -f "$OUT/MacDownloader-ChromeExtension-$VERSION.zip" "$OUT/MacDownloader-Firefox-$VERSION.zip"
(cd "$OUT/ext" && zip -qr "$OUT/MacDownloader-ChromeExtension-$VERSION.zip" ChromeExtension)
# Firefox wants manifest.json at the archive root.
(cd "$FIREFOX_DIR" && zip -qr "$OUT/MacDownloader-Firefox-$VERSION.zip" .)

echo "Extensions:"
ls -lh "$OUT"/MacDownloader-*Extension*-"$VERSION".zip "$OUT"/MacDownloader-Firefox-"$VERSION".zip
