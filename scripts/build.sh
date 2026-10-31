#!/usr/bin/env bash
# Build XSpace.app from source.
#
#   ./scripts/build.sh            -> build/XSpace.app
#   ./scripts/build.sh --install  -> also copy to ~/Applications/XSpace.app
#
# Signing:
#   - XSPACE_SIGN_IDENTITY="<name or SHA-1>" picks a specific identity.
#   - Otherwise the first valid "Apple Development" / "Developer ID Application"
#     identity in your keychain is used (stable signature: no extra prompts after rebuilds).
#   - Without any identity the app is ad-hoc signed. It still runs sandboxed, but macOS
#     may ask for confirmation after each rebuild because the signature changes.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product XSpace
BIN_DIR="$(swift build -c release --show-bin-path)"

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

codesign --force --options runtime --timestamp=none \
  --entitlements Support/XSpace.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP (signed with: $([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "identity $IDENTITY"))"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/XSpace.app"
  cp -R "$APP" "$HOME/Applications/XSpace.app"
  echo "Installed: $HOME/Applications/XSpace.app"
fi
