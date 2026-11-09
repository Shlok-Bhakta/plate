# In-app food-logging agent: decision doc

2026-11-09. Research only; nothing is built. Prices and model facts come from Anthropic's model documentation
(model table as of 2026-10-06) and the live pricing and vision pages, both checked today.

## Decision

**Build option A: a server-side agent endpoint in `food`.** The app sends a photo and/or text to
the Plate server. `food serve` runs a Claude Messages API tool loop, with tools that are thin wrappers
over `service.rs`, and returns a draft meal that one tap confirms. The API key never leaves the
server. Start on **Claude Opus 5.5** (`claude-opus-5-5`, effort `medium`), about **8-10 cents a
photo, roughly $15 a month** at 6 photos a day. In week one, replay past photos against Sonnet 5.5
and Haiku 5.5, and move down a tier if the estimates hold up.

Why A: the agent reuses the exact functions and help text the CLI agent uses, so behavior stays
the same. The only external contract is `POST /v1/messages` with `anthropic-version: 2023-06-01`,
which has stayed unchanged since 2023 while new features arrived as additive fields. The server
already has `ureq` and outbound network for Open Food Facts. There's no SDK, no Node runtime, and
no chat client to keep up to date.

## Options compared

| | A. Server endpoint | B. On-device API | C. Embed a coding-agent client | D. Share to an agent app | E. Apple Foundation Models |
|---|---|---|---|---|---|
| Maintenance | Low: one model-ID string, about 600 lines of Rust | Medium: agent logic in Swift and help text duplicated | High: follows a fast-moving client protocol and CLI | None in Plate; the agent app owns it | Medium: a second, weaker logging path |
| Cost per photo | 8-10 cents (Opus 5.5) | Same | Same tokens plus the client's large harness prompt | Same as today | Free |
| Latency | 10-25 s | Similar, plus a phone-to-server trip per tool call | Slower (harness overhead) | Switching apps plus the agent's run | 1-3 s, text only |
| Reliability | Good: bounded loop, retries | Each tool call crosses the tailnet from the phone | Breaks when upstream changes | Good | Good offline |
| Key security | Key in a systemd credential on the server | Org API key on the phone | Server-side, but the agent has bash | N/A | N/A |
| UX | Native: camera to draft to confirm | Native | Chat UI inside Plate | Leaves the app | Native, but can't read photos |

**B (on-device direct API).** It works, but the agent ends up written twice: the tool schemas
and the `food log --help` workflow would live in Swift, the CLI help in Rust, and they'd drift
apart. Every tool call goes from the phone to the server over the network. The key sits on the phone. The
Keychain is fine against casual access, but this is an org-wide, spend-capable key, and rotating
it means a new build or a settings field. Its only advantage over A is that the server doesn't
need changes, and A's server change is small. Reject.

**C (embed a general coding-agent client).** Such clients and their protocols release often, and
Plate would need to track them. It also gives a general coding agent with `bash` the job of
reading untrusted images (food labels, menus), which is the worst place for prompt injection.
The Claude Agent SDK on the server has the same problem: a Node/Python runtime to keep updated, a
large harness prompt on every call, and bash. Reject.

**D (hand-off via share sheet).** It needs almost no code: a share button on a photo that opens
the iOS share sheet, where the user picks whatever agent app already drives their `food` CLI (if
it accepts shared images through a share extension or URL scheme). Entries still show up in Plate within a second through sync. Worth keeping as the fallback
when A is down, but it fails the main goal of staying in the app.

**E (Apple Foundation Models, iOS 26).** The on-device model is about 3B parameters with a
roughly 4K-token context window. It has guided generation (`@Generable`) and tool calling, and
needs an Apple Intelligence device with Apple Intelligence on. As far as I know, the iOS 26 public
API takes text, not images; verify against the current SDK. Apple positions it for summarizing,
extraction and classification, not world knowledge. Nutrient values and portion sizes are world
knowledge, and portions need vision, so it can't replace Claude for photos. It could parse "2 eggs
and toast" into `[{food: "egg", qty: 2}, {food: "toast", qty: 1, unit: "slice"}]` offline, with
the server's catalog and USDA portions supplying the numbers. That's a second path to maintain
when the same text costs Claude 1-3 cents. Not now; revisit only if offline logging matters.

**Also considered: Managed Agents.** Anthropic would run the loop, but the tools must reach
the Plate server, which is usually on a private network. So the server would still execute every tool, and the agent would
depend on a beta product. Not worth it.

## Design (option A)

### Endpoints (all need the bearer token, like the rest of `/v1`)

```
POST /v1/agent/jobs     {"image": "<base64 JPEG>"?, "text": "2 enchiladas and rice"?,
                         "barcodes": ["0049000028911"]?, "meal"?: "dinner", "date"?: "2026-11-09"}
                        -> 202 {"job": "uuid"}
GET  /v1/agent/jobs/ID?wait=25
                        -> {"status": "running|draft|logged|failed", "step": "Searching: rice white cooked",
                            "draft": {"items": [...batch items...], "preview": [...entries...],
                                      "summary": "Dinner: ... about 640 kcal, 48 g protein"},
                            "error"?: "...", "usage": {...}}
POST /v1/agent/jobs/ID/confirm   {"items"?: [...edited items...]}  -> service::log, returns logged entries
POST /v1/agent/jobs/ID/reply     {"text": "the rice was brown"}     -> continues the same loop (v1.1)
DELETE /v1/agent/jobs/ID
```

The job is asynchronous, so a 20-second agent run doesn't fight the app's 40 s URLSession timeout
or iOS suspending the app. The long-poll works like `/v1/sync?wait=` and uses the same condvar
pattern. Jobs live in memory, keyed by id, and expire after an hour. Images are never written to
disk and are dropped when the job ends. A 1024 px JPEG is about 150-300 KB, or about 400 KB as
base64, well under the server's 2 MB body limit and its 15 s request deadline. One job thread
calls the API with blocking `ureq`. Cap concurrent jobs with a `Gate` (say 2) so they can't starve
the 64-connection limit.

### Tools (server-executed; none writes)

Every tool is read-only, or a dry run. Writes happen only on `confirm`, through the same
`service::log` the CLI uses. Define the tools with `strict: true` and `additionalProperties: false`,
and validate their inputs again on the server.

| Tool | Input schema (brief) | Backed by |
|---|---|---|
| `search_foods` | `{query: string, limit?: int 1-10, include_off?: bool}` | `service::search` (the user's foods, USDA, OFF), returned as compact text lines like `food search` prints |
| `lookup_barcode` | `{code: string, pattern ^\d{6,14}$}` | `service::barcode` (saving the OFF product is a harmless side effect) |
| `suggest` | `{meal?: enum}` | `service::suggest` ("the usual", recents, yesterday's meal) |
| `propose_meal` | `{items: [{catalog? \| food? \| name?, grams?, servings?, nutrients?: {kcal, protein, ...}, meal?, date?, note?, brand?}] (max 20), summary: string}` | **dry run** of `service::log` |

`propose_meal` is how the agent covers steps 5 and 6 of the CLI workflow (log, then check). Add
`State::dry_run(work)` beside `State::write`: it runs the same closure in a transaction and drops
the transaction instead of committing it. That returns exactly what `service::log` would produce,
including matched names, grams, nutrients and per-item errors ("item 3: ..."), with no duplicated
resolution code. The global version counter lives in the database, so it rolls back too. The model
checks the matched names against the plate and calls `propose_meal` again with the full corrected
list. The last successful proposal becomes the draft. On confirm, the server re-runs
`service::log` on those items, or on the user's edited items.

Tell the app which barcodes it sees: it runs Vision's `VNDetectBarcodesRequest` on the photo and
sends the digits. That's more reliable than having the model read digits off the image.

### System prompt: reuse the CLI agent's words

The server builds the system prompt at startup from constants already in the binary: a short
framing paragraph, then `help::LOG` verbatim (the meal-photo workflow), the nutrient keys from
`help::nutrients()`, and the notes from `help::SEARCH` and `help::BARCODE`. The framing maps the
CLI to the tools: "`food search` is `search_foods`; `food log --json` is `propose_meal` (a dry run;
the user confirms); instead of `food rm`/`food edit`, propose the full corrected list again; end with the
one-line reply from step 7." When `help.rs` changes, the in-app agent changes with it.

Everything that changes per request goes in the user turn, after the cache breakpoint: today's
date and time in the server's time zone, the default meal, what's left today (from `day_summary`),
and the user's note. Nothing volatile goes in `system`, so caching keeps working.

### Request shape

`POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`,
`content-type: application/json`:

- `model` from config (default `claude-opus-5-5`); `max_tokens: 8000`; no streaming, since the
  requests are short.
- `thinking: {type: "adaptive"}` (it can't be turned off on Opus 5.5) and
  `output_config: {effort: "medium"}`, set explicitly. Try `low` in the eval.
- `tool_choice: {type: "auto"}`. Forced `any`/`tool` returns 400 on Opus 5.5 and Sonnet 5.5, so
  steer with the prompt instead.
- Image block: `{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": ...}}`,
  placed before the text.
- Caching: an explicit `cache_control: {type: "ephemeral"}` on the last system block (tools and
  system together are about 3,200 tokens, above the 512-token minimum), plus top-level automatic
  caching so loop turns 2+ read the image and earlier turns from cache. Use the 5-minute TTL:
  meals are hours apart, so a 1-hour TTL never gets reused, while loop turns are seconds apart.
  Check `usage.cache_read_input_tokens` > 0 on turn 2.
- Refusals: check `stop_reason` before reading `content`; `refusal` fails the job with a clear
  message. Optionally add `fallbacks: "default"` with the `anthropic-beta:
  server-side-fallback-2026-07-01` header. It's a beta, so drop it if it ever causes trouble.
- Keep the loop append-only: send each assistant `content` back unchanged, thinking blocks
  included, and never edit earlier turns.

### Loop limits, errors, retries

- At most 6 API turns per job, and at most 20 items. Return tool errors as `tool_result` with
  `is_error: true` rather than failing the job.
- Use a 120 s timeout per API request and 3 minutes per job.
- Retry 429, 500, 529 (overloaded) and connection errors twice with backoff, honoring
  `retry-after`. Never retry other 4xx errors. Show 401 as "API key is invalid" and 402 as "API
  credit is exhausted".
- If no `propose_meal` succeeds, the job fails with the model's last text, so the user can retype
  or use the share-sheet fallback.

### App UX

- A "Snap or describe" entry in the Add sheet: camera or photo picker plus a text field. Resize
  on the device to a 1024 px long edge, JPEG quality 0.8. Re-encoding drops EXIF and GPS.
- While it runs, show a sheet with the `step` text ("Searching: chicken breast roasted").
- The draft appears as entry rows (the same row view as Today) with a total. The user can tap a row
  to adjust grams, then press **Log** once. That's two steps in all (snap, then Log), within the
  prime directive.
- Afterwards, show the existing undo toast (`Toast.swift`), listing the entries it created.
- Add a Settings toggle, "Log photos immediately", for later, once the user trusts it: confirm runs
  automatically, and undo stays.

## Cost per meal

Token estimate for a typical photo. A 1024x768 image is `ceil(1024/28) x ceil(768/28)` = 37 x 28 =
**1,036 visual tokens**.

| Part | Tokens |
|---|---|
| System prompt (framing 400, LOG help 1,300, nutrient keys 500, search/barcode notes 300) | ~2,500 |
| Tool definitions (4 tools) | ~700 |
| User turn: image plus date, meal, what's left, note | ~1,350 |
| Turn 1 out: thinking plus 3-4 parallel `search_foods` calls; results ~1,500 back | |
| Turn 2 out: `propose_meal`; preview ~800 back | |
| Turn 3 out: check and summary line | |
| **Totals over 3 requests** | about 7,600 cache-write, 10,700 cache-read, ~2,000 output (3,000 on Fable) |

| Model | In / 5m write / read / out ($ per MTok) | Per photo | +25% buffer | Month (180 photos) | $100 buys |
|---|---|---|---|---|---|
| Haiku 5.5 `claude-haiku-5-5` | 0.10 / 0.125 / 0.01 / 0.50 | $0.002 | $0.003 | ~$0.50 | 30,000+ photos |
| Sonnet 5.5 `claude-sonnet-5-5` (best value) | 2 / 2.50 / 0.10 / 10 | $0.040 | $0.05 | ~$9 | ~2,000 photos, ~11 months |
| **Opus 5.5 `claude-opus-5-5` (recommended)** | 4 / 5 / 0.20 / 20 | $0.080 | $0.10 | ~$18 | ~1,000 photos, ~5.5 months |
| Fable 5.1 `claude-fable-5-1` (top model) | 10 / 12.50 / 0.25 / 50 | $0.25 | $0.31 | ~$56 | ~320 photos, ~2 months |

The buffer covers a correction turn, longer thinking, and the odd retry. A text-only log ("2
enchiladas and rice") costs about a cent less. Output tokens, mostly thinking, are about half of
Opus's cost, which is why effort `low` is the first thing to test. Fable 5.1 also needs the org
to have 30-day data retention (it isn't available under zero data retention), and it runs long
turns; it's overkill here.

**API billing.** Claude subscription plans and API billing are separate. API credit, if any,
shows in the Claude Console (platform.claude.com) under Settings > Billing as a credit balance or
grant. Create an API key in a dedicated "Plate" workspace; don't reuse a personal assistant's or
coding agent's login for a server service.

## Latency (estimates; measure in the eval)

Upload over Tailscale takes under 1 s. Each Opus 5.5 turn at effort `medium` with the image takes
roughly 4-10 s, so 3 turns come to about **10-25 s** from snap to draft. Sonnet 5.5 should be
somewhat faster and Haiku 5.5 about 3-8 s in total. `search_foods` is local SQLite, plus OFF's
1.5 s budget; set `include_off: false` unless the item is branded. Effort `low` cuts thinking
time. Because the job is asynchronous, the user can leave the sheet and come back to the draft.

## Maintenance, and why it's stable

- **Contract:** one HTTP endpoint and one version header, `2023-06-01`, which is still current.
  New features are optional fields and beta headers. No SDK to upgrade; `ureq` is already a
  dependency.
- **Model IDs** are the one thing that ages: models are retired on a published schedule. Keep the
  ID in a config file next to the key, so changing it needs a restart, not a rebuild. Surface
  404/400 "model" errors in Settings, not just as a failed job.
- **Behavior** follows `help.rs` automatically. A new server capability is a new tool wrapping a
  `service.rs` function.
- **Size:** about 600 lines of Rust (API client and loop ~250, tools ~150, jobs and endpoints ~200)
  plus tests replaying recorded API responses, and about 400 lines of Swift (capture, job polling,
  draft sheet), reusing the entry rows and Toast.
- **Eval before choosing the model for good:** collect past meal photos together with what was
  actually logged for each (for example from an existing CLI agent's history). Replay 20 of
  them through Haiku 5.5, Sonnet 5.5 and Opus 5.5, comparing kcal and protein and how often the
  wrong catalog item gets matched. That's about $3 in total.

## Risks

1. **Cost runaway** (a loop bug, a retry storm, a leaked key). Use a dedicated Console workspace
   with a monthly spend limit (say $25) as the final backstop. On the server: at most 6 turns and
   3 minutes per job, 2 concurrent jobs, 40 jobs a day, and `max_tokens` per request. Log each
   job's `usage` to a non-synced table and show month-to-date spend in Settings. Store the key as
   a systemd credential (`systemd-creds encrypt --name=anthropic-key`, loaded with
   `LoadCredentialEncrypted=`, read from `$CREDENTIALS_DIRECTORY`), the same pattern as
   `food-key`, and never put it in the app.
2. **Prompt injection via photos** (menus, packaging, labels: "ignore previous instructions...").
   The tool scope is the main defense. There's no bash, no SQL, no health data, no deletes and no
   writes: the agent can only search foods and propose a meal, which the user sees before anything
   is logged. Inputs are validated on the server (barcode digits, item and amount limits, the
   existing 0-1e9 nutrient checks, plus a sanity cap such as 5,000 kcal per item). The only
   outbound channel is the OFF search text, which `include_off: false` closes. The worst case is
   a bad draft, and in auto-log mode, bad entries the user can undo. Keep operator instructions in
   `system`, never in the user turn.
3. **Privacy.** Meal photos and the user's notes go to Anthropic. Re-encoding on the phone
   strips EXIF/GPS, and the server keeps no copy. The model docs mention retention only for Fable 5.1 (30-day
   retention required). For the general API data-retention and training policy, check Anthropic's
   current commercial terms and privacy center before shipping; don't assume zero retention.
4. Smaller ones: model-ID retirement (it's a config value), an API outage (the share-sheet
   fallback still works), and refusals (`stop_reason: "refusal"`; Haiku 5.5 has no server-side
   fallback).
