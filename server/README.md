# Plate server

`food` is the server behind Plate, an iPhone food log. It is one Rust binary:

- `food serve` runs the service. It keeps your log (foods, recipes, entries, goals and daily
  health numbers) in an encrypted SQLite database and syncs it with the iPhone app over a small
  HTTP API, with changes reaching the phone within a second.
- Every other subcommand (`food log`, `food today`, `food search`, `food report`, ...) is a client
  of the service's local Unix socket. People, scripts and AI agents log food with it, for example
  from a photo of a meal. The database and its key never leave the service.

It imports the USDA FoodData Central catalog (about 13,600 foods with full micronutrients),
looks up barcodes and branded foods on Open Food Facts, and computes adaptive calorie and
nutrient goals from your weight, height, age, sex and activity.

It runs on Linux or macOS as your normal user. No root, no Docker, no external database.

## Quick start

You need a Rust toolchain ([rustup.rs](https://rustup.rs)) and a C compiler (SQLCipher and
OpenSSL are built from source and linked in).

```
cargo build --release
./target/release/food init          # config, data directory and database key; prints next steps
./target/release/food serve         # the service, in the foreground (or install a unit, below)
```

In another terminal:

```
./target/release/food token new     # the app token: enter it in the app with the server's URL
./target/release/food seed-usda     # download and import the USDA catalog once (about 15 MB)
./target/release/food log --catalog "banana raw" --grams 118
./target/release/food today
```

Then make the server reachable from your phone over HTTPS (see "Reaching it from the phone")
and enter its URL and the token in the app's settings.

`food init` takes `--data-dir`, `--listen`, `--timezone` and `--encryption keyfile|none`. It is
safe to rerun: it never replaces an existing key.

### Keeping it running

- **Linux (systemd):** `deploy/plate.service` is a user unit. Copy the binary to
  `~/.local/bin/food`, then:
  ```
  install -D -m 644 deploy/plate.service ~/.config/systemd/user/plate.service
  systemctl --user daemon-reload && systemctl --user enable --now plate.service
  loginctl enable-linger "$USER"     # keep running while logged out
  ```
- **macOS (launchd):** `deploy/plate.plist` is a LaunchAgent; the instructions are in the file.
- **Hardened Linux:** `deploy/hardened/` runs the service as a dedicated system user with its key
  sealed to the machine's TPM. See its README.

## Configuration

`food config` prints the effective settings, the config file it read, how the database is
keyed, and whether the service answers.

The config file is the first that exists of `$FOOD_CONFIG`, `~/.config/plate/config.toml`
(or `$XDG_CONFIG_HOME/plate/config.toml`) and `/etc/plate/config.toml`. It is plain
`key = value` lines with `#` comments. Every key can also be set with an environment variable,
which wins over the file. No file is needed: everything has a default.

| Key | Environment | Default | Meaning |
|---|---|---|---|
| `data_dir` | `FOOD_DATA_DIR` | `~/.local/share/plate` | The database and key file. |
| `database` | `FOOD_DB` | `<data_dir>/food.db` | The database file. |
| `listen` | `FOOD_LISTEN` | `127.0.0.1:18792` | The app's HTTP address. Keep it on loopback. |
| `socket` | `FOOD_SOCKET` | `$XDG_RUNTIME_DIR/plate/food.sock` on Linux, `<data_dir>/food.sock` on macOS | The CLI's Unix socket. |
| `socket_uids` | `FOOD_SOCKET_UIDS` | none | Other local users (uids or names) the socket answers. The service's own user and root always are. |
| `timezone` | `FOOD_TIMEZONE` | the system zone | An IANA zone such as `Europe/Berlin`, used for every day, "today", report and default meal. |
| `encryption` | `FOOD_ENCRYPTION` | `auto` | `keyfile`, `systemd-credential`, `none` or `auto`. See below. |
| `key_file` | `FOOD_KEY_FILE` | `<data_dir>/food.key` | The SQLCipher key: 64 hex digits, mode 600. |
| `credential` | `FOOD_CREDENTIAL` | `food-key` | The systemd credential holding the key. |
| `cache_dir` | `FOOD_CACHE_DIR` | `~/.cache/plate` | Downloads for `food seed-usda`. |
| `off_contact` | `FOOD_OFF_CONTACT` | none | An email or URL added to the User-Agent sent to Open Food Facts and USDA (they ask for one). |
| `health_command` | `FOOD_HEALTH_COMMAND` | `health` | The Personal Health CLI used by `food health refresh` (optional). |
| `health_owner` | `FOOD_HEALTH_OWNER` | inferred | Whose devices count in `food health refresh`. |

Example:

```
data_dir = ~/.local/share/plate
listen = 127.0.0.1:18792
encryption = keyfile
timezone = America/New_York
off_contact = me@example.com
```

Time zones are read from the system's zoneinfo files (`/usr/share/zoneinfo`, present on Linux
and macOS). Entries keep the day they were logged on, so changing the zone later only affects
new entries and how "today" is computed.

## Encryption

| Mode | What it does | Protects against | Doesn't protect against |
|---|---|---|---|
| `keyfile` (what `food init` sets up) | SQLCipher (AES-256), keyed by `key_file`. | A copied database file or backup, a lost disk without the key file. | Anything running as your user, which can read the key file too. |
| `systemd-credential` | SQLCipher, keyed by a systemd credential (`LoadCredentialEncrypted=`), which can be sealed to the machine's TPM. | The above, plus a copied disk: the key opens only on that machine. Used by `deploy/hardened`. | Root on the running machine. If the TPM is reset, the data is gone without a backup. |
| `none` | Plain SQLite. | Nothing. | Anyone who can read the file. Fine on a machine with full-disk encryption you alone use. |
| `auto` (the default) | The systemd credential if the service has one, else `key_file` if it exists. With neither, `food serve` refuses to start. | | |

Keep a copy of the key file somewhere safe: without it the database can't be opened. A key file
readable by other users is refused. To switch modes, `food export`, set up a new data directory
with `food init`, and `food import`.

## Reaching it from the phone

The server speaks plain HTTP on `127.0.0.1`. The phone needs HTTPS. **Never expose the port
plain-HTTP on the internet:** the bearer token and your log would travel in the clear.

**Tailscale (recommended).** Install Tailscale on the server and the phone, then:

```
tailscale serve --bg --https=8445 http://127.0.0.1:18792
```

The app's URL is `https://<machine>.<tailnet>.ts.net:8445`. Only your tailnet can reach it, and
Tailscale handles the certificate.

**A reverse proxy with TLS.** For a public hostname, put Caddy (or nginx) in front. A
`Caddyfile`:

```
plate.example.com {
    reverse_proxy 127.0.0.1:18792
}
```

Caddy gets and renews the certificate itself. Every API route except `/v1/ping` needs the
token; still, prefer a private network when you can.

Check it with `curl https://<your URL>/v1/ping` (no token) and
`curl -H "Authorization: Bearer <token>" https://<your URL>/v1/sync?since=0`.

## The CLI, for people and agents

Run `food --help` for the commands and conventions, and `food <command> --help` for each one.
The help is written to be the complete documentation for an AI agent that logs food on your
behalf: it covers logging a meal from a photo (`food log --help`), the nutrient keys
(`food help nutrients`), reading the database with read-only SQL (`food query`), and more.
Help never needs the service.

The CLI talks to the service over the Unix socket, so it works as the user running the service
(and root). To let another local user log food, add their uid or name to `socket_uids`.

## Goals and health data

Goals start at 2,200 kcal. Give the server a few body facts and they adapt:

```
food goals profile weight=172lb height=70in age=34 sex=female activity=light
food goals plan cut          # or maintain, bulk
food goals set protein=150   # override any target
```

TDEE is BMR (Mifflin-St Jeor) times the activity factor, or BMR plus your real active energy
once there are 5 days of it. Health data can come from anywhere:

- `food health import data.csv` (or `.json`, or stdin) takes daily rows of
  `day, weight_kg, active_kcal, basal_kcal, steps, exercise_min`, plus an optional profile
  (`--birth-date`, `--sex`, `--height-cm`). See `food health --help`.
- `POST /v1/health_days` takes the same rows from the app or any script, with the app token.
- `food health refresh` pulls from a separate Personal Health server's `health` CLI, if you run
  one.

Without any of these, goals stay on the profile (or at the default, with a note saying what's
missing). Nothing is guessed.

## HTTP API

All routes but `/v1/ping` need `Authorization: Bearer <token>`. Bodies are JSON.

| Route | |
|---|---|
| `GET /v1/ping` | `{"ok": true, "version": N}` |
| `GET /v1/meta` | Nutrient keys, units, daily values, meals and the server's `timezone`. |
| `GET /v1/sync?since=V&wait=S` | Every row changed since version V; long-polls up to 25 s. |
| `POST /v1/mutations` | `{"mutations": [{"table", "op": "upsert"\|"delete", "row"}]}`, last writer wins. |
| `GET /v1/search?q=...` | Your foods, the USDA catalog and Open Food Facts. |
| `GET /v1/barcode/{code}` | A product by barcode (saved as a food). |
| `GET /v1/suggest?meal=...` | Recents, frequent foods and yesterday's same meal. |
| `POST /v1/health_days` | `{"days": [{"day": "YYYY-MM-DD", "weight_kg", "active_kcal", "basal_kcal", "steps", "exercise_min"}], "profile": {...}}` |

## Backups

```
food export ~/plate-backup.json     # everything that syncs, as JSON (mode 600)
food import ~/plate-backup.json     # restore; rows already newer are kept
```

The export goes through the service, so it works whatever the encryption mode, including a
TPM-sealed key. It includes foods, recipes, entries, goals, health days, deletions and the
profile; the USDA catalog is rebuilt with `food seed-usda`. The file itself isn't encrypted, so
store it somewhere private (or encrypt it, for example with `age` or `gpg`). A copy of the data
directory taken while the service is stopped, together with the key file, is also a complete
backup.

## Tests

```
cargo test --release
```

## Data sources and attribution

- **USDA FoodData Central** (Foundation Foods, SR Legacy and FNDDS), U.S. Department of
  Agriculture, Agricultural Research Service, [fdc.nal.usda.gov](https://fdc.nal.usda.gov). It is
  in the public domain (CC0 1.0). `food seed-usda` downloads it directly from USDA.
- **Open Food Facts** ([openfoodfacts.org](https://world.openfoodfacts.org)): barcode lookups and
  branded-food search. The data is © Open Food Facts contributors, available under the
  [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/); product
  images and individual contents are under their own licenses. Plate caches the products you look
  up. If you share data derived from it, keep the attribution and the ODbL terms.
- Daily values are the U.S. FDA's; adult RDAs are from the National Academies' Dietary Reference
  Intakes.
