#!/bin/bash
# MacDownloader installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mubaroksn/MacDownloader/main/install.sh | bash
#
# Downloads the latest release DMG with curl and copies the app into /Applications.
# Files fetched by curl carry no quarantine flag, so macOS opens the app without the
# "unidentified developer" prompt. The app itself is ad-hoc signed, not notarized.
#
# Options (environment variables):
#   MACDL_VERSION=1.4.0   install that release instead of the latest
#   MACDL_DMG=/path.dmg   install from a local DMG (no download)
#   MACDL_DEST=/dir       install somewhere other than /Applications
#   MACDL_NO_OPEN=1       don't launch the app afterwards
set -euo pipefail

REPO="mubaroksn/MacDownloader"
APP_NAME="MacDownloader.app"
DEST="${MACDL_DEST:-/Applications}"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[31mGagal:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "installer ini hanya untuk macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || die "MacDownloader butuh macOS 13 (Ventura) atau lebih baru."

TMP="$(mktemp -d)"
MNT=""
cleanup() {
  [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ -n "${MACDL_DMG:-}" ]; then
  DMG="$MACDL_DMG"
  [ -f "$DMG" ] || die "file $DMG tidak ditemukan."
  say "Memakai DMG lokal $(basename "$DMG")"
else
  # No GitHub API: unauthenticated API calls are rate-limited per IP. The
  # /releases/latest page redirects to /releases/tag/vX.Y.Z, which gives the version.
  if [ -n "${MACDL_VERSION:-}" ]; then
    version="${MACDL_VERSION#v}"
  else
    say "Mencari rilis terbaru…"
    latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
      || die "tidak bisa menghubungi GitHub."
    version="${latest##*/tag/v}"
    [ -n "$version" ] && [ "$version" != "$latest" ] || die "tidak menemukan rilis terbaru."
  fi
  url="https://github.com/$REPO/releases/download/v$version/MacDownloader-$version.dmg"
  DMG="$TMP/$(basename "$url")"
  say "Mengunduh $(basename "$url")"
  curl -fL --retry 3 --progress-bar -o "$DMG" "$url" || die "unduhan $(basename "$url") gagal."
fi

say "Membuka DMG"
MNT="$TMP/mnt"
mkdir -p "$MNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet || die "DMG tidak bisa dibuka."
[ -d "$MNT/$APP_NAME" ] || die "$APP_NAME tidak ada di dalam DMG."

if pgrep -x MacDownloader >/dev/null 2>&1; then
  say "Menutup MacDownloader yang sedang berjalan"
  osascript -e 'tell application id "com.mubaroksn.macdownloader" to quit' >/dev/null 2>&1 \
    || pkill -x MacDownloader || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MacDownloader >/dev/null 2>&1 || break; sleep 0.5; done
  pkill -x MacDownloader >/dev/null 2>&1 || true
fi

mkdir -p "$DEST"
SUDO=""
if [ ! -w "$DEST" ] || { [ -e "$DEST/$APP_NAME" ] && [ ! -w "$DEST/$APP_NAME" ]; }; then
  say "Butuh izin admin untuk menulis ke $DEST"
  SUDO="sudo"
fi

say "Memasang ke $DEST"
$SUDO rm -rf "$DEST/$APP_NAME"
$SUDO ditto "$MNT/$APP_NAME" "$DEST/$APP_NAME"
# Belt and braces: an app copied this way has no quarantine flag, but clear it anyway.
$SUDO xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

codesign --verify --deep --strict "$DEST/$APP_NAME" 2>/dev/null \
  || die "tanda tangan app tidak valid — file mungkin rusak, coba jalankan ulang."

version=$(defaults read "$DEST/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "MacDownloader $version terpasang di $DEST/$APP_NAME"

if [ -z "${MACDL_NO_OPEN:-}" ]; then
  open "$DEST/$APP_NAME"
fi
