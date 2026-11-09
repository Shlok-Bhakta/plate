# Plate: spec and contract

Plate is a self-hosted food tracker. Each server has one user. An AI agent or script on the server can do most of the logging, for example from a meal photo, through the `food` CLI. The iPhone app is the fast place to look at today, type or scan something in, and see trends. It must look like an Apple Design Award app.

**Prime directive: logging takes one or two steps.** Recents and favorites log in one tap. Search to log takes two. The agent can do anything the app can.

## Pieces

| Part | Where | What |
|---|---|---|
| `server/` | any Linux or macOS machine you control | `food`, one Rust binary. `food serve` is the service; every other subcommand is a CLI client of its Unix socket. |
| `app/` | built on a Mac with Xcode (XcodeGen), or with the `swiftc` scripts | **Plate**, a SwiftUI iPhone app (iOS 26+, Liquid Glass). It can also carry a full Apple Health sync to a separate health server (see "Health sync"). |
| `docs/DESIGN.md` | | The visual design spec for the app. |

Agents learn the CLI from its own help (`food --help`, `food <command> --help`); there's no separate agent documentation to keep in step.

## Server deployment

The generic self-hosted setup is in `server/README.md`: `food init`, then `food serve` as your own user under a systemd user unit (`deploy/plate.service`) or a LaunchAgent (`deploy/plate.plist`). `server/deploy/hardened/` is an optional, stricter Linux mode (`sudo ./deploy/hardened/install.sh`):

- Binary `/usr/local/bin/food` (root-owned). Service `personal-food.service`, run as a dedicated system user (`SERVICE_USER`), with systemd sandboxing (`ProtectSystem=strict`, `ProtectHome`, `NoNewPrivileges`, a system call filter and so on). Network access out is needed, for Open Food Facts.
- DB: SQLCipher at `$DATA/food.db`, the directory owned by the service user with mode 700. Key: a new 32-byte random key, sealed with `systemd-creds encrypt --with-key=host+tpm2 --name=food-key` into `/etc/credstore.encrypted/`, and loaded with `LoadCredentialEncrypted=food-key:...`. The install script creates it once and is safe to rerun.
- HTTP on `127.0.0.1:18792`, optionally exposed to the tailnet with `tailscale serve --bg --https=8445 http://127.0.0.1:18792`, giving `https://<machine>.<tailnet>.ts.net:8445`. The script leaves existing serve entries alone.
- Unix socket `/run/personal-food/food.sock`. It only answers root, the service's own user and the login user's uid (`READER`, passed as `FOOD_READER_UID` / `socket_uids`), checked with SO_PEERCRED. The install script writes `/etc/plate/config.toml` (socket path, no secrets) so the login user's CLI finds the socket. The socket can write, because agents log food through it.
- App auth: `Authorization: Bearer <token>`, with tokens stored as SHA-256 hashes. `food rotate-token [grace-hours]` (also `food token new`) prints a new token. The app stores it in the Keychain, entered at onboarding or built in from an optional, gitignored `app/Secrets.swift`.
- Health context (optional): if a separate Personal Health server's `health` CLI is installed, `food health refresh`, run as the login user, calls `health query ...`, builds per-day rows plus a profile (deduplicated by source, in the server's time zone), and sends them over the socket. The service never reads the health server's database. A user timer `personal-food-health.timer` runs it every 30 minutes. The service then recomputes the adaptive goals. Without a health server, the app or `food health import` supplies the same rows (see "Server notes").

## Data model

Every synced row is a JSON object stored with these server columns: `id TEXT PRIMARY KEY` (a UUID made by the client or CLI), `version INTEGER` (from one global counter the server increments on every write), `updated_at INTEGER` (ms since epoch, set by the writer), `deleted INTEGER` (tombstone), and `data TEXT` (the JSON). Keep the fields below inside `data`, alongside `id`, `updated_at` and `deleted`. Extract into columns whatever needs indexing.

### Nutrients

A nutrient map is `{ key: number }`. Missing means unknown, which is different from 0. Keys and units are fixed and shared by the server, CLI, app and agents:

```
kcal kcal | protein g | carbs g | fat g | fiber g | sugar g | added_sugar g
sat_fat g | trans_fat g | mono_fat g | poly_fat g | omega3 g | cholesterol mg
sodium mg | potassium mg | calcium mg | iron mg | magnesium mg | phosphorus mg | zinc mg
copper mg | manganese mg | selenium ug | iodine ug
vit_a ug (RAE) | vit_c mg | vit_d ug | vit_e mg | vit_k ug | thiamin mg | riboflavin mg
niacin mg | pantothenic mg | vit_b6 mg | biotin ug | folate ug (DFE) | vit_b12 ug | choline mg
caffeine mg | alcohol g | water ml
```

The server exposes the list, with display names, units, groups (`macro`, `fat`, `mineral`, `vitamin`, `other`) and FDA daily values, at `GET /v1/meta`. The app may also embed the list.

### `foods` (synced)

```json
{ "id": "uuid", "kind": "food | recipe | quick",
  "name": "Greek yogurt, plain nonfat", "brand": "Fage", "barcode": "0689544001737",
  "serving": { "amount": 1, "unit": "container", "grams": 170 },
  "portions": [ { "label": "1 cup", "grams": 245 }, { "label": "100 g", "grams": 100 } ],
  "nutrients": { "kcal": 90, "protein": 18 },
  "components": [ { "food_id": "uuid", "servings": 2 } ],
  "recipe_servings": 4,
  "source": "usda | off | custom | agent | recipe", "source_ref": "fdc:171284 | off:0689544001737",
  "favorite": false, "created_at": 0, "updated_at": 0, "deleted": false }
```

`nutrients` are for **one serving**. `serving.grams` is optional. When it's known, portions scale by grams; otherwise only by servings. For a recipe, `components` lists the ingredients, `nutrients` is the total divided by `recipe_servings`, and the server recomputes it whenever a recipe is written. `kind: quick` is a calories-and-macros-only item.

### `entries` (synced): the food log

```json
{ "id": "uuid", "day": "2026-11-08", "meal": "breakfast | lunch | dinner | snack",
  "logged_at": 0, "food_id": "uuid or null", "name": "Greek yogurt", "brand": "Fage",
  "servings": 1.5, "serving_label": "container (170 g)", "grams": 255,
  "nutrients": { "kcal": 135 },
  "note": "from photo", "source": "app | agent | barcode",
  "updated_at": 0, "deleted": false }
```

`day` is the local day in the server's configured time zone (`timezone`, default the system zone). `nutrients` is a snapshot of the **total for this entry**, so editing a food later doesn't rewrite history. Editing `servings` scales the snapshot, which the client or CLI does.

### `goals` (synced, a single row with `id = "current"`)

```json
{ "id": "current", "mode": "auto | manual", "plan": "maintain | cut | bulk",
  "targets": { "kcal": 2350, "protein": 150, "carbs": 260, "fat": 78, "fiber": 33, "sodium": 2300 },
  "overrides": { "protein": 160 },
  "limits": ["sodium", "sat_fat", "added_sugar", "cholesterol"],
  "basis": { "weight_kg": 72.1, "height_cm": 178, "age": 22, "sex": "male",
             "bmr": 1720, "active_kcal_avg14": 520, "tdee": 2400, "computed_at": 0 },
  "meal_split": { "breakfast": 0.25, "lunch": 0.35, "dinner": 0.3, "snack": 0.1 },
  "water_ml": 3000, "updated_at": 0 }
```

Auto mode works like this. BMR comes from Mifflin–St Jeor, using the latest weight, latest height and age from date of birth. TDEE is BMR plus the 14-day average of active energy, de-duplicated by source (one device per day, see `health_days` in "Server notes"). If active energy is missing, TDEE is BMR × 1.35. `maintain` keeps TDEE, `cut` uses TDEE − 20%, and `bulk` uses TDEE + 10%. Protein is 2.0 g/kg on a cut, otherwise 1.8 g/kg. Fat is 30% of kcal, carbs are the rest, and fiber is 14 g per 1000 kcal. Micronutrients use the FDA daily values, or the adult RDA for the profile's sex where that is more precise. `overrides` always win. The CLI can also set `mode: manual`. Never invent personal numbers: if health data is missing, keep the last basis or use the default 2,200 kcal and say why in `basis.note`.

### `health_days` (synced, server-written, read-only to the app)

`{ "id": "2026-11-08", "day": "2026-11-08", "weight_kg": 72.1, "active_kcal": 540, "basal_kcal": 1700, "steps": 9123, "exercise_min": 34, "updated_at": 0 }`. Fields are null when unknown. Keep 400 days.

### Not synced

- `catalog`: the USDA FoodData Central seed (Foundation, SR Legacy and FNDDS survey foods, which cover mixed dishes like "pizza, cheese, regular crust"). Nutrients are **per 100 g**, plus the USDA portions (`1 cup = 245 g`). Use FTS5 search over name and description. `food seed-usda` downloads and imports it, and is idempotent.
- `off_cache`: Open Food Facts lookups by barcode, with a User-Agent like `Plate/1.0 (self-hosted; <off_contact>)`. Negative results are cached for 1 day.
- `tokens`, `meta`.

## HTTP API (the app)

All routes except `/v1/ping` need the bearer token. Bodies are JSON. Errors are `{"error": "..."}` with a 4xx or 5xx status.

- `GET /v1/ping` returns `{"ok":true,"version":N}`.
- `GET /v1/meta` returns the nutrient list described above.
- `GET /v1/sync?since=V&wait=S` returns `{"version": N, "foods":[...], "entries":[...], "goals":[...], "health_days":[...]}` with every row whose `version > V`, tombstones included. `since=0` is a full snapshot. If there's nothing new and `wait>0`, the server holds the request up to `min(S,25)` seconds and answers as soon as something changes (use a condvar). This is how agent edits show up on the phone within a second.
- `POST /v1/mutations` takes `{"mutations":[{"table":"foods|entries|goals","op":"upsert|delete","row":{...}}]}` and returns `{"version":N,"applied":k}`. It's idempotent, and last writer wins by `updated_at`: a mutation older than the stored row is ignored. Recipe nutrients are recomputed on the server.
- `GET /v1/search?q=...&limit=25` merges the user's own foods (favorites and frequently logged first), the catalog and Open Food Facts text search (with a short timeout; skip it if that's slow), and returns `{"results":[Food]}`. Catalog and OFF results come back as Food objects with `id: null`, `source_ref` set, `serving` set to the first USDA portion or 100 g, and `portions` filled in. The client upserts one with a new id when it's logged, and the server dedupes foods by `source_ref`, returning the existing id.
- `GET /v1/barcode/{code}` returns `{"food": Food}` or a 404. It looks in the user's foods, then the OFF cache, then OFF. A food found this way is saved into `foods`, so it syncs and becomes a recent.
- `GET /v1/suggest?meal=lunch&day=...` returns `{"recents":[Food],"frequent":[Food],"yesterday":[Entry]}` for one-tap logging. Frequent is weighted by time of day.

## Sync on the phone

The phone keeps a local cache of every synced table in Codable JSON files in Application Support, plus a persisted outbox of mutations. Changes apply to the local cache immediately (optimistic), then flush to `/v1/mutations`. While the app is in the foreground it loops on `GET /v1/sync?since=<last>&wait=25`. It works offline and retries with backoff. The app never computes goals; it reads them.

## Health sync

By default the app reads a few daily Apple Health totals (weight, active and resting energy, steps, exercise minutes, plus height, birth date and sex) and sends them to the Plate server with `POST /v1/health_days` (`app/Sources/HealthDays`). That's all the adaptive goals need.

Optionally, the app also carries a full Health uploader from an earlier standalone Personal Health app, for people who run a separate health server. When `HealthSecrets.swift` is built in, the app uploads every Health type there instead (`POST /ingest`, raw-DEFLATE JSON, `kind = "hk"` batches and `kind = "diag"` breadcrumbs), and the Plate server pulls daily rows from it with `food health refresh`. The backends stay separate.

- **Code:** `app/Sources/HealthSync/` is that uploader (`HealthSync.swift`, `HealthPayload.swift`, `HealthTypes.swift`); its secrets enum is `HealthSecrets`. `Breadcrumbs` and `GalaReporter` are shared from `Sources/Support`. The launch path (send the previous run's breadcrumbs, then register observers and background delivery, then a full sync) is in `App.swift`; foreground syncs are in `RootView`. Demo mode skips all of it.
- **Entitlements:** `app/Plate.entitlements` (HealthKit), applied by the XcodeGen project; `PLATE_ENTITLEMENTS =` in `Local.xcconfig` builds without HealthKit. The `swiftc` device script produces an unsigned IPA, and the signing step applies the entitlements from its provisioning profile.
- **Persisted state, never rename:** UserDefaults `sent`, `lastSync`, `requested`, `lastDailySync` and `anchor.<HK type identifier>` (secure-archived `HKQueryAnchor`), plus `Library/Caches/breadcrumbs.txt`. Renaming any of them re-uploads the whole history. `Tests/health_state_test.py` checks them. Plate's own files live in `Application Support/Plate/`.
- **Secrets:** `app/HealthSecrets.swift` (`enum HealthSecrets { url, token }`, gitignored, mode 600), found by the same lookup as `Secrets.swift`, including `~/.config/plate/HealthSecrets.swift`. After issuing a new health token, update the file and rebuild the app.
- **Settings → Apple Health** shows the last upload, samples sent in the last run, the permission state, the daily sync, Sync now, and an Activity screen with this run's notes and breadcrumbs.

## CLI (agents)

Every command prints readable text by default and JSON with `--json`. Unless said otherwise, `--date` defaults to today in the server's time zone, and `--meal` defaults from the time of day (before 10:30 breakfast, before 15:00 lunch, before 21:00 dinner, otherwise snack).

```
food today [--date D] [--json]            # totals vs goals, per meal, micronutrient gaps
food log "name" [--kcal N --protein N --carbs N --fat N --fiber N ...] [--n key=val ...]
         [--meal M] [--date D] [--servings X] [--grams G] [--note T]
food log --food <id|source_ref> [--servings X | --grams G] [--meal M]
food log --catalog <fdc id or query> --grams G [--meal M]    # USDA per-100 g data, scaled by grams
food log --json [--json-out] < items.json # batch: [{name, grams?, servings?, nutrients?, catalog?, food?, meal?, note?}]
food entries [--date D | --from D --to D] [--json]
food edit <entry-id> [--servings X] [--grams G] [--meal M] [--date D] [--name T]
food rm <entry-id>...
food search "query" [--json]              # own foods, catalog, OFF
food barcode <code> [--json]
food food add --json < food.json          # custom food
food food list [--favorites] | food food fav <id> | food food rm <id>
food recipe add --json < recipe.json      # components by food id, source_ref, or catalog query plus grams
food goals [--json] | food goals set key=val... | food goals plan cut|maintain|bulk | food goals auto | food goals manual
food report [--days 7]                    # averages, adherence, weakest micronutrients, protein and kcal trends
food health-refresh                       # pull from `health query`, push health_days and profile, recompute goals
food health import [FILE] | food goals profile key=val...   # health data or body facts without a health server
food query "SELECT ..."                   # read-only SQL for anything else
food rotate-token [grace-hours] (= food token new) | food seed-usda | food serve
food init | food config | food export [FILE] | food import FILE   # setup, settings, backups
```

Agent edits get `source: "agent"`. They sync to the phone the same way app edits do.

The CLI documents itself, and its help is the agents' documentation: `food`, `food -h`, `food --help` and `food help` print an overview; `-h` or `--help` anywhere in a command's arguments, or `food help <command>`, print that command's usage, flags, examples and gotchas (the meal-photo workflow is in `food log --help`, also `food help photo`); `food help nutrients` lists the keys and units. Help never needs the service. The texts live in `server/src/help.rs`; keep them in step with behavior.

## AI logging (photo or text to a draft meal)

Snap a photo, or type "2 enchiladas and rice", and an LLM proposes a meal you confirm in one tap. The agent loop runs on **the server**, because that's where search, the catalog and logging live. The API key is entered in the app (or the CLI) and stored only in the server's database, which is encrypted. It's never returned to the app, never logged, and never stored on the phone. Design background: `docs/research/in-app-agent.md`. That doc assumed Anthropic's API; this build targets the **OpenAI-compatible Chat Completions API** (tools plus image input), so it works with OpenRouter (the default), OpenAI, local servers and anything else compatible.

### Config (stored in the encrypted database; key write-only)

- `GET /v1/agent/config` returns `{"base_url": "https://openrouter.ai/api/v1", "model": "", "has_key": false, "key_hint": "…1234", "auto_log": false, "max_jobs_per_day": 60, "system_prompt": null, "default_system_prompt": "…", "usage": {"today": {"jobs", "prompt_tokens", "completion_tokens", "cost"}, "month": {…}}}`. `cost` is in USD when the provider reports it (OpenRouter does, with `usage: {include: true}`), otherwise null. `system_prompt` is the user's custom prompt, or null when the built-in one is used; `default_system_prompt` is the built-in one (see "The agent").
- `PUT /v1/agent/config` takes any of `{"base_url", "model", "api_key", "auto_log", "max_jobs_per_day", "system_prompt"}`. An `api_key` of `""` clears it. A `system_prompt` string (at most 32 KB) sets it; null or `""` goes back to the built-in one. It returns the same shape as GET.
- `GET /v1/agent/models?q=` proxies the provider's `GET {base_url}/models`. For OpenRouter it filters to models whose `architecture.input_modalities` contains `image` and whose `supported_parameters` contains `tools`, and returns `{"models": [{"id", "name", "context_length", "prompt_price", "completion_price"}]}`, with prices per 1M tokens in USD (or null), sorted by name and filtered by `q`. For other providers it returns the ids unfiltered. It's cached for 1 hour.
- `POST /v1/agent/test` sends a tiny text completion with the current config and returns `{"ok": true, "model", "latency_ms"}` or an error: `401` becomes "API key is invalid", `402` "out of credit", `404` "unknown model".

### Jobs (async; the app long-polls)

```
POST   /v1/agent/jobs          {"image"?: "<base64 JPEG>", "text"?: "…", "barcodes"?: ["…"], "meal"?: "dinner", "date"?: "YYYY-MM-DD"}
                               -> 202 {"job": "uuid"}   (at least one of image or text is required; the image is at most 1.5 MB decoded)
GET    /v1/agent/jobs/ID?wait=25
                               -> {"status": "running|draft|logged|failed", "step": "Searching: rice white cooked",
                                   "draft": {"items": [batch items as for `food log --json`], "preview": [entries exactly as they would be logged],
                                             "summary": "Dinner: … about 640 kcal, 48 g protein"},
                                   "error"?: "…", "usage": {"prompt_tokens", "completion_tokens", "cost"}}
POST   /v1/agent/jobs/ID/confirm   {"items"?: [edited batch items]} -> {"entries": [...], "version": N}   (logs through the same path as `food log --json`)
DELETE /v1/agent/jobs/ID
```

- Jobs live in memory and expire after 1 hour. Images are never written to disk.
- At most 2 jobs run at once, with a daily cap of `max_jobs_per_day`.
- At most 6 model turns per job, a 90 s request timeout and a 3-minute job timeout.
- 429, 5xx and connection errors are retried twice with backoff.
- With `auto_log` on, a successful draft is confirmed automatically (status `logged`), and the app shows its usual undo toast.

### The agent

- **Request:** `POST {base_url}/chat/completions` with `model`, `messages`, `tools` (`type: "function"`) and `tool_choice: "auto"`. The user message's content parts are the text plus `{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,…"}}`. Headers: `Authorization: Bearer <key>`; for OpenRouter, also `HTTP-Referer` and `X-Title: Plate`. Include `"usage": {"include": true}`, which other providers ignore.
- **System prompt:** the custom `system_prompt` if one is set, else the built-in one: a short framing that lists the tools by the CLI command each one is, then the CLI's own help text (the `food log --help` photo workflow, the nutrient keys, `food search --help` and `food barcode --help`). Everything that changes per request always goes in the user turn, whatever the system prompt says: date and time, the default meal, what's left today, the note and any barcodes. The tool definitions are always sent.
- **Tools** are the food commands and nothing else (all read-only or dry-run; writes only happen on confirm; no SQL, no deletes, no health data beyond what goals show). Each tool's description starts with the command it mirrors ("Same as `food search`"):
  - `search_foods {query, limit?, include_off?}` = `food search`: own foods, the catalog, then OFF, as compact lines.
  - `lookup_barcode {code}` = `food barcode`, without saving the product.
  - `suggest {meal?}` = `food suggest`.
  - `get_today {date?}` = `food today`: totals vs targets, entries by meal, what's left, low nutrients.
  - `get_goals {}` = `food goals`: targets, limits, overrides and basis.
  - `propose_meal {items: [...], summary}` = `food log --json`, as a **dry run** of the batch log, in a transaction that is rolled back. It returns the matched names, sizes, nutrients and per-item errors, so the model can check its matches and propose again. The last successful proposal is the draft.
- **Prompt injection** (text on labels and menus): the tools can't write, delete, run SQL or read health data, and the user confirms the draft unless they turned on auto-log.

### CLI

`food agent config [--base-url U] [--model M] [--key-stdin] [--auto-log on|off] [--max-jobs N]`, `food agent models [query]`, `food agent test`, `food agent prompt [--default | --set < FILE | --reset]` (prints the effective system prompt, or the built-in one, or sets or resets the custom one), `food agent log [--photo PATH] [--text T] [--meal M] [--date D] [--yes]`. Without `--yes` it prints the draft and asks for confirmation; with it, it logs the draft. Each of these has full `--help`.

## Quality bar

- The Rust code stays small and plain: small modules, no frameworks beyond `tiny_http`, `rusqlite` (`bundled-sqlcipher-vendored-openssl`), `serde_json`, a small HTTP client (`ureq`) and `libc`. Add tests for sync, last-writer-wins, recipe math, serving scaling and goal math (`cargo test`).
- The app: no third-party packages. Use SwiftUI, Swift Charts, VisionKit `DataScannerViewController` for barcodes, and Liquid Glass (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, and so on). It must look stunning in light and dark mode.

## Server notes

What the server does beyond, or more precisely than, the contract above. All of it is additive; nothing above changed shape.

- **Sync rows** carry their `version`. If `since` is ahead of the server (a restored database), `/v1/sync` returns a full snapshot with `"reset": true`; the client should replace its cache.
- **`POST /v1/mutations`** also returns `"ids": {"<sent id>": "<stored id>"}` and `"errors": [{"index", "error"}]`. A bad mutation is skipped and reported, not fatal, so one broken row can't wedge the outbox. When a new food repeats a live food's `source_ref`, the server keeps the existing food, returns its id in `ids`, writes a tombstone for the sent id (with `merged_into`) so the client drops it, and points entries at the existing food (now and in later writes). Retrying that creation (same id, `updated_at` no newer than the alias tombstone's, as when the reply was lost) is a no-op that still returns the id mapping, so it can't overwrite the existing food. A genuinely newer write through the alias applies to the existing food as an edit: it keeps that food's `created_at` and `source_ref`. An exact repeat of the stored row is a no-op and doesn't bump the version.
- **Rows a mutation can't write** get a per-mutation error, so one bad row can't poison other clients: a row that isn't an object or is over 256 KB of JSON; `updated_at`, `created_at` or `logged_at` that isn't whole ms from 2020-01-01 to a day past the server's clock (`0` or null means unknown for `created_at` and `logged_at`, which then default to `updated_at`); `deleted` that isn't a boolean; a food `kind` other than `food`, `recipe` or `quick`; and any of `servings`, `grams`, `serving.amount`, `serving.grams`, portion `grams`, `recipe_servings`, component `servings` and `grams`, `water_ml` and `meal_split` values that isn't a number from 0 to 1e9. Nutrient values outside 0 to 1e9 are dropped like any other non-number (unknown stays unknown). An entry `day` that isn't a real `YYYY-MM-DD` date in 2000 to 2100 is replaced by the day of `logged_at`. CLI writes with an out-of-range timestamp use the server's clock instead of failing.
- **Recipes with a deleted ingredient** still compute and still take writes: the deleted component stays in `components` but is left out of the math, and the recipe carries `"partial": true` and `"missing_food_ids": [...]` (both absent when every ingredient is live). Deleting a food recomputes the live recipes that use it, and recipes that use those, keeping their `updated_at` (like the goals recompute), so clients see a new version but a newer client edit still wins; a deleted food coming back heals them the same way. A component without a `food_id`, a recipe that contains itself, a `components` that isn't a list, and grams for a food with no gram weight are still errors.
- **Goals written by a client:** the server keeps its own `basis` and recomputes `targets` from `mode`, `plan` and `overrides`. Server recomputes after a Health refresh don't change `updated_at`, so they never make a client's newer edit lose. `targets` holds every nutrient that has a target, including `water` (from `water_ml`) and the micronutrients. `sat_fat` and `added_sugar` limits are 10% of kcal each (the basis of their DVs). If kcal is overridden in auto mode, the macros follow the overridden kcal. Magnesium uses the 19-30 RDA (400 mg men, 310 mg women) below 31. `basis` also has `weight_day`, `active_days` and `note`. The 14-day active-energy window ends the day before the newest day with Watch active energy (that day is usually cut off by the phone's once-a-day Health sync); it needs 5 days of data, otherwise TDEE is BMR x 1.35.
- **`health_days`** from `food health refresh` pick one source per day for active and basal energy, steps and exercise (the owner's Watch, then any Watch, then an iPhone, then other apps; other people's devices are skipped), and the day's last weighing for weight. The owner is `health_owner`, else the possessive name ("X’s Apple Watch") with the most Watch days. Only changed days get a new version.
- **`GET /v1/search`** takes `off=0` to skip Open Food Facts (otherwise a 1.5 s budget, via search.openfoodfacts.org). OFF fills whatever room is left, and keeps a fifth of `limit` even when USDA fills it. The user's foods carry `times_logged`; catalog results also carry `category` and `dataset` (`foundation`, `sr_legacy`, `survey`). Catalog search takes the foods matching every word (a cooking word such as "grilled" also matches its near-synonyms like "broiled" or "roasted", and may be left out when nothing has it), else every word with the last as a prefix, else any word, and dedupes repeated names. It then ranks them so the plainest name wins: each query word missing from the name costs a lot, and each extra word costs by kind (sauces, "with ...", brands, fast food, baby food, canned, dry mixes and dishes like salad or sandwich a lot; plain describers like "raw", "enriched", "without salt" or "no added fat" very little; a query word negated, as in "Pizza, no cheese", a lot). Extra words in the first comma segment ("Rice crackers") and a first word the query didn't name ("Pepper, banana, raw") cost more, each comma segment a little, and survey (FNDDS) foods a little more than Foundation and SR Legacy, so "banana raw" is SR Legacy's "Bananas, raw" while a dish only the survey has still wins there.
- **`GET /v1/barcode/{code}`** answers 400 for anything but 6 to 14 digits and 502 when OFF can't be reached (not cached). Barcodes match with leading zeros ignored, so UPC-A and EAN-13 forms find the same food. OFF foods: one serving is OFF's `serving_quantity` when it has one, else 100 g.
- **`GET /v1/suggest`** also returns the `meal` it used. Frequent foods are scored over 90 days by same meal (0.6) plus closeness to the current time of day (0.4), halving every 30 days.
- **`GET /v1/meta`** also has a `limit` flag per nutrient, `meals`, `groups` and `timezone`.
- **CLI logging:** nutrient flags are per serving and multiplied by `--servings` (default 1). An item logged by name is also saved as a food with `source: "agent"` and `source_ref: "agent:<name-slug>"` (kind `quick` if it only has kcal and macros), so the app can log it again in one tap; logging that name again updates it. Entry ids can be given as a unique prefix of 4+ characters. `food log` prints one line per entry (id prefix, the matched name, size, kcal and protein, then the `source_ref` and, for a catalog item, the query it was matched from) and the day's kcal and protein against target, for a batch too; `--json-out` (or `--json` on a single-item log) prints the full reply instead: every entry and the whole day. A flag a command doesn't take is an error, and usage errors point at that command's `--help`. Extras beyond the list above: `food suggest [--meal M]`, `food search --limit N --no-off`, `food log --brand B`, `food edit --note T` and nutrient flags on `food edit`, `food food fav <id> --off`.
- **HTTP limits:** the server speaks HTTP/1.1 itself and answers one request per connection (`Connection: close`). It serves at most 64 connections at once; past that a connection gets `503` with `{"error"}` (retry later). The request line, headers and body must all arrive within 15 s of connecting, or the reply is `408`; a reply that can't be written in 30 s is dropped. A body over 2 MB (by `Content-Length` or chunked; 3 MB for `POST /v1/agent/jobs`) is `413`, so keep a mutation batch under 2 MB. At most 32 long-polls wait at once; a `/v1/sync?wait=` past that answers straight away, with whatever changed (possibly nothing), and the client just polls again. The Unix socket serves at most 16 connections at once and otherwise replies `{"ok": false, "error": "the food service is busy; try again"}`.
- **`food report`** averages each nutrient over the logged days that have data for it (a day whose entries never mention iron isn't a zero), and returns `coverage: {key: days}` beside `averages`; the CLI prints, for example, `iron 7.9 mg avg, 44% (4 of 7 days)`. `weakest` and `over_limits` only count a nutrient known on at least half the logged days, and carry `days`. The kcal and protein trends average the days with data in each half.
- **`food query`** returns at most 10,000 rows (or about 16 MB of values) and then says `"truncated": true` in the socket reply (the CLI prints a note on stderr); no single string or blob may pass 16 MB, and a query still running after 5 s is interrupted with an error.
- **USDA seed:** the 2026-10-29 Foundation CSV release on fdc.nal.usda.gov has no `food.csv` or `food_nutrient.csv`, so `food seed-usda` tries each release newest first and uses the first complete one (now Foundation 2026-04-30, SR Legacy 2018-04, FNDDS 2024-10-31: 13,602 foods). The download runs as the CLI's user into `cache_dir` (`~/.cache/plate`), and the parsed rows are streamed to the service over the socket. Energy falls back to the Atwater values for Foundation foods; omega-3 is ALA + EPA + DHA + DPA; vitamin D falls back to IU / 40. Values are USDA's own; a few FNDDS foods list 0 where SR Legacy has a value (for example the survey "Banana, raw" has 0 iron).
- **Configuration** (`server/src/config.rs`, documented in `server/README.md` and `food config --help`): a `key = value` file, the first of `$FOOD_CONFIG`, `$XDG_CONFIG_HOME/plate/config.toml` or `~/.config/plate/config.toml`, and `/etc/plate/config.toml`; a `FOOD_<KEY>` environment variable wins over the file. Keys and defaults: `data_dir` (`~/.local/share/plate`; with only `FOOD_DB` set, its directory), `database` (`FOOD_DB`, `<data_dir>/food.db`), `listen` (`127.0.0.1:18792`), `socket` (`$XDG_RUNTIME_DIR/plate/food.sock`, else `/run/user/<uid>/plate/food.sock`, else `<data_dir>/food.sock`, as on macOS), `socket_uids` (extra uids or user names; `FOOD_READER_UID` is added to it; the service's own uid and root are always answered), `timezone` (IANA name, else the system zone from `$TZ` or `/etc/localtime`), `encryption`, `key_file` (`<data_dir>/food.key`), `credential` (`food-key`), `cache_dir` (`~/.cache/plate`), `off_contact` (the Open Food Facts and USDA User-Agent is `Plate/1.0 (self-hosted; <contact>)`, or `Plate/1.0 (Plate self-hosted)` without one), `health_command` (`health`, preferring `/usr/local/bin/health`) and `health_owner`. An unknown key or a relative path is an error. `food config [--json]` prints the effective values and asks the service for its zone and version.
- **Encryption modes:** `keyfile` (SQLCipher, a key file of 64 hex digits; refused if its group or other permission bits are set), `systemd-credential` (`$CREDENTIALS_DIRECTORY/<credential>`, the hardened mode), `none` (plain SQLite), and `auto`, the default: the credential if present, else the key file if it exists, else (only with `FOOD_ALLOW_PLAINTEXT`) plain; otherwise `food serve` refuses to start. A key can't open a plain file and vice versa; the error says which. Only `food serve` reads the key.
- **Time zone:** days, "today", reports, meal defaults, the 400-day health window and `/v1/meta`'s `timezone` use the configured zone. Zones come from the system's TZif files (with the POSIX rule in the footer past the last transition), or a POSIX TZ string; no tz crate. The CLI sends `today`, `yesterday` and `-N` to the service, which resolves them in its zone. `food serve` fails on a configured zone it can't load; with no setting and no system zone it uses UTC with a warning.
- **`food init`** writes the config (mode 600), the data dir (700) and, unless `--encryption none`, a random key file (600), then prints the next steps. It keeps an existing config (`--force` rewrites it) and never replaces a key; it refuses to make a key when a database already exists without one. `food token new [grace-hours]` is `food rotate-token`.
- **Health without a health server:** `food health import [FILE|-] [--format json|csv] [--birth-date D] [--sex S] [--height-cm N]` reads daily rows (`day` or `date`, `weight_kg` or `weight_lb`, `active_kcal`, `basal_kcal`, `steps`, `exercise_min`; a few other spellings) from CSV, or JSON as a list or `{"days": [...], "profile": {...}}`, and sends them in batches of 500. `food goals profile weight=172lb height=70in age=34 sex=female activity=light` sets body facts by hand (`key=none` clears one; a weight is stamped with today as `weight_day`, an age with `age_on` and counts up from it). The profile is now merged, not replaced: a key with a value sets it, null clears it, and values are checked (dob a date, sex male or female, height 50-272 cm, weight 20-450 kg, age 14-110, activity_factor 1.0-2.5); a bad value from a push is skipped and listed in `profile_ignored`, from `food goals profile` it's an error. Days outside the last 400 or more than a day ahead, or without a valid date, are skipped (`days_skipped`). The basis takes the newest weighing of the profile's and the health days', age from `dob` else `age`, and without 5 days of active energy TDEE is BMR x `activity_factor` (default 1.35). With facts missing, the note says to use `food goals profile` or a health import.
- **`POST /v1/health_days`** (bearer token) takes `{"days": [{"day", "weight_kg", "active_kcal", "basal_kcal", "steps", "exercise_min"}], "profile": {"dob" or "birth_date", "sex", "height_cm", "weight_kg", "weight_day", "activity_factor"}}`, at most 1,000 days, and returns `{"days_written", "days_skipped", "days_pruned", "profile_ignored", "goals"}`. It's the same path as the CLI's import and refresh, so a day pushed twice doesn't get a new version. The app can use it to send Apple Health days directly when there's no separate health server; `health_days` stay read-only through `/v1/mutations`.
- **AI logging** (`server/src/agent.rs`, `llm.rs`), beyond the contract:
  - The API key lives in a `secrets` table in the same encrypted database, not in `meta` (the other settings are in meta `agent`), so that `food query` can be refused reads of it (an SQLite authorizer); it's never exported. The spend ledger is the `agent_usage` table (per local day; `cost` NULL until a provider reports one). A job counts against `max_jobs_per_day` when it starts, failed or not; `POST /v1/agent/test` adds its tokens but isn't a job.
  - Status codes: `400` for a bad request or missing key or model (the message says which), `413` for an image over 1.5 MB, `400` for one that isn't a JPEG, `429` when 2 jobs already run or the daily cap is reached, `404` for an unknown or expired job, `409` for confirming a job that is still running or failed. A provider's failure on `/v1/agent/test` and `/v1/agent/models` is `502` with the mapped message, never `401`, which the app would read as its own token. `POST /v1/agent/jobs` takes a body of up to 3 MB (every other route stays at 2 MB).
  - `GET /v1/agent/jobs/ID?wait=S` answers as soon as anything visible changes (a new `step`, the draft, the end), so the app can show progress; poll again until the status isn't `running`. It shares the 32 long-poll slots with `/v1/sync`. The reply also has `job`, `meal` and `date` (the defaults the job fills in), `created_at`, and once logged `entries` and `version` (for the undo toast). `draft` is null while running.
  - Items are normalized before the dry run: unknown fields are an error, exactly one of `catalog`, `food` or `name`, `grams` up to 5,000 and `servings` up to 100, `nutrients` only on name items and only known keys, and a proposed entry over 5,000 kcal is refused. Items without `meal`, `date` or `note` get the job's (the request's meal, else the meal by the clock when the job started; its date, else that day; its text, else "from photo"), so the preview and the logged entries match exactly (apart from ids and timestamps). Edited items on confirm get the same checks.
  - Confirm returns `{"entries", "version", "today"}`. Confirming a logged job again without items returns what it logged, without logging twice (a retry after a lost reply). With `auto_log`, a failed automatic confirm leaves the job as a `draft` with `error` set, so it can still be confirmed by hand. `DELETE` returns `{"deleted": true}`; a running job stops at its next step.
  - Requests: `usage: {include: true}`, `HTTP-Referer` and `X-Title` are sent to OpenRouter only (strict servers reject unknown fields); `max_tokens` is 8,000 (`max_completion_tokens` for api.openai.com). Assistant `tool_calls` (and OpenRouter's `reasoning_details`) are sent back as given, with one `role: tool` message per call. A model that answers without proposing gets one nudge. A provider error after a successful proposal still ends in the draft. Retries back off 1 s then 3 s, honoring `Retry-After` up to 30 s, within the 3-minute job deadline. `lookup_barcode` caches an Open Food Facts lookup (the cache isn't synced) but saves no food, so the database's synced rows and version don't change until confirm.
  - Errors: 401 "API key is invalid"; 402 "out of credit"; 404 or a "model not found / not a valid model" message, "unknown model"; "no endpoints found that support …", that the model can't take images or tools; moderation, flagged or content-filter replies (and `finish_reason: content_filter`), a content-filter message; a `refusal`, "the model declined: …". The key is scrubbed from every message, and the service log has one line per job (outcome, time, tokens, cost, model), never the key, the photo or the note.
  - `GET /v1/agent/models` also returns `base_url`. Model lists are cached per base URL for an hour.
- **`food export [FILE|-]` and `food import FILE|-`:** a JSON backup (`"format": "plate-export"`, `format_version` 1) of every synced row with tombstones, the food aliases and the profile, written mode 600. It goes through the socket, so it works with a TPM-sealed key. Import restores a row only if the database has no copy with the same or newer `updated_at` (each restored row gets a new version, so phones pick it up), adds missing aliases, sets the profile only when the stored one is empty, then recomputes the goals. The catalog and OFF cache aren't included.
- **Deploy files:** `server/deploy/plate.service` (systemd user unit) and `server/deploy/plate.plist` (launchd) run `food serve` as the user. `server/deploy/hardened/` is the dedicated-user, TPM-sealed setup; its `install.sh` takes `READER` (default `$SUDO_USER`), `SERVICE_USER`, `DATA`, `REQUIRE_MOUNT`, `TAILSCALE_PORT` and `HEALTH_TIMER` from the environment (the defaults at the top of the script are one machine's; set your own), and fills them into the `personal-food.service` template.
