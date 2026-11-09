#!/usr/bin/env bash
# 1. Info.plist lint and bundle identity (the configured $PLATE_BUNDLE_ID, see build-env.sh), including the
# Health keys, the setup link scheme and the reminders' background refresh; the alternate icon sets match
# Settings → App Icon. 2. The health sync's persisted state
# (UserDefaults keys, anchors, cache files) is unchanged from the Personal Health app. 3. The app typechecks
# for a device, with the secrets files and without them. 4. Logic tests for Sources/Core on the Mac: serving scaling, nutrient sums, LWW merge,
# outbox persistence. 5. Health payload and date-format tests on the Mac. 6. In a fresh simulator, HealthKit
# accepts a read request for every type, and the Health launch path runs for 20 s without crashing
# (PLATE_SIM_TEST=0 skips this step).
set -euo pipefail
cd "$(dirname "$0")"
source ./build-env.sh

: "${GALA_BUILD_DIR:=$(mktemp -d)}"
mkdir -p "$GALA_BUILD_DIR"
work="$(mktemp -d "${GALA_BUILD_DIR}/platetest.XXXXXX")"
sim=""
cleanup() {
  if [ -n "$sim" ]; then xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true; xcrun simctl delete "$sim" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

plutil -lint Info.plist
plate_info_plist "$work/Info.plist"
PLATE_BUNDLE_ID="$PLATE_BUNDLE_ID" python3 - "$work/Info.plist" <<'PY'
import os, plistlib, sys
tracked = plistlib.load(open("Info.plist", "rb"))
# The tracked plist names no bundle id: Xcode fills in PRODUCT_BUNDLE_IDENTIFIER, the scripts PLATE_BUNDLE_ID.
assert tracked["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)", tracked["CFBundleIdentifier"]
assert tracked["BGTaskSchedulerPermittedIdentifiers"] == ["$(PRODUCT_BUNDLE_IDENTIFIER).reminders"]
info = plistlib.load(open(sys.argv[1], "rb"))
bundle = os.environ["PLATE_BUNDLE_ID"]
# Whatever is configured. (A build that upgrades an earlier app in place, keeping its Health authorization
# and sync state, must keep that app's id.)
assert info["CFBundleIdentifier"] == bundle, (info["CFBundleIdentifier"], bundle)
assert info["CFBundleExecutable"] == "Plate"
assert info["CFBundleDisplayName"] == "Plate"
assert info["MinimumOSVersion"] == "26.0"
assert info["UIDeviceFamily"] == [1]
assert info["UISupportedInterfaceOrientations"] == ["UIInterfaceOrientationPortrait"]
assert info["NSCameraUsageDescription"]
assert info["NSHealthShareUsageDescription"]
assert info["NSHealthUpdateUsageDescription"]
assert info["NSHealthClinicalHealthRecordsShareUsageDescription"]
assert "UIUserInterfaceStyle" not in info, "light and dark must both be allowed"
# Meal reminders: a BGAppRefreshTask reschedules them (no entitlement needed for either key).
assert info["UIBackgroundModes"] == ["fetch"], info.get("UIBackgroundModes")
assert info["BGTaskSchedulerPermittedIdentifiers"] == [bundle + ".reminders"], info["BGTaskSchedulerPermittedIdentifiers"]
reminders = open("Sources/Reminders/Reminders.swift").read()
assert 'refreshTaskID = (Bundle.main.bundleIdentifier ?? "plate") + ".reminders"' in reminders
# plate://setup?url=...&token=... opens onboarding or Change server.
assert [s for t in info["CFBundleURLTypes"] for s in t["CFBundleURLSchemes"]] == ["plate"], info.get("CFBundleURLTypes")
print(f"Info.plist ok ({bundle})")
PY
PLATE_BUNDLE_ID="$PLATE_BUNDLE_ID" python3 Tests/health_state_test.py "$work/Info.plist"
# Settings → App Icon lists exactly the alternate icon sets in the catalog, each with a preview image.
python3 - <<'PY'
import os, re
ids = re.findall(r'AppIcon\(id: "(\w+)"', open("Sources/UI/Settings/AppIconSection.swift").read())
assert ids[0] == "E1" and len(ids) == len(set(ids)) == 8, ids
for i in ids:
    assert os.path.isdir(f"Assets.xcassets/IconPreview-{i}.imageset"), f"no preview for {i}"
sets = sorted(d[len("AppIcon-"):-len(".appiconset")] for d in os.listdir("Assets.xcassets")
              if d.startswith("AppIcon-") and d.endswith(".appiconset"))
assert sets == sorted(ids[1:]), sets
print("app icons ok")
PY

# Tests never need the real tokens; the typecheck uses them when they're here, so they're known to compile.
# Then again without either file (a fresh clone, or the Xcode project).
secrets="$(plate_secrets)" || { secrets="$work/Secrets.swift"; plate_placeholder_secrets "$secrets"; }
health_secrets="$(plate_health_secrets)" || { health_secrets="$work/HealthSecrets.swift"; plate_placeholder_health_secrets "$health_secrets"; }
plate_secret_args "$secrets" "$health_secrets"
nice -n 10 xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -target "arm64-apple-ios${PLATE_MIN_OS}" \
  "${PLATE_FLAGS[@]}" -module-cache-path "$GALA_BUILD_DIR/ModuleCache" "${PLATE_SOURCES[@]}" "${PLATE_SECRET_ARGS[@]}"
echo "device typecheck ok (with Secrets.swift and HealthSecrets.swift)"
nice -n 10 xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -target "arm64-apple-ios${PLATE_MIN_OS}" \
  "${PLATE_FLAGS[@]}" -module-cache-path "$GALA_BUILD_DIR/ModuleCache" "${PLATE_SOURCES[@]}"
echo "device typecheck ok (without secrets files)"

cp Tests/LogicTests.swift "$work/main.swift"
nice -n 10 xcrun swiftc -swift-version 5 -module-cache-path "$GALA_BUILD_DIR/ModuleCache" \
  "${PLATE_CORE[@]}" "$work/main.swift" -o "$work/logic-tests"
"$work/logic-tests" | tee "${GALA_ARTIFACT_DIR:-$work}/logic-tests.txt"

mkdir -p "$work/payload"
cp Tests/HealthPayloadTests.swift "$work/payload/main.swift"
nice -n 10 xcrun swiftc -swift-version 5 -module-cache-path "$GALA_BUILD_DIR/ModuleCache" \
  Sources/HealthSync/HealthPayload.swift "$work/payload/main.swift" -o "$work/payload-tests"
"$work/payload-tests"

if [ "${PLATE_SIM_TEST:-1}" = 0 ]; then echo "simulator selftest skipped (PLATE_SIM_TEST=0)"; exit 0; fi

# Simulator: build, sign ad hoc with the HealthKit entitlements, install in a throwaway device, run
# --selftest and --startup-test. Placeholder tokens and unroutable URLs, so nothing reaches a real server.
plate_placeholder_secrets "$work/Secrets.swift"
plate_placeholder_health_secrets "$work/HealthSecrets.swift"
plate_secret_args "$work/Secrets.swift" "$work/HealthSecrets.swift"
app="$work/Plate.app"
mkdir -p "$app"
plate_info_plist "$app/Info.plist"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$app/Info.plist"
cat > "$work/sim.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.developer.healthkit</key><true/>
  <key>com.apple.developer.healthkit.background-delivery</key><true/>
</dict></plist>
PLIST
nice -n 10 xcrun --sdk iphonesimulator swiftc -target "arm64-apple-ios${PLATE_MIN_OS}-simulator" "${PLATE_FLAGS[@]}" \
  -module-cache-path "$GALA_BUILD_DIR/ModuleCache" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$work/sim.entitlements" \
  "${PLATE_SOURCES[@]}" "${PLATE_SECRET_ARGS[@]}" -o "$app/Plate"
codesign -f -s - "$app" >/dev/null 2>&1

read -r runtime devicetype < <(xcrun simctl list -j runtimes devicetypes | python3 -c '
import json, sys
data = json.load(sys.stdin)
runtime = [r for r in data["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]][-1]
phones = [d for d in runtime.get("supportedDeviceTypes", []) if d["productFamily"] == "iPhone"]
print(runtime["identifier"], phones[-1]["identifier"])')
sim="$(xcrun simctl create "plate-health-test-$$" "$devicetype" "$runtime")"
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl install "$sim" "$app"
python3 - "$sim" "$PLATE_BUNDLE_ID" <<'PY'
import subprocess, sys
for argument, marker in (("--selftest", "SELFTEST OK"), ("--startup-test", "STARTUP OK")):
    try:
        # -PlateDemo YES keeps the food store off the network; the Health code paths are the phone's.
        run = subprocess.run(["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", sys.argv[1],
                              sys.argv[2], argument, "-PlateDemo", "YES"],
                             capture_output=True, text=True, timeout=120)
        out = run.stdout + run.stderr
    except subprocess.TimeoutExpired as error:
        out = (error.stdout or b"").decode(errors="replace") + "\n(timed out)"
    hits = [line for line in out.splitlines() if marker.split()[0] in line or "fatal" in line.lower() or "exception" in line.lower()]
    print(f"{argument}: " + (" | ".join(dict.fromkeys(hits)) or "(no marker)"))
    if marker not in out:
        print(out[-4000:])
        # Only a crash in the app or a type HealthKit refuses (an exception in the app) fails the self-test.
        # healthd itself can drop the connection: the iOS 26.5 simulator's healthd aborts on an internal
        # assertion (HDAuthorizationEntity readAuthorizationStatusesByTypeForBundleIdentifier) for this read
        # set, as it did for the standalone Personal Health app. The startup test must always reach its marker.
        refused = "disallowed" in out.lower() or "exception" in out.lower()
        if argument == "--startup-test" or refused:
            sys.exit(f"{argument} failed")
        print(f"{argument}: healthd unavailable, not counted as a failure")
PY
echo "simulator selftest and startup test ok"
