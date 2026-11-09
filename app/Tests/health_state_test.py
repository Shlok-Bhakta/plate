"""The health sync's persisted state must stay byte-for-byte what the Personal Health app used.

A build with HealthSecrets.swift can take over the Personal Health app's bundle id (set as PLATE_BUNDLE_ID
in local.env), so the phone keeps that app's UserDefaults and container. If any of these names or formats
change, the next sync starts from no anchors and re-uploads the whole Health history (millions of samples).
Run by ios-test.sh from app/ as: health_state_test.py <built Info.plist>, with PLATE_BUNDLE_ID set.
"""
import os
import plistlib
import re
import sys
from pathlib import Path

# Found in the Personal Health app's sources (Sync.swift, Breadcrumbs.swift, GalaReporter.swift)
# at build 11, the last standalone delivery.
BUNDLE_ID = os.environ["PLATE_BUNDLE_ID"]  # the configured id; the built plist must carry it
USER_DEFAULTS_KEYS = {"sent", "lastSync", "requested", "lastDailySync"}  # Int, Date, Bool, Date
ANCHOR_PREFIX = "anchor."  # + HKSampleType.identifier: NSKeyedArchiver data of an HKQueryAnchor
ANCHOR_WRITE = "NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)"
ANCHOR_READ = "NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)"
CACHE_FILES = {"breadcrumbs.txt", "gala-uncaught-exception.txt"}  # in Library/Caches

sources = {p: p.read_text() for p in Path("Sources").rglob("*.swift")}
sync = Path("Sources/HealthSync/HealthSync.swift").read_text()
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


info = plistlib.loads(Path(sys.argv[1]).read_bytes())
check(info["CFBundleIdentifier"] == BUNDLE_ID, f"bundle id is {info['CFBundleIdentifier']}")

keys = set(re.findall(r'forKey:\s*"([^"]*)"', sync))
check(keys == USER_DEFAULTS_KEYS | {ANCHOR_PREFIX}, f"HealthSync UserDefaults keys changed: {sorted(keys)}")
check(sync.count(f'forKey: "{ANCHOR_PREFIX}" + type.identifier') == 2, "anchor key is no longer \"anchor.\" + type.identifier")
check(ANCHOR_WRITE in sync and ANCHOR_READ in sync, "anchor archive format changed")
check(all("UserDefaults.standard." in line for line in sync.splitlines() if "forKey:" in line),
      "a HealthSync key isn't read or written through UserDefaults.standard")

for path, text in sources.items():
    check("UserDefaults(suiteName" not in text, f"{path}: a UserDefaults suite moves keys out of the app's domain")
    if path.parts[1] != "HealthSync":
        clash = [k for k in re.findall(r'forKey:\s*"([^"]*)"', text) if k in USER_DEFAULTS_KEYS or k.startswith(ANCHOR_PREFIX)]
        check(not clash, f"{path}: Plate code uses a health key: {clash}")
    if path.parts[1] != "Support":
        for name in re.findall(r'appending(?:PathComponent)?\((?:path:\s*)?"([^"]+)"', text):
            check(name not in CACHE_FILES, f"{path}: writes {name}, which the health app's container already uses")

crumbs = Path("Sources/Support/Breadcrumbs.swift").read_text()
check(".cachesDirectory" in crumbs and '.appending(path: "breadcrumbs.txt")' in crumbs, "breadcrumbs file moved")
gala = Path("Sources/Support/GalaReporter.swift").read_text()
check(".cachesDirectory" in gala and '"gala-uncaught-exception.txt"' in gala, "Gala exception file moved")
store = Path("Sources/Sync/Store.swift").read_text()
check('.applicationSupportDirectory' in store and '.appending(path: "Plate", directoryHint: .isDirectory)' in store,
      "Plate's cache must stay in Application Support/Plate, apart from the health app's files")

if failures:
    print("\n".join("FAIL " + f for f in failures))
    sys.exit(1)
print(f"health persisted state ok: {len(USER_DEFAULTS_KEYS)} keys, anchors, {len(CACHE_FILES)} cache files")
