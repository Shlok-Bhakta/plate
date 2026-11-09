#!/usr/bin/env bash
# Builds Plate.app for the iOS simulator (debug), for visual QA: ./sim-build.sh [out-dir]
# Then: xcrun simctl install <udid> <out>/Plate.app && xcrun simctl launch <udid> <bundle id> -PlateDemo YES
# Uses Secrets.swift when it's found (PLATE_SECRETS=none builds without it, to see onboarding). The
# simulator never talks to a health server: HealthSecrets.swift is a placeholder when found, and left out
# with PLATE_HEALTH_SECRETS=none.
set -euo pipefail
cd "$(dirname "$0")"
source ./build-env.sh

out="${1:-build/sim}"
mkdir -p "$out"
secrets="$(plate_secrets)" || secrets=""
health_secrets=""
if plate_health_secrets >/dev/null; then health_secrets="$out/HealthSecrets.swift"; plate_placeholder_health_secrets "$health_secrets"; fi
plate_secret_args "$secrets" "$health_secrets"
app="$out/Plate.app"
rm -rf "$app"
mkdir -p "$app"
plate_info_plist "$app/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$app/Info.plist"
plate_assets iphonesimulator "$app" "$out/assets.plist" > "$out/actool.log" || { cat "$out/actool.log"; exit 1; }
/usr/libexec/PlistBuddy -c "Merge $out/assets.plist" "$app/Info.plist" >/dev/null

# Simulator entitlements: an application identifier (the Keychain, where the server token lives, needs one)
# and HealthKit.
cat > "$out/sim.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>SIMULATOR.$PLATE_BUNDLE_ID</string>
  <key>keychain-access-groups</key><array><string>SIMULATOR.$PLATE_BUNDLE_ID</string></array>
  <key>com.apple.developer.healthkit</key><true/>
</dict></plist>
PLIST

nice -n 10 xcrun --sdk iphonesimulator swiftc \
  -target "arm64-apple-ios${PLATE_MIN_OS}-simulator" \
  "${PLATE_FLAGS[@]}" \
  -Onone -g \
  -module-cache-path "$out/ModuleCache" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$out/sim.entitlements" \
  "${PLATE_SOURCES[@]}" "${PLATE_SECRET_ARGS[@]+"${PLATE_SECRET_ARGS[@]}"}" \
  -o "$app/Plate"
codesign -f -s - "$app" >/dev/null 2>&1
echo "$app"
