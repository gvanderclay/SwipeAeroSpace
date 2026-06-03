#!/usr/bin/env bash
#
# dev-install.sh — build the current checkout, replace the installed app, and
# relaunch it. For local gesture testing of dev branches (e.g. feat/gesture-accuracy).
#
# Usage:  ./dev-install.sh            # build (Debug), install to /Applications, launch
#         ./dev-install.sh --no-build # skip xcodebuild, install the last-built product
#
set -euo pipefail

PROJECT="SwipeAeroSpace.xcodeproj"
SCHEME="SwipeAeroSpace"
CONFIG="Debug"
APP_NAME="SwipeAeroSpace.app"
INSTALL_DIR="/Applications"
DO_BUILD=1

for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")"

echo "==> Quitting any running ${SCHEME} instances..."
# Graceful quit first (lets the app tear down its event tap + socket), then force.
osascript -e "tell application \"${SCHEME}\" to quit" >/dev/null 2>&1 || true
sleep 1
if pgrep -x "${SCHEME}" >/dev/null 2>&1; then
    echo "    still running, sending SIGTERM..."
    pkill -x "${SCHEME}" || true
    sleep 1
fi
pkill -9 -x "${SCHEME}" >/dev/null 2>&1 || true

if [[ "${DO_BUILD}" -eq 1 ]]; then
    echo "==> Building ${SCHEME} (${CONFIG})..."
    xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration "${CONFIG}" \
        build CODE_SIGNING_ALLOWED=NO | tail -3
fi

echo "==> Locating built product..."
BUILD_DIR="$(xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration "${CONFIG}" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR =/{print $2; exit}')"
BUILT_APP="${BUILD_DIR}/${APP_NAME}"

if [[ ! -d "${BUILT_APP}" ]]; then
    echo "ERROR: built app not found at ${BUILT_APP}" >&2
    echo "       (run without --no-build to compile it first)" >&2
    exit 1
fi

echo "==> Installing to ${INSTALL_DIR}/${APP_NAME}..."
rm -rf "${INSTALL_DIR:?}/${APP_NAME}"
cp -R "${BUILT_APP}" "${INSTALL_DIR}/"

# Re-sign with a STABLE development identity so the Accessibility grant survives
# rebuilds. Ad-hoc signatures change every build, which invalidates the TCC grant
# and makes CGEvent.tapCreate return nil ("couldn't create event tap" → no swipes).
# Override by exporting SIGN_IDENTITY=... before running.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development/{print $2; exit}')}"
if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "==> Re-signing with: ${SIGN_IDENTITY}"
    codesign --force --deep --sign "${SIGN_IDENTITY}" \
        "${INSTALL_DIR}/${APP_NAME}" >/dev/null 2>&1 \
        && echo "    signed OK" \
        || echo "    WARNING: re-sign failed; app stays ad-hoc (grant won't persist)"
else
    echo "==> No Apple Development identity found; leaving ad-hoc signature."
    echo "    (Accessibility grant will NOT persist across rebuilds.)"
fi

echo "==> Launching..."
open "${INSTALL_DIR}/${APP_NAME}"

cat <<EOF

Done. Now (test build):
  • Branch: $(git branch --show-current 2>/dev/null || echo '?')
  • Make sure AeroSpace is running.
  • This is a fresh binary, so macOS may re-prompt for Accessibility permission.
    Grant it in System Settings > Privacy & Security > Accessibility
    (remove/re-add the SwipeAeroSpace entry if gestures don't work).
EOF
