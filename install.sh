#!/bin/bash
# wwwrap installer (formerly MacDownloader).
#
#   curl -fsSL https://raw.githubusercontent.com/rakitlab/wwwrap/main/install.sh | bash
#
# Downloads the latest release DMG with curl and copies the app into /Applications.
# Files fetched by curl carry no quarantine flag, so macOS opens the app without the
# "unidentified developer" prompt. The app itself is ad-hoc signed, not notarized.
# An older MacDownloader.app is closed and moved to the Trash; its data moves over on first launch.
#
# Options (environment variables; the old MACDL_* names still work):
#   WWWRAP_VERSION=1.7.0   install that release instead of the latest
#   WWWRAP_DMG=/path.dmg   install from a local DMG (no download)
#   WWWRAP_DEST=/dir       install somewhere other than /Applications
#   WWWRAP_NO_OPEN=1       don't launch the app afterwards
#   WWWRAP_REPO=owner/name download releases from another repository
set -euo pipefail

REPO="${WWWRAP_REPO:-${MACDL_REPO:-rakitlab/wwwrap}}"
DEST="${WWWRAP_DEST:-${MACDL_DEST:-/Applications}}"
VERSION="${WWWRAP_VERSION:-${MACDL_VERSION:-}}"
LOCAL_DMG="${WWWRAP_DMG:-${MACDL_DMG:-}}"
NO_OPEN="${WWWRAP_NO_OPEN:-${MACDL_NO_OPEN:-}}"
LEGACY_APP="MacDownloader.app"
LEGACY_ID="com.mubaroksn.macdownloader"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[31mGagal:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "installer ini hanya untuk macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || die "wwwrap butuh macOS 13 (Ventura) atau lebih baru."

TMP="$(mktemp -d)"
MNT=""
cleanup() {
  [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ -n "$LOCAL_DMG" ]; then
  DMG="$LOCAL_DMG"
  [ -f "$DMG" ] || die "file $DMG tidak ditemukan."
  say "Memakai DMG lokal $(basename "$DMG")"
else
  # No GitHub API: unauthenticated API calls are rate-limited per IP. The
  # /releases/latest page redirects to /releases/tag/vX.Y.Z, which gives the version.
  if [ -n "$VERSION" ]; then
    version="${VERSION#v}"
  else
    say "Mencari rilis terbaru…"
    latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
      || die "tidak bisa menghubungi GitHub."
    version="${latest##*/tag/v}"
    [ -n "$version" ] && [ "$version" != "$latest" ] || die "tidak menemukan rilis terbaru."
  fi
  DMG="$TMP/app.dmg"
  base="https://github.com/$REPO/releases/download/v$version"
  # Releases before 1.7.0 were called MacDownloader.
  asset="wwwrap-$version.dmg"
  curl -fsIL -o /dev/null "$base/$asset" || asset="MacDownloader-$version.dmg"
  say "Mengunduh $asset"
  curl -fL --retry 3 --progress-bar -o "$DMG" "$base/$asset" || die "unduhan $asset gagal."
fi

say "Membuka DMG"
MNT="$TMP/mnt"
mkdir -p "$MNT"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MNT" -quiet || die "DMG tidak bisa dibuka."
SRC=$(find "$MNT" -maxdepth 1 -name "*.app" -print -quit)
[ -n "$SRC" ] || die "tidak ada aplikasi di dalam DMG."
APP_NAME="$(basename "$SRC")"
EXE=$(defaults read "$SRC/Contents/Info" CFBundleExecutable 2>/dev/null || echo "${APP_NAME%.app}")
BUNDLE_ID=$(defaults read "$SRC/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")

quit_app() { # $1 = bundle id, $2 = process name
  pgrep -x "$2" >/dev/null 2>&1 || return 0
  say "Menutup $2 yang sedang berjalan"
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || pkill -x "$2" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$2" >/dev/null 2>&1 || break; sleep 0.5; done
  pkill -x "$2" >/dev/null 2>&1 || true
}

quit_app "$BUNDLE_ID" "$EXE"
if [ "$APP_NAME" != "$LEGACY_APP" ]; then quit_app "$LEGACY_ID" "MacDownloader"; fi

mkdir -p "$DEST"
SUDO=""
if [ ! -w "$DEST" ] || { [ -e "$DEST/$APP_NAME" ] && [ ! -w "$DEST/$APP_NAME" ]; }; then
  say "Butuh izin admin untuk menulis ke $DEST"
  SUDO="sudo"
fi

say "Memasang ke $DEST"
$SUDO rm -rf "$DEST/$APP_NAME"
$SUDO ditto "$SRC" "$DEST/$APP_NAME"
# Belt and braces: an app copied this way has no quarantine flag, but clear it anyway.
$SUDO xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

codesign --verify --deep --strict "$DEST/$APP_NAME" 2>/dev/null \
  || die "tanda tangan app tidak valid — file mungkin rusak, coba jalankan ulang."

# The renamed app replaces MacDownloader: move the old copy to the Trash (data is migrated on launch).
if [ "$APP_NAME" != "$LEGACY_APP" ] && [ -d "$DEST/$LEGACY_APP" ]; then
  mkdir -p "$HOME/.Trash"
  $SUDO mv "$DEST/$LEGACY_APP" "$HOME/.Trash/MacDownloader $(date +%Y%m%d-%H%M%S).app" \
    && say "$LEGACY_APP lama dipindah ke Sampah"
fi

version=$(defaults read "$DEST/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "${APP_NAME%.app} $version terpasang di $DEST/$APP_NAME"
echo "INSTALLED_APP=$DEST/$APP_NAME"

if [ -z "$NO_OPEN" ]; then
  open "$DEST/$APP_NAME"
fi
