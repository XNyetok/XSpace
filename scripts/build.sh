#!/usr/bin/env bash
# Build XSpace.app from source.
#
#   ./scripts/build.sh               -> build/XSpace.app for this Mac's architecture
#   ./scripts/build.sh --universal   -> build/XSpace.app for Apple silicon and Intel
#   ./scripts/build.sh --install     -> also copy to ~/Applications/XSpace.app
#
# Environment:
#   XSPACE_SIGN_IDENTITY="<name or SHA-1>"  signing identity; "-" forces an ad-hoc signature
#   XSPACE_WARNINGS_AS_ERRORS=1             fail on compiler warnings (CI does this)
#
# Signing:
#   - Without XSPACE_SIGN_IDENTITY the first valid "Apple Development" / "Developer ID
#     Application" identity in your keychain is used (stable signature: no extra prompts
#     after rebuilds).
#   - Without any identity the app is ad-hoc signed. It still runs sandboxed, but macOS
#     may ask for confirmation after each rebuild because the signature changes.
#   - Developer ID signatures get a secure timestamp, which notarization requires.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
SWIFT_FLAGS=(-c release)
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) SWIFT_FLAGS+=(--arch arm64 --arch x86_64) ;;
    *) echo "usage: $0 [--universal] [--install]" >&2; exit 64 ;;
  esac
done
if [[ "${XSPACE_WARNINGS_AS_ERRORS:-0}" == 1 ]]; then
  SWIFT_FLAGS+=(-Xswiftc -warnings-as-errors)
fi

swift build "${SWIFT_FLAGS[@]}" --product XSpace
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

APP="build/XSpace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/XSpace" "$APP/Contents/MacOS/XSpace"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${XSPACE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"(Apple Development|Developer ID Application):/ { print $2; exit }')"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "note: no signing identity found, using ad-hoc signature"
  IDENTITY="-"
fi

TIMESTAMP="--timestamp=none"
if [[ "$IDENTITY" != "-" ]] && security find-identity -v -p codesigning 2>/dev/null \
    | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application:'; then
  TIMESTAMP="--timestamp"
fi

codesign --force --options runtime "$TIMESTAMP" \
  --entitlements Support/XSpace.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
SIGNED_WITH="$([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "identity $IDENTITY")"
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/XSpace"); signed with: $SIGNED_WITH)"

if [[ "$INSTALL" == 1 ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/XSpace.app"
  cp -R "$APP" "$HOME/Applications/XSpace.app"
  echo "Installed: $HOME/Applications/XSpace.app"
fi
