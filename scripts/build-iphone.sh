#!/bin/zsh
# Builds the iPhone app (with its Live Activity and screen-sharing extensions) and installs it.
#   BLUEY_TEAM=<team id> BLUEY_BUNDLE_PREFIX=<your.prefix> BLUEY_DEVICE=<udid> ./scripts/build-iphone.sh
# The bundle IDs become <prefix>.phone, <prefix>.phone.widgets, <prefix>.phone.broadcast, app group group.<prefix>.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BLUEY_TEAM:?Set BLUEY_TEAM to your Apple developer team id}"
: "${BLUEY_BUNDLE_PREFIX:?Set BLUEY_BUNDLE_PREFIX, e.g. com.example.bluey}"
: "${BLUEY_DEVICE:?Set BLUEY_DEVICE to the iPhone UDID (xcrun devicectl list devices)}"
xcodegen generate >/dev/null
xcodebuild -project GooglyEyes.xcodeproj -scheme GooglyEyes -configuration Debug \
  -destination "id=$BLUEY_DEVICE" -derivedDataPath /tmp/BlueyDeviceDerived -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$BLUEY_TEAM" BLUEY_BUNDLE_PREFIX="$BLUEY_BUNDLE_PREFIX" build | grep -E "error:|BUILD" || true
APP=/tmp/BlueyDeviceDerived/Build/Products/Debug-iphoneos/Bluey.app
for i in 1 2 3 4 5; do
  if timeout 120 xcrun devicectl device install app --device "$BLUEY_DEVICE" "$APP" 2>&1 | grep -q "App installed"; then
    echo "Installed"; break
  fi
  echo "Install attempt $i failed (unlock the iPhone?), retrying…"; sleep 5
done
timeout 60 xcrun devicectl device process launch --device "$BLUEY_DEVICE" --terminate-existing "$BLUEY_BUNDLE_PREFIX.phone" >/dev/null && echo "Launched"
