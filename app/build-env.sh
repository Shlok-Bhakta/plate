# Shared by ios-build.sh, ios-test.sh and sim-build.sh (sourced, not run).
# Plain swiftc, no Xcode project, no SwiftPM. (project.yml is the Xcode route to the same sources.)
#
# Local settings come from the environment, then app/local.env, then ~/.config/plate/local.env (both
# gitignored; KEY=value lines, # comments). The first one that sets a key wins.
#
#   PLATE_BUNDLE_ID        the app's bundle id (default com.example.plate)
#   PLATE_SECRETS          path to Secrets.swift, or "none" to build without one
#   PLATE_HEALTH_SECRETS   path to HealthSecrets.swift, or "none"
#   PLATE_SECRETS_DIR      another directory to look in for both (Gala's mirror of the project skips
#                          gitignored files, so the secrets have to be found outside it)
#   PLATE_REQUIRE_SECRETS  1: ios-build.sh fails unless both secrets files are found
#
# Both secrets files are optional. Secrets.swift (`enum Secrets { static let serverURL, token }`) seeds the
# server connection so the app skips onboarding; HealthSecrets.swift (`enum HealthSecrets { static let
# url: URL, token }`) turns on HealthSync to a separate health server. See Sources/Support/BuildFeatures.swift.

plate_load_local_env() {
  local file line key value
  for file in ./local.env "$HOME/.config/plate/local.env"; do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      key="${line%%=*}"; value="${line#*=}"
      key="${key//[[:space:]]/}"
      case "$key" in PLATE_*) ;; *) continue ;; esac
      value="${value#\"}"; value="${value%\"}"
      [ -n "${!key+x}" ] || export "$key=$value"
    done < "$file"
  done
}
plate_load_local_env

PLATE_BUNDLE_ID="${PLATE_BUNDLE_ID:-com.example.plate}"
PLATE_MIN_OS=26.0
PLATE_FLAGS=(-swift-version 5 -parse-as-library -module-name Plate
  -framework SwiftUI -framework VisionKit -framework AVFoundation -framework MetricKit -framework Charts -framework HealthKit)

# Every app source, in a stable order. Sources/Core is pure Foundation (the logic tests compile it alone).
PLATE_SOURCES=()
while IFS= read -r f; do PLATE_SOURCES+=("$f"); done < <(find Sources -name '*.swift' | LC_ALL=C sort)
PLATE_CORE=()
while IFS= read -r f; do PLATE_CORE+=("$f"); done < <(find Sources/Core -name '*.swift' | LC_ALL=C sort)

# plate_secret_file <name> <override>: prints the first that exists of the override, ./<name>,
# $PLATE_SECRETS_DIR/<name> and ~/.config/plate/<name>. An override of "none" finds nothing.
plate_secret_file() {
  local name="$1" override="$2" candidate
  [ "$override" = none ] && return 1
  for candidate in "$override" "./$name" "${PLATE_SECRETS_DIR:+$PLATE_SECRETS_DIR/$name}" "$HOME/.config/plate/$name"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then echo "$candidate"; return 0; fi
  done
  return 1
}
plate_secrets() { plate_secret_file Secrets.swift "${PLATE_SECRETS:-}"; }
plate_health_secrets() { plate_secret_file HealthSecrets.swift "${PLATE_HEALTH_SECRETS:-}"; }

# plate_secret_args <Secrets.swift or ""> <HealthSecrets.swift or "">: sets PLATE_SECRET_ARGS to the files
# and the -D flag for each (PLATE_SECRETS, PLATE_HEALTH_SERVER) that BuildFeatures checks.
plate_secret_args() {
  PLATE_SECRET_ARGS=()
  if [ -n "$1" ]; then PLATE_SECRET_ARGS+=("$1" -D PLATE_SECRETS); fi
  if [ -n "$2" ]; then PLATE_SECRET_ARGS+=("$2" -D PLATE_HEALTH_SERVER); fi
}

# Placeholders for tests, which never need the real tokens. Both URLs are unroutable on purpose, so a
# test run can't reach a real server.
plate_placeholder_secrets() {
  printf 'enum Secrets {\n    static let serverURL = "https://127.0.0.1:9"\n    static let token = "placeholder"\n}\n' > "$1"
}
plate_placeholder_health_secrets() {
  printf 'import Foundation\n\nenum HealthSecrets {\n    static let url = URL(string: "https://127.0.0.1:9/ingest")!\n    static let token = "placeholder"\n}\n' > "$1"
}

# plate_info_plist <out>: Info.plist with the bundle id filled in (Xcode does this itself from
# PRODUCT_BUNDLE_IDENTIFIER).
plate_info_plist() {
  sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$PLATE_BUNDLE_ID/g" Info.plist > "$1"
  plutil -lint -s "$1"
}

# plate_assets <iphoneos|iphonesimulator> <app dir> <partial plist out>
# Compiles the asset catalog; the app icon is optional while it's being drawn.
plate_assets() {
  # actool runs in a shared daemon whose working directory isn't ours, so every path must be absolute.
  local platform="$1" app partial dir
  app="$(cd "$2" && pwd)"
  dir="$(cd "$(dirname "$3")" && pwd)"; partial="$dir/$(basename "$3")"
  local catalog="$PWD/Assets.xcassets"
  local icon=() set
  if [ -d Assets.xcassets/AppIcon.appiconset ]; then icon=(--app-icon AppIcon); else echo "note: no AppIcon.appiconset yet, building without an icon"; fi
  # Alternate icons (Settings → App Icon): each AppIcon-<ID>.appiconset goes into Assets.car, and actool
  # lists them under CFBundleIcons → CFBundleAlternateIcons in the partial Info.plist merged below.
  for set in Assets.xcassets/AppIcon-*.appiconset; do
    [ -d "$set" ] && icon+=(--alternate-app-icon "$(basename "$set" .appiconset)")
  done
  xcrun actool "$catalog" --compile "$app" --platform "$platform" --minimum-deployment-target "$PLATE_MIN_OS" \
    "${icon[@]}" --accent-color AccentColor --target-device iphone \
    --output-partial-info-plist "$partial" --errors --warnings --output-format human-readable-text
}
