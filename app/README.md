# Plate for iPhone

The SwiftUI app (iOS 26, iPhone) for a Plate server (`server/`). It keeps an offline copy of your log,
syncs within a second of any change, and logs by search, barcode, favorites or quick add. Set up the
server first (`server/README.md`): you need its HTTPS URL and a token from `food token new`.

## Build it with Xcode

You need Xcode 26 and an Apple account (a free one works for your own phone, without HealthKit; see below).

```
brew install xcodegen
cd app
xcodegen
open Plate.xcodeproj
```

`xcodegen` writes `Plate.xcodeproj` from `project.yml`. The project is generated and gitignored, so
rerun `xcodegen` after pulling changes that add or remove files.

Then set your own bundle id and team. Create `app/Local.xcconfig` (gitignored):

```
PLATE_BUNDLE_ID = com.yourname.plate
PLATE_DEVELOPMENT_TEAM = ABCDE12345
```

Your team id is in Xcode → Settings → Accounts, or at developer.apple.com → Membership. (You can also
pick the team in the target's Signing & Capabilities tab, but `Local.xcconfig` survives regenerating the
project.) Choose your iPhone as the run destination and press Run.

### HealthKit

The app reads a few Apple Health numbers (weight, active and resting energy, steps, exercise minutes,
height, birth date, sex) as daily totals and sends them to your server so your calorie goal adapts. That
needs the HealthKit capability on your App ID: with automatic signing and a paid developer account Xcode
adds it for you from `Plate.entitlements`; otherwise enable HealthKit for the App ID at
developer.apple.com → Identifiers.

Free accounts can't use HealthKit. To build without it, add this line to `Local.xcconfig`:

```
PLATE_ENTITLEMENTS =
```

Everything else works the same; Settings → Apple Health says it isn't available, and goals use the body
facts you give the server (`food goals profile ...`).

## Connect it to your server

On first launch Plate asks for the server's URL (for example `https://plate.example.com` or
`https://<machine>.<tailnet>.ts.net:8445`) and the token. It checks `/v1/ping`, then the token with
`/v1/sync`, and says what's wrong if either fails. The URL is kept in the app's settings and the token in
the iOS Keychain. Settings → Server has **Change server** and **Sign out** (which deletes the phone's copy
of the log; everything on the server stays).

Instead of typing, you can use a setup link:

```
plate://setup?url=https%3A%2F%2Fplate.example.com&token=YOUR_TOKEN
```

Open it on the phone (from Notes or Messages, say), copy it and tap **Paste setup link**, or show it as a
QR code and tap **Scan QR code**:

```
qrencode -t ansiutf8 "plate://setup?url=https%3A%2F%2Fplate.example.com&token=YOUR_TOKEN"
```

Days follow the server's time zone (`timezone` in the server's config), so the app, the server and its
CLI agree on what "today" is. Until the first sync the app uses the phone's zone.

## AI logging

The camera button in the Quick Log bar (and "Snap or describe" in the Add sheet, or "Ask AI" under a search)
turns a photo or a few words into a draft meal you check and log in one tap. The agent runs on your server
(SPEC "AI logging"); set it up in Settings → AI logging: a provider (OpenRouter, or any OpenAI-compatible
server), an API key, a model, and optionally your own instructions. The key goes to the server once and is
never stored on the phone. Photos are scaled to 1024 px and re-encoded without EXIF or GPS before they're sent.
Taking photos uses the camera permission; picking one uses the system photo picker, which needs none.

## Build it with the scripts (no Xcode project)

`build-env.sh`, `ios-build.sh` (an unsigned device `.ipa`, for your own signing step), `sim-build.sh`
(a simulator app) and `ios-test.sh` (lint, logic tests and a simulator self-test) build the same sources
with plain `swiftc`. Their settings come from the environment, then `app/local.env`, then
`~/.config/plate/local.env` (both gitignored, `KEY=value` lines):

| Key | Meaning |
|---|---|
| `PLATE_BUNDLE_ID` | The bundle id written into Info.plist (default `com.example.plate`). |
| `PLATE_SECRETS` | Path to an optional `Secrets.swift`, or `none`. |
| `PLATE_HEALTH_SECRETS` | Path to an optional `HealthSecrets.swift`, or `none`. |
| `PLATE_SECRETS_DIR` | Another directory to look in for both files. |
| `PLATE_REQUIRE_SECRETS` | `1`: `ios-build.sh` fails unless both files are found. |

Both secrets files are optional, gitignored, and looked for in `app/`, `PLATE_SECRETS_DIR` and
`~/.config/plate/`:

- `Secrets.swift` builds a server connection into the app, so it skips onboarding (it's saved to the
  Keychain on first launch, and again whenever the file changes):
  ```swift
  enum Secrets {
      static let serverURL = "https://plate.example.com"
      static let token = "..."
  }
  ```
- `HealthSecrets.swift` is for people who also run a separate Personal Health server: the app then
  uploads every Health type there (`Sources/HealthSync`) instead of sending daily totals to the Plate
  server, and the Plate server pulls them with `food health refresh`.
  ```swift
  import Foundation
  enum HealthSecrets {
      static let url = URL(string: "https://health.example.com/ingest")!
      static let token = "..."
  }
  ```

Run the tests with `./ios-test.sh` (`PLATE_SIM_TEST=0` skips the simulator part).
