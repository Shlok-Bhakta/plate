#!/usr/bin/env bash
# Gala recipe: builds an unsigned device IPA (Payload/Plate.app) into $GALA_ARTIFACT_DIR.
# No entitlements file: the signing step (Gala) signs with a provisioning profile for $PLATE_BUNDLE_ID and
# applies that profile's entitlements, HealthKit included.
#
# The bundle id and the optional secrets come from build-env.sh (app/local.env or ~/.config/plate/local.env).
# Without Secrets.swift the app asks for its server on first launch; without HealthSecrets.swift Apple Health
# goes to the food server. PLATE_REQUIRE_SECRETS=1 makes a missing file an error instead.
set -euo pipefail
cd "$(dirname "$0")"

: "${GALA_BUILD_DIR:?Gala Engine sets this}"
: "${GALA_ARTIFACT_DIR:?Gala Engine sets this}"
source ./build-env.sh

missing() {
  if [ "${PLATE_REQUIRE_SECRETS:-0}" = 1 ]; then echo "error: $1 not found (app/, \$PLATE_SECRETS_DIR or ~/.config/plate/) and PLATE_REQUIRE_SECRETS=1"; exit 1; fi
  echo "note: no $1, $2"
}
secrets="$(plate_secrets)" && echo "using secrets from $secrets" || { secrets=""; missing Secrets.swift "the app will ask for its server"; }
health_secrets="$(plate_health_secrets)" && echo "using health secrets from $health_secrets" \
  || { health_secrets=""; missing HealthSecrets.swift "Apple Health goes to the food server"; }
plate_secret_args "$secrets" "$health_secrets"
echo "bundle id $PLATE_BUNDLE_ID"

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$GALA_BUILD_DIR" "$GALA_ARTIFACT_DIR"
work="$(mktemp -d "${GALA_BUILD_DIR}/plate.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/Payload/Plate.app"
mkdir -p "$app"
plate_info_plist "$app/Info.plist"
plate_assets iphoneos "$app" "$work/assets.plist"
/usr/libexec/PlistBuddy -c "Merge $work/assets.plist" "$app/Info.plist"

nice -n 10 xcrun --sdk iphoneos swiftc \
  -sdk "$sdk" \
  -target "arm64-apple-ios${PLATE_MIN_OS}" \
  "${PLATE_FLAGS[@]}" \
  -O \
  -module-cache-path "$GALA_BUILD_DIR/ModuleCache" \
  "${PLATE_SOURCES[@]}" "${PLATE_SECRET_ARGS[@]+"${PLATE_SECRET_ARGS[@]}"}" \
  -o "$app/Plate"

(cd "$work" && zip -qry "$GALA_ARTIFACT_DIR/Plate-unsigned.ipa" Payload)
echo "built $GALA_ARTIFACT_DIR/Plate-unsigned.ipa"
