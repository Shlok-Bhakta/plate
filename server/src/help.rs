//! `food --help`, `food <command> --help` and `food help <topic>`: the documentation agents read.
//! Plain text, never touching the socket, so help works without the service.

use crate::nutrients;

pub const OVERVIEW: &str = r#"food: Plate, a self-hosted food log. The iPhone app shows it; you (an agent or a script) do
most of the logging, usually from a meal photo. Every write reaches the user's phone within a
second.

Commands
  today           the day so far: totals vs targets, entries by meal (with ids), low nutrients
  log             log food: from the USDA catalog, a saved food, by name with nutrients, or a batch
  entries         list entries for a day or a range of days
  edit            change an entry's amount, meal, date, name, note or nutrients
  rm              delete entries
  search          find foods: the user's own, then the USDA catalog, then Open Food Facts
  barcode         look up a barcode and save the product as a food
  suggest         what the user usually has for a meal, and yesterday's same meal
  food            saved foods: add (or update), list, fav, rm
  recipe          add or edit a recipe built from ingredients
  goals           targets, plan (cut, maintain, bulk), overrides, body profile, auto or manual
  report          averages, adherence, weakest nutrients and trends over N days
  agent           AI logging for the app's photos: provider, model, key, prompt, spend (admin)
  query           read-only SQL over the database
  health          import daily weight and activity (CSV or JSON), or refresh from a health server
  token           print a new app token (admin; `food rotate-token` is the same)
  export          back up everything that syncs as one JSON file (admin)
  import          restore a backup made by `food export` (admin)
  seed-usda       download and import the USDA catalog (admin)
  init            first-time setup: config file, data directory, database key (admin)
  config          show the effective settings and whether the service answers (admin)
  serve           the service itself (admin)

Conventions
  Dates      --date YYYY-MM-DD, today, yesterday or -N (N days ago), as days in the service's
             time zone (`food config` shows it).
  Meals      --meal breakfast|lunch|dinner|snack. Omitted, it follows the clock: before 10:30
             breakfast, before 15:00 lunch, before 21:00 dinner, else snack. When the user says
             when they ate, pass --meal and --date.
  Output     readable text. --json prints the full JSON reply instead, except on `food log`,
             where --json means the items come on stdin; there, --json-out prints the reply.
  Ids        entries and foods have UUIDs. The 8 characters printed are enough (any unique
             prefix of 4 or more works).
  Nutrients  flags are the nutrient keys: --kcal 450 --protein 30, or --n key=value for any key.
             A missing nutrient means unknown, which is not zero. Keys: `food help nutrients`.

Topics: `food help nutrients` (every key and unit), `food help photo` (= food log --help).
Run `food <command> --help` before using a command for the first time; for a meal photo, read
`food log --help` first. Setting up a server: `food init --help`.
"#;

/// Steps 1 to 4 of the meal-photo workflow: what's on the plate and how much. `food log --help`
/// and the AI logging agent's system prompt both use it.
macro_rules! photo_estimate {
    () => {
        r#"  1. Name every item, including drinks, sauces, dressings, oil and butter. They're where
     estimates go wrong.
  2. Estimate grams honestly from the plate (about 26 cm), utensils, a hand, packaging and
     typical portions. Don't round down to be kind. If something is ambiguous (fried or grilled,
     whole or skim), pick the likelier one and say which.
  3. Prefer --catalog, so micronutrients come from real data. A query matches the plainest food
     that has all its words, so name foods plainly ("chicken breast roasted", "rice white
     cooked", "olive oil") and add a word only when it matters ("fried", "with skin", "canned").
     `food search "<q>" --no-off` shows the candidates and their fdc: ids.
  4. Otherwise (restaurant dishes, anything the catalog lacks) log by name with the whole
     profile you can reasonably judge: kcal, protein, carbs, fat, fiber, sugar, sat_fat, sodium
     and more. Leave out what you can't judge: missing means unknown, which beats a made-up
     zero. Give whole-plate totals and leave servings at 1.
"#
    };
}

/// Steps 1 to 4 of the meal-photo workflow, as in `food log --help`.
pub const PHOTO_ESTIMATE: &str = photo_estimate!();

pub const LOG: &str = concat!(r#"food log: add entries to the log.

Usage
  food log --catalog <query|fdc:ID> --grams G [options]      USDA data, scaled by weight
  food log --food <id|source_ref> [--servings X|--grams G]   a saved food
  food log "name" --kcal N [nutrient flags] [options]        your own estimate
  food log --json [--json-out] < items.json                  a batch: the whole meal at once

Flags
  --catalog Q     the best USDA match for query Q, or fdc:ID (ids from `food search --no-off`).
                  Needs --grams or --servings. Prefer --grams: one serving is the first USDA
                  portion, which can be large ("Olive oil" is 1 cup = 224 g, 2,016 kcal).
  --food REF      a saved food: id (or prefix), or a source_ref such as fdc:173735,
                  off:<barcode> (only after `food barcode <barcode>`) or agent:<slug>.
  "name"          log by name. Needs at least --kcal. Saved as a food (source_ref
                  agent:<name-and-brand-slug>), so the user can re-log it in one tap; logging
                  the same name again updates that food.
  --grams G       the weight eaten. For --catalog and --food it sets the amount; for a name it
                  is recorded but does not scale the nutrients.
  --servings X    default 1. Nutrient flags are per serving and get multiplied by --servings.
  --kcal N, --protein N, ..., --n key=value
                  nutrients for a name-logged item (see `food help nutrients`).
  --meal M        breakfast|lunch|dinner|snack. Default: from the clock.
  --date D        default today.
  --note T        free text, such as "from photo".
  --brand B       for a name-logged item.
  --json          batch mode when there's no name, --catalog or --food: read items from stdin.
                  On a single-item log it prints the full JSON reply.
  --json-out      print the full JSON reply (every entry and the whole day) instead of the summary.

A meal photo (or "two eggs and toast")
"#, photo_estimate!(), r#"  5. Log the meal in one batch call. It is all or nothing: if any item fails, nothing is logged
     and the error names the item.
  6. CHECK every matched name in the output against the plate. If one is wrong (a sauce,
     "glutinous", "fast food", raw instead of cooked, a different food), fix it right away:
     `food rm <id>`, then log that item again with a better query or the fdc: id. If only the
     amount is off, `food edit <id> --grams G`.
  7. Reply in one line, then what's left: "Logged dinner: rice 200 g, chicken 150 g, salsa
     verde, about 640 kcal and 48 g protein. 1,320 kcal and 95 g protein left today."

Batch items (a JSON array on stdin; a single object also works)
  Each item has exactly one of:
    "catalog"   query or "fdc:ID", with "grams" or "servings"
    "food"      a saved food's id or source_ref
    "name"      with "nutrients": {key: amount per serving}; kcal is required
  and optionally "grams", "servings", "meal", "date", "note", "brand" (name items) and
  "serving_unit" (name items: the saved food's serving label, default "serving").

  food log --json <<'EOF'
  [{"catalog": "rice white cooked", "grams": 200, "meal": "dinner"},
   {"catalog": "fdc:171477", "grams": 150, "meal": "dinner"},
   {"catalog": "olive oil", "grams": 7, "meal": "dinner"},
   {"name": "Chipotle salsa verde", "grams": 30, "nutrients": {"kcal": 15, "carbs": 3,
    "sodium": 260}, "meal": "dinner", "note": "from photo"}]
  EOF

Output: one line per entry (8-character id, the matched name, size, kcal, protein, then the
source_ref and, for a catalog query, the query it matched), then the day's kcal and protein
against target.

Examples
  food log --catalog "egg scrambled" --grams 120 --meal breakfast
  food log "Chipotle chicken burrito bowl" --kcal 750 --protein 52 --carbs 70 --fat 26 \
    --fiber 12 --sodium 1900 --meal lunch --note "from photo"
  food log --food 2211c6cd --servings 1.5 --meal dinner --date yesterday
"#);

pub const TODAY: &str = r#"food today: the day so far.

Usage
  food today [--date D] [--json]

Flags
  --date D   which day (default today).
  --json     the full summary: totals, targets, remaining, meals with entries, gaps, no_data,
             over_limits, goals and that day's health row (weight, activity).

What it shows
  - The plan and mode, then kcal and protein eaten against target (left or over), then carbs,
    fat and fiber.
  - Each meal's entries with their 8-character ids, for `food edit` and `food rm`.
  - "low so far": nutrients under target, lowest first. Only nutrients some entry reports are
    counted, so a total is a lower bound when only some entries report it.
  - "no data yet": nutrients no entry reports. That's unknown, not zero: don't call it a
    deficiency.
  - "over limits": sodium, saturated fat, added sugar or cholesterol past their ceilings.
  Targets are for the whole day, so early in the day everything looks low.

"What should I eat?": start from `food today` (what's left, the biggest gaps) and
`food suggest`, then name a couple of real options the user tends to eat, with rough numbers.

Examples
  food today
  food today --date yesterday
"#;

pub const ENTRIES: &str = r#"food entries: list logged entries.

Usage
  food entries [--date D | --from D [--to D]] [--json]

Flags
  --date D   one day (default today).
  --from D   the first day of a range; --to D is the last (default today).
  --json     full rows: nutrients (the entry's total), servings, grams, food_id, note, source.

Each line: day, meal, 8-character id, name, size, kcal and protein. An entry's nutrients are a
snapshot of what was eaten, so editing a food later doesn't change it.

Examples
  food entries --date yesterday
  food entries --from -6 --json
"#;

pub const EDIT: &str = r#"food edit: change one entry.

Usage
  food edit <entry-id> [--grams G | --servings X] [--meal M] [--date D] [--name T] [--note T]
            [nutrient flags] [--json]

Flags
  <entry-id>     the id from `food today` or `food entries` (8 characters is enough).
  --grams G      the new weight. Rescales the whole nutrient snapshot by new/old grams. Needs an
                 entry that has a weight; otherwise use --servings.
  --servings X   the new servings. Rescales the whole snapshot by new/old servings, and wins
                 over --grams if both are given.
  --meal M       move it to breakfast, lunch, dinner or snack.
  --date D       move it to another day.
  --name T       rename this entry only (the saved food keeps its name).
  --note T       replace the note.
  --kcal N, --protein N, ..., --n key=value
                 overwrite single values in the entry's total (not per serving), after any
                 rescale. Other nutrients stay as they are. Keys: `food help nutrients`.
  --json         print the edited entry as JSON.

Notes
  - Only the entry changes; the saved food and other entries don't.
  - A wrong food is not an edit: `food rm <id>` and log the right one.

Examples
  food edit 0123abcd --grams 180
  food edit 0123abcd --meal lunch --date yesterday
  food edit 0123abcd --sodium 1200 --fiber 8
"#;

pub const RM: &str = r#"food rm: delete entries.

Usage
  food rm <entry-id>... [--json]

Takes one or more entry ids (8 characters is enough) and prints each removed entry. The delete
syncs to the phone. There is no undo: to restore one, log it again. To delete a saved food,
use `food food rm`.

Example
  food rm 0123abcd 4567ef01
"#;

pub const SEARCH: &str = r#"food search: find foods to log.

Usage
  food search "query" [--limit N] [--no-off] [--json]

Flags
  --limit N   how many results (default 15, at most 100).
  --no-off    skip Open Food Facts: faster, and shows the catalog candidates and their fdc: ids.
  --json      full Food objects (serving, portions, nutrients per serving, source_ref).

Order
  1. [mine <id>] the user's own foods with every query word in the name or brand, favorites (★) and
     the most logged first.
  2. [usda] the USDA catalog, plainest match first (the same ranking `food log --catalog`
     uses). Its pick for a query can show as a [mine] line if the user logged it before.
  3. [off] Open Food Facts text search (branded products, 1.5 s budget; it keeps about a
     fifth of the list).
Each line: tag, name, brand, one serving: kcal, P C F (g), then the source_ref.

Notes
  - Nothing is saved until it's logged. Log a catalog result with
    `food log --catalog fdc:ID --grams G`, and the user's own food with `food log --food <id>`.
  - An [off] result can't be logged by its off: ref until `food barcode <digits>` saves it.

Examples
  food search "rice white cooked" --no-off
  food search "fairlife protein shake" --limit 5
"#;

pub const BARCODE: &str = r#"food barcode: look up a product by barcode.

Usage
  food barcode <digits> [--json]

Looks in the user's foods, then the cached Open Food Facts lookups, then Open Food Facts itself, and
saves what it finds as one of the user's foods (it syncs and becomes a recent). 6 to 14 digits;
leading zeros don't matter, so UPC-A and EAN-13 forms find the same food.

Exit status: 0 found (prints the food, its portions and id); 2 not found (misses are cached
for a day); 1 an error, such as Open Food Facts being unreachable.

Then log it: `food log --food off:<digits> [--servings X | --grams G]`. One serving is the
label's serving size when Open Food Facts has one, else 100 g.

The data is crowd-sourced, so sanity-check it: kcal should be near 4 x protein + 4 x carbs +
9 x fat, and the serving size should be plausible. If it's wrong, log by name with corrected
numbers.

Example
  food barcode 0049000028911 && food log --food off:0049000028911 --servings 1
"#;

pub const SUGGEST: &str = r#"food suggest: what the user usually has.

Usage
  food suggest [--meal M] [--json]

Flags
  --meal M   which meal (default from the clock).
  --json     full Food objects for recents and frequent, and yesterday's entries.

Shows up to 8 "frequent" foods (scored over 90 days by the same meal and the time of day, with
older entries counting half every 30 days), up to 8 "recent" foods, and the entries of
yesterday's same meal. Use it for "the usual" and "same as yesterday", and with `food today`
for "what should I eat?". Log one with `food log --food <id>`.

Example
  food suggest --meal lunch
"#;

pub const FOOD: &str = r#"food food: the user's saved foods.

Usage
  food food add [--json] < food.json     add a food, or update one in place (with its id)
  food food list [--favorites] [--json]  every saved food, with how often it's been logged
  food food fav <id> [--off] [--json]    star it (--off unstars it)
  food food rm <id>... [--json]          delete foods

Food JSON (for add; only name is required)
  {"name": "Greek yogurt, plain nonfat", "brand": "Fage", "barcode": "0689544001737",
   "kind": "food",
   "serving": {"amount": 1, "unit": "container", "grams": 170},
   "portions": [{"label": "1 cup", "grams": 245}],
   "nutrients": {"kcal": 90, "protein": 18, "carbs": 6, "fat": 0, "calcium": 200},
   "favorite": false}

Notes
  - nutrients are for ONE serving. serving.grams is optional, but without it the food can only
    be logged by --servings, not --grams.
  - kind is "food" (the default) or "quick" (kcal and macros only). Recipes use
    `food recipe add`.
  - To update a food, send its full row with the same "id" (fields you leave out are dropped).
    Get it with `food food list --json` or
    `food query "SELECT data FROM foods WHERE id LIKE '<prefix>%'"`.
  - Changing or deleting a food never rewrites past entries (they keep their snapshot).
    Deleting one that's in a recipe makes that recipe partial (see `food recipe --help`).
  - Name-logged items and barcode lookups are already saved; don't add them again.

Examples
  food food list --favorites
  food food fav 6093bec7
  food food add --json <<'EOF'
  {"name": "Protein bar", "brand": "Barebells", "serving": {"amount": 1, "unit": "bar",
   "grams": 55}, "nutrients": {"kcal": 200, "protein": 20, "carbs": 16, "fat": 8}}
  EOF
"#;

pub const RECIPE: &str = r#"food recipe add: add or edit a recipe.

Usage
  food recipe add [--json] < recipe.json

Recipe JSON
  {"name": "Magic Beans", "recipe_servings": 4,
   "components": [
     {"catalog": "beans black raw", "grams": 454},
     {"catalog": "fdc:170000", "grams": 150},
     {"food_id": "a4753a10", "servings": 2},
     {"source_ref": "off:0041220197699", "grams": 100}]}

  Each component is one of:
    "catalog" (a query or fdc:ID) with "grams" (or "servings" of its first USDA portion)
    "food_id" (a saved food's id or prefix) with "servings" (or "grams" if it has a weight)
    "source_ref" (fdc:, off: or agent:) with "servings" or "grams"
  With neither amount, a component is 1 serving.

The server computes the nutrients: the ingredient total divided by recipe_servings (default
1), and the serving's grams when every ingredient's weight is known. Nutrients you send are
overwritten. It prints the saved recipe and its id; log it with
`food log --food <id> --servings X`.

Editing a recipe
  Send the full row back with the same "id"; it updates in place instead of making a copy.
  food query "SELECT data FROM foods WHERE id LIKE '2211c6cd%'" | jq -r '.[0].data' > /tmp/r.json
  (change /tmp/r.json: components, recipe_servings, name)
  food recipe add --json < /tmp/r.json
  Saved components come back as food_id plus servings; keep them, or replace one with a
  catalog plus grams item.

Notes
  - Recipes made from dry beans or grains are weighed dry, so the serving's grams are dry
    weight. Log them by servings (a share of the pot: half a 4-serving pot is --servings 2),
    never by cooked grams.
  - A deleted ingredient doesn't break the recipe: it's left out of the nutrients and the
    recipe is marked partial ("partial: N deleted ingredient(s)"). Replace that component to
    fix it.
  - Editing a recipe doesn't rewrite entries already logged from it.
"#;

pub const GOALS: &str = r#"food goals: daily targets.

Usage
  food goals [--json]                       targets, limits, overrides and how they were set
  food goals plan cut|maintain|bulk         change the plan
  food goals set key=value [key=value ...]  override targets; key=auto clears an override
  food goals profile [key=value ...]        show or set body facts: weight, height, age, sex
  food goals auto                           targets follow the profile and activity (default)
  food goals manual                         freeze the current targets

Auto mode: BMR (Mifflin-St Jeor, from the latest weight, height, age and sex) plus the 14-day
average active energy is TDEE; with under 5 days of active energy, TDEE is BMR x the activity
factor (default 1.35). Cut is TDEE - 20%, bulk + 10%. Protein is 2.0 g/kg on a cut, else 1.8;
fat 30% of kcal; carbs the rest; fiber 14 g per 1,000 kcal; micronutrients from the FDA daily
values or the RDA for the profile's sex. It recomputes after every profile change and health
import or refresh. Nothing is guessed: with facts missing the target stays at 2,200 kcal and
the basis note (shown by `food goals`) says what's missing.

set keys
  <nutrient>=N   a target in that nutrient's unit (`food help nutrients`). Overrides win in
                 both modes; overriding kcal in auto mode makes the macros follow it.
  <nutrient>=auto (or =none) clears that override.
  water_ml=N     the daily water target in ml.
  plan=P, mode=M the same as `food goals plan P` and `food goals auto|manual`.

profile keys (=none clears one; health data can set them too, see `food health --help`)
  weight=N       kg, or with a unit: 172lb, 78kg. Counts as today's weighing; a later weighing
                 from health data wins.
  height=N       cm, or 70in, 1.78m.
  age=N          years, counting up from today; birth_date=YYYY-MM-DD wins over it.
  sex=male|female
  activity=F     the TDEE factor without activity data: sedentary 1.2, light 1.375, moderate
                 1.55, active 1.725, very_active 1.9, or a number from 1.0 to 2.5.

Sodium, saturated fat, added sugar and cholesterol are limits (ceilings), not floors.

Change goals or the profile only when the user asks, and say what changed. Leave auto mode on
unless they ask.

Examples
  food goals
  food goals set protein=170 fiber=40
  food goals set protein=auto
  food goals profile weight=172lb height=70in age=34 sex=female activity=light
"#;

pub const REPORT: &str = r#"food report: how the last N days went.

Usage
  food report [--days N] [--json]

Flags
  --days N   the window, ending today (default 7, from 1 to 400).
  --json     the full report: per_day totals and health, averages, coverage, adherence,
             weakest, over_limits, trends, weight.

What it shows
  - Averages of kcal, protein, carbs, fat and fiber. They use complete logged days: today is
    left out until it's over, unless it's the only logged day.
  - Each nutrient is averaged over the days that have data for it, with "(4 of 7 days)" when
    that isn't every logged day. "—" means no data: unknown, not zero.
  - Adherence: days with kcal within 10% of target, and days protein hit its target.
  - "weakest": nutrients lowest against target; "over limits on average": ceilings passed. Both
    only count a nutrient known on at least half the logged days.
  - kcal and protein trends (first half to second half of the window), weight first to last,
    and average active energy.
  - One line per day. "—" means nothing was logged that day, which is not a fast.

Example
  food report --days 14
"#;

pub const QUERY: &str = r#"food query: read-only SQL for anything else.

Usage
  food query "SELECT ..."

Prints a JSON array of row objects (no --json needed). Only statements that don't write run;
anything else is refused.

Tables
  foods, entries, goals, health_days   synced: id, version, updated_at (ms), deleted, data
      (the row's JSON). Always filter deleted = 0. Read fields with json_extract, such as
      json_extract(data, '$.nutrients.kcal'). Indexed copies as columns: entries.day
      (the local day, YYYY-MM-DD), meal, food_id, logged_at; foods.kind, name, source_ref,
      barcode, favorite; health_days.day. goals has one row, id 'current'. health_days.data has
      weight_kg, active_kcal, basal_kcal, steps and exercise_min.
  catalog      the USDA foods, per 100 g: fdc_id, dataset (foundation, sr_legacy, survey),
               name, category, nutrients (JSON per 100 g), portions (JSON [{label, grams}]).
  catalog_fts  full-text index on catalog name and category; join on catalog_fts.rowid = fdc_id.
  off_cache    Open Food Facts lookups by barcode (food is null for a miss).
  meta         key/value: version, profile (the body facts from `food goals profile`), catalog,
               agent (the AI logging settings).
  agent_usage  AI logging spend per day: jobs, prompt_tokens, completion_tokens, cost (USD).
  secrets      holds the AI provider's key; no query can read it.
  List tables with: food query "SELECT name FROM sqlite_master WHERE type = 'table'"
  Columns with:     food query "SELECT name FROM pragma_table_info('entries')"

Limits: at most 10,000 rows or about 16 MB; past that the rows stop and stderr says
"truncated", so aggregate or add a LIMIT. A query still running after 5 s fails.

Notes
  - Put the SQL in double quotes and strings in single quotes. date('now') is UTC, so use
    literal days.
  - Entry nutrients are totals for the entry; food nutrients are per serving.

Examples
  food query "SELECT day, round(sum(json_extract(data, '$.nutrients.protein'))) AS protein
    FROM entries WHERE deleted = 0 AND day >= '2026-11-01' GROUP BY day ORDER BY day"
  food query "SELECT c.fdc_id, c.name, json_extract(c.nutrients, '$.protein') AS protein_100g
    FROM catalog_fts JOIN catalog c ON c.fdc_id = catalog_fts.rowid
    WHERE catalog_fts MATCH 'lentils' LIMIT 10"
"#;

pub const HEALTH: &str = r#"food health: weight and activity for the goals.

Usage
  food health import [FILE|-] [--format json|csv] [--birth-date D] [--sex S] [--height-cm N]
  food health refresh [--json]

import reads daily rows from a file (or stdin) and sends them to the service, which keeps 400
days and recomputes the auto goals. Feed it from any app, spreadsheet or script; importing a
day again replaces it. The iPhone app can push the same rows itself (POST /v1/health_days).

  CSV: a header row with day (or date) and any of weight_kg (or weight_lb), active_kcal,
  basal_kcal, steps and exercise_min. Empty cells are unknown; other columns are ignored.
    day,weight_kg,active_kcal,basal_kcal,steps,exercise_min
    2026-11-07,72.4,520,1710,9120,34
  JSON: a list of such objects, or {"days": [...], "profile": {...}}, where the profile has any
  of birth_date (YYYY-MM-DD), sex (male or female), height_cm, weight_kg and activity_factor.
  --birth-date, --sex and --height-cm set the profile from the command line.

  Days are local days in the service's time zone. active_kcal is active energy (Apple Health's
  "Active Energy", a watch's move calories), not the day's total. With 5 days of it in the last
  14, TDEE is BMR plus its average; otherwise BMR x the activity factor (`food goals --help`).

refresh is for setups with a separate Personal Health server: it runs that server's
`health query` (the health_command setting) as the calling user, picks one source per day (a
Watch first; another person's devices skipped, by the health_owner setting or the owner with
the most Watch days), and pushes the last 400 days and the profile. A timer usually runs it.
`food health-refresh` is the same command.

Examples
  food health import weight.csv --birth-date 1990-04-01 --sex female --height-cm 168
  my-exporter --json | food health import - --format json
  food health refresh
"#;

pub const TOKEN: &str = r#"food token: a new token for the iPhone app (admin).

Usage
  food token new [grace-hours]
  food rotate-token [grace-hours]      the same

Prints a new app token on stdout. Tokens issued before keep working for grace-hours (default
48), then stop; 0 revokes them at once. The app sends it as "Authorization: Bearer <token>";
the server keeps only its SHA-256. Treat it as a password, and only make one when the user
asks.
"#;

pub const EXPORT: &str = r#"food export: back up the log as JSON (admin).

Usage
  food export [FILE|-]

Writes everything that syncs (foods, recipes, entries, goals, health days and deletions), the
food aliases and the profile as one JSON file (created with mode 600), or to stdout. It doesn't
need the database key, so it's the way to back up an encrypted database, move to another
machine or change the encryption. The USDA catalog and the Open Food Facts cache are left out
(`food seed-usda` rebuilds the catalog). The file isn't encrypted: keep it private.

Example
  food export ~/plate-backup-$(date +%F).json
"#;

pub const IMPORT: &str = r#"food import: restore a backup made by `food export` (admin).

Usage
  food import FILE|-

Restores each row unless the database already has the same or a newer copy (by updated_at),
so it's safe to run twice, or into a database in use. The profile is restored only into an
empty one. The app picks up restored rows on its next sync. To move to a new machine or a new
key: `food init` and `food serve` there, then `food import` the export.
"#;

pub const SEED_USDA: &str = r#"food seed-usda: import the USDA catalog (admin).

Usage
  food seed-usda

Downloads USDA FoodData Central (Foundation, SR Legacy and FNDDS survey foods, the newest
complete release of each; public domain) into the cache dir (the cache_dir setting, default
~/.cache/plate) as the caller, then streams it to the service. Downloads already in the cache
are reused, and it's idempotent. A new database needs it once, for `food log --catalog` and
search.
"#;

pub const INIT: &str = r#"food init: first-time setup (admin).

Usage
  food init [--data-dir DIR] [--listen ADDR] [--timezone ZONE] [--encryption keyfile|none]
            [--force]

Writes the config file (~/.config/plate/config.toml, or $FOOD_CONFIG), creates the data
directory (mode 700) and, for an encrypted database, a random key file (mode 600), then prints
the next steps. It doesn't need the service. Safe to rerun: an existing config and key are
kept; --force rewrites the config, never the key.

Flags
  --data-dir DIR    default ~/.local/share/plate (or $XDG_DATA_HOME/plate).
  --listen ADDR     the app's HTTP address, default 127.0.0.1:18792.
  --timezone ZONE   an IANA zone such as Europe/Berlin; default the system zone.
  --encryption E    keyfile (default): SQLCipher keyed by the new key file. none: plain SQLite.
                    For a systemd credential, edit the config (see `food config --help`).

Back up the key file: without it the database can't be read. `food export` makes a backup that
doesn't need it.

Then: `food serve`, `food token new`, `food seed-usda`.
"#;

pub const CONFIG: &str = r#"food config: the effective settings (admin).

Usage
  food config [--json]

Prints every setting, the config file read, how the database is keyed, and whether the service
answers (with its time zone). The config file is the first of $FOOD_CONFIG,
~/.config/plate/config.toml and /etc/plate/config.toml: `key = value` lines, # comments.
FOOD_<KEY> environment variables win over it. No file is needed; these are the defaults.

Keys (environment variable)
  data_dir        database and key file; ~/.local/share/plate         (FOOD_DATA_DIR)
  database        the database file; <data_dir>/food.db                (FOOD_DB)
  listen          the app's HTTP address; 127.0.0.1:18792              (FOOD_LISTEN)
  socket          the CLI socket; $XDG_RUNTIME_DIR/plate/food.sock,
                  else <data_dir>/food.sock (macOS)                    (FOOD_SOCKET)
  socket_uids     other users (uids or names) the socket answers; the
                  service's own user and root always are               (FOOD_SOCKET_UIDS)
  timezone        IANA zone for days and meals; the system zone        (FOOD_TIMEZONE)
  encryption      keyfile, systemd-credential, none or auto            (FOOD_ENCRYPTION)
  key_file        64 hex digits, mode 600; <data_dir>/food.key         (FOOD_KEY_FILE)
  credential      the systemd credential's name; food-key              (FOOD_CREDENTIAL)
  cache_dir       USDA downloads; ~/.cache/plate                       (FOOD_CACHE_DIR)
  off_contact     an email or URL for the Open Food Facts User-Agent   (FOOD_OFF_CONTACT)
  health_command  the `health` CLI for `food health refresh`; health   (FOOD_HEALTH_COMMAND)
  health_owner    whose devices count in a refresh; inferred           (FOOD_HEALTH_OWNER)

encryption
  keyfile             SQLCipher with the key in key_file. Protects a copied disk or backup of
                      the database, not against your own user account, which can read the key.
  systemd-credential  SQLCipher with the key from the service's systemd credential (for
                      LoadCredentialEncrypted=, which can seal it to the machine's TPM).
  none                plain SQLite: anyone who can read the file can read the log.
  auto (default)      the credential if the service has one, else key_file if it exists.
The CLI never opens the database (the service does), so only `food serve` needs the key.
"#;

pub const AGENT: &str = r#"food agent: AI logging, a photo or a sentence to a draft meal (admin).

Usage
  food agent config [--base-url U] [--model M] [--key-stdin] [--auto-log on|off] [--max-jobs N]
                    [--effort none|low|medium|high] [--verify-matches on|off]
  food agent models [query]
  food agent test
  food agent prompt [--default | --set < FILE | --reset]
  food agent log [--photo PATH] [--text T | "text"] [--meal M] [--date D] [--yes]
                 [--dry-run] [--model M] [--effort E]
  Every one takes --json.

The service runs the agent for the app's photo logging: it sends the photo and the note to an
OpenAI-compatible Chat Completions API (OpenRouter by default; OpenAI, a local server and other
compatible ones work), lets the model use read-only tools that are the food commands, and keeps
the meal it proposed as a draft. Nothing is logged until the draft is confirmed, or at once
with auto-log on. You (a CLI agent) don't need it: log with `food log` yourself.

The fast path: in its first reply the model proposes the whole meal as plain catalog queries
with grams, the server matches them, and the first proposal without an item error ends the job.
It searches only when an item fails, all the doubtful items at once.

config     with no flags, prints the settings and the spend today and this month.
  --base-url U       the API base, before /chat/completions; default https://openrouter.ai/api/v1
  --model M          a model id that takes images and calls tools (`food agent models`)
  --key-stdin        read the API key from stdin, keeping it out of the shell history; an empty
                     line clears it. It's stored in the encrypted database and never shown again:
                     not by config, the app's API or `food query`.
  --auto-log on|off  log a good draft straight away (default off; the app still offers undo)
  --max-jobs N       jobs per day, 1 to 1000 (default 60): a backstop against runaway spend
  --effort E         how hard the model thinks: none, low (default), medium or high. Sent as
                     OpenRouter's reasoning.effort or OpenAI's reasoning_effort; other providers
                     get nothing extra. Lower is faster.
  --verify-matches on|off
                     show the model the matched foods and let it propose once more (default
                     off: slower, rarely needed)
models     the provider's models, matching the query. On OpenRouter only those that take images
           and call tools, with USD per 1M tokens in and out. Cached for an hour.
test       one tiny request with the current settings: whether the key, model and credit work,
           and how long it took.
prompt     prints the system prompt in use. --default prints the built-in one: a short preface,
           steps 1 to 4 of the photo workflow in `food log --help` and `food help nutrients`.
           --set reads a custom one from stdin (at most 32 KB); --reset goes back to the
           built-in one. Whatever it says, each job also sends the date and time, the meal,
           what's left today, the note and any barcodes (already looked up), and the same tools.
log        runs one job, prints the draft and its timing, and asks before logging it. --yes
           logs it without asking; with no terminal and no --yes nothing is logged.
  --photo PATH   a JPEG of at most 1.5 MB. It isn't resized: shrink it to about 1024 px first.
  --text T       what was eaten, or a note about the photo ("the rice was brown").
  --meal M, --date D  when it was eaten (default from the clock, and today).
  --dry-run      never log the draft, even with auto-log on or --yes: for trying models.
  --model M, --effort E
                 this job only, without changing the saved settings.

The model's tools (each the same as a command; none of them writes)
  propose_meal     food log --json as a dry run; a good one is the draft
  search_foods     food search "q" [--no-off]
  lookup_barcode   food barcode <digits>, without saving the product
  suggest          food suggest [--meal M]
  get_today        food today [--date D]
  get_goals        food goals

Limits: 2 jobs at once, the daily cap, 6 model turns, 90 s a request, 3 minutes a job. 429s,
5xx and dropped connections are retried twice. Errors say what to do: "API key is invalid",
"out of credit", "unknown model", a content filter or the model declining. Entries it logs have
source agent and the note (or "from photo") as their note. A cancelled job (the app's cancel)
stops at once, logs nothing and doesn't count toward the daily cap. The service log has one
line per job: the outcome, the time, each model turn's time and tool calls, tokens and cost.

Examples
  printf '%s\n' "$OPENROUTER_API_KEY" | food agent config --key-stdin --model openai/gpt-5-mini
  food agent models gemini
  food agent test
  food agent log --photo dinner.jpg --text "half the rice"
  food agent log "two eggs and toast" --meal breakfast --yes
  food agent log --photo dinner.jpg --dry-run --model google/gemini-3.5-flash --effort none
"#;

pub const SERVE: &str = r#"food serve: the service (admin).

Usage
  food serve

Runs in the foreground with the database open: the app's HTTP API on the listen address
(default 127.0.0.1:18792) and the CLI's Unix socket. `food config` shows the settings. Keep it
running with the systemd user unit or the launchd plist in the server's deploy/ directory.
Reach it from the phone over HTTPS only (Tailscale serve, or a reverse proxy with TLS), never
plain HTTP on the internet. Logs go to stderr: one line per request, paths only.

Agents shouldn't start, stop or restart it; read the database through `food query`.
"#;

/// Every command, with its help. `photo` is the meal-photo workflow in `food log --help`.
pub const COMMANDS: &[(&str, &str)] = &[
    ("today", TODAY),
    ("log", LOG),
    ("entries", ENTRIES),
    ("edit", EDIT),
    ("rm", RM),
    ("search", SEARCH),
    ("barcode", BARCODE),
    ("suggest", SUGGEST),
    ("food", FOOD),
    ("recipe", RECIPE),
    ("goals", GOALS),
    ("report", REPORT),
    ("agent", AGENT),
    ("query", QUERY),
    ("health", HEALTH),
    ("token", TOKEN),
    ("export", EXPORT),
    ("import", IMPORT),
    ("seed-usda", SEED_USDA),
    ("init", INIT),
    ("config", CONFIG),
    ("serve", SERVE),
];

/// Other names for commands, with the same help.
pub const ALIASES: &[(&str, &str)] = &[("rotate-token", TOKEN), ("health-refresh", HEALTH)];

fn command_help(name: &str) -> Option<&'static str> {
    COMMANDS.iter().chain(ALIASES).find(|(c, _)| *c == name).map(|(_, text)| *text)
}

pub fn is_help(arg: &str) -> bool {
    arg == "-h" || arg == "--help"
}

/// The nutrient keys and units, from the same table the server uses.
pub fn nutrients() -> String {
    let mut out = String::from("Nutrient keys, for --<key> N, --n key=value, \"nutrients\" in JSON and `food goals set`.\n\n");
    for (group, label) in [("macro", "Energy and macros"), ("fat", "Fats"), ("mineral", "Minerals"), ("vitamin", "Vitamins"), ("other", "Other")] {
        out.push_str(&format!("  {label}\n"));
        let mut line = String::from("   ");
        for n in nutrients::ALL.iter().filter(|n| n.group == group) {
            let item = format!(" {} {}{}", n.key, n.unit, match n.key { "vit_a" => " (RAE)", "folate" => " (DFE)", _ => "" });
            if line.len() + item.len() > 96 {
                out.push_str(&line);
                out.push('\n');
                line = String::from("   ");
            }
            line.push_str(&item);
            line.push(',');
        }
        line.pop();
        out.push_str(&line);
        out.push('\n');
    }
    out.push_str(
        "\nA missing key means unknown, which is not zero: leave out what you can't judge.\n\
         Name-logged nutrients are per serving (times --servings); `food edit` flags overwrite the\n\
         entry's total; foods and recipes store nutrients per serving; the catalog is per 100 g.\n",
    );
    out
}

/// Help for a command or topic name.
pub fn topic(name: &str) -> Option<String> {
    match name {
        "nutrients" | "nutrient" => Some(nutrients()),
        "photo" | "photos" | "meal" => Some(LOG.to_string()),
        "help" => Some(OVERVIEW.to_string()),
        _ => command_help(name).map(str::to_string),
    }
}

fn topic_or_error(name: &str) -> Result<String, String> {
    topic(name).ok_or_else(|| {
        let names: Vec<&str> = COMMANDS.iter().map(|(c, _)| *c).collect();
        format!("no help for {name:?}; commands: {}; topics: nutrients, photo", names.join(", "))
    })
}

/// The help a command line asks for, or None when it isn't asking. Never touches the socket.
/// `food`, `food -h`, `food --help` and `food help` are the overview; `food help <command>` and
/// `-h`/`--help` anywhere in a command's arguments are that command's help.
pub fn requested(raw: &[String]) -> Option<Result<String, String>> {
    let Some(first) = raw.first() else { return Some(Ok(OVERVIEW.to_string())) };
    if first == "help" || is_help(first) {
        return Some(match raw[1..].iter().find(|a| !is_help(a) && !a.starts_with('-')) {
            None => Ok(OVERVIEW.to_string()),
            Some(name) => topic_or_error(name),
        });
    }
    if raw[1..].iter().any(|a| is_help(a)) {
        return Some(command_help(first).map(str::to_string)
            .ok_or_else(|| format!("unknown command {first:?}; run `food --help` for the list")));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn every_command_has_help_with_usage_and_flags_or_examples() {
        for (name, text) in COMMANDS {
            for flag in ["--help", "-h"] {
                assert_eq!(requested(&args(&[name, flag])), Some(Ok(text.to_string())), "{name} {flag}");
            }
            assert_eq!(requested(&args(&["help", name])), Some(Ok(text.to_string())), "help {name}");
            assert!(text.contains("Usage\n"), "{name} has no usage");
            assert!(OVERVIEW.contains(&format!("\n  {name} ")), "{name} is missing from the overview");
            assert!(text.lines().all(|l| l.chars().count() <= 100), "{name} has a line over 100 characters");
        }
    }

    #[test]
    fn help_anywhere_in_the_args() {
        for line in [
            &["recipe", "add", "-h"][..],
            &["food", "fav", "--help"],
            &["food", "fav", "6093bec7", "-h"],
            &["goals", "set", "--help"],
            &["log", "Burrito", "--kcal", "-h", "--meal", "lunch"],
            &["log", "--json", "--help"],
            &["serve", "--help"],
        ] {
            let text = requested(&args(line)).unwrap().unwrap();
            assert!(text.contains(&format!("food {}", line[0])), "{line:?}");
        }
        assert!(requested(&args(&["log", "--catalog", "rice"])).is_none());
        assert!(requested(&args(&["query", "SELECT '-h'"])).is_none());
    }

    #[test]
    fn overview_and_topics() {
        for line in [&[][..], &["-h"], &["--help"], &["help"], &["help", "--help"]] {
            assert_eq!(requested(&args(line)), Some(Ok(OVERVIEW.to_string())), "{line:?}");
        }
        assert!(OVERVIEW.lines().count() <= 50);
        assert!(OVERVIEW.lines().all(|l| l.chars().count() <= 100));
        assert_eq!(requested(&args(&["rotate-token", "--help"])), Some(Ok(TOKEN.to_string())));
        assert_eq!(requested(&args(&["help", "health-refresh"])), Some(Ok(HEALTH.to_string())));
        for (key, var, _) in crate::config::KEYS {
            assert!(CONFIG.contains(&format!("  {key} ")) && CONFIG.contains(var), "{key} is missing from `food config --help`");
        }
        assert_eq!(requested(&args(&["help", "photo"])), Some(Ok(LOG.to_string())));
        let nutrients = requested(&args(&["help", "nutrients"])).unwrap().unwrap();
        for n in nutrients::ALL {
            assert!(nutrients.contains(&format!(" {} {}", n.key, n.unit)), "{}", n.key);
        }
        assert!(requested(&args(&["help", "nope"])).unwrap().is_err());
        assert!(requested(&args(&["nope", "--help"])).unwrap().unwrap_err().contains("food --help"));
    }
}
