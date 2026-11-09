# Plate: design spec

This is the visual and interaction spec for the Plate iPhone app (iOS 26+, SwiftUI, Liquid Glass). Read it alongside `SPEC.md`, which defines the data. Where this doc gives a number, use that number. Where it names a system component, use the system component rather than rebuilding it.

Each Plate server has one user. An agent (or a script) can do most of the logging through the `food` CLI, so the app is mostly a place to look: "how am I doing today, how am I trending". When the user does log by hand, it takes one or two taps.

---

## 1. Principles

1. **Glance first.** Today answers "how much is left, and is protein on track?" in under a second, without scrolling or reading a label.
2. **One or two taps.** Recents, favorites and yesterday's meals log in one tap from the Add sheet or from an empty meal. Search to log is type, then one tap. Every log can be undone from a toast, so there are no confirm dialogs.
3. **Glass is for navigation, content stays solid.** Liquid Glass goes only on the tab bar, toolbars, the bottom accessory, toasts and floating controls. Cards, charts and lists sit on opaque grouped backgrounds, so the numbers stay crisp.
4. **Adherence-neutral color.** Going over a calorie target is never shown in red. Red is only for nutrients that are *limits* (sodium, saturated fat, added sugar, cholesterol) once they're exceeded. The app doesn't scold.
5. **Few numbers, each meaningful.** One hero number per screen. Secondary numbers are smaller, gray, and use monospaced digits. Micronutrients live one tap deeper.
6. **Unknown is not zero.** When a nutrient is missing from an entry, the app says so (shown as "≥" and "partial data"). It never draws the gap as a deficiency.
7. **Agent edits feel alive.** Rows from the server animate in softly, so the phone feels like it's sharing a live log with the agent.

### What we take from each reference

| App | What we take | What we avoid |
|---|---|---|
| **MacroFactor** | Adherence-neutral color. Tapping the hero switches between "remaining" and "eaten" (and remembers the choice). Long-pressing the log button gives a shortcut list of favorites. 7/30/90-day ranges with averages that follow the selected range. A smoothed weight trend line. Speed-mode logging that keeps the logger open after each add. | Dense coaching screens, and carousels of widgets. |
| **Cronometer** | The full micronutrient breakdown grouped by vitamin, mineral and lipid, with target bars. "Oracle" style "best sources of X" suggestions. Time-stamped entries. | The data-dump look: 80 rows with no hierarchy, and ads. |
| **Foodnoms** | An Apple-native feel. Colorful goal tiles at the top of Today. A favorites bar inside the logger. Its developer's write-up on why a floating "+" is the least-bad iOS 26 answer. | A cramped tab bar with a "+" sitting over empty space (we use the bottom accessory instead). |
| **Lose It!** | Friendly copy, big tap targets, a fast barcode flow. | Badges, streak nags and pop-up upsells. |
| **MyFitnessPal Premium** | Calorie goals split by meal, quick add, meal scan (our agent does that part). | Everything else: ads, list clutter, feed content. |
| **Oura (2025 redesign)** | Three tabs, each for a different time horizon (today, vitals, long term), progressive disclosure, and one highlighted insight instead of ten. | Score inflation, and opaque composite scores. |
| **Bevel** | Clean, scannable stat tiles that show health context (weight, active energy, steps) without stealing focus. | Feature sprawl. |
| **Gentler Streak** | A calm palette, gentle wording, and a single "today's recommendation" in place of a list of insights. | Mascots. |
| **Apple Fitness / Health (iOS 26)** | A floating tab bar that minimizes on scroll. Summary cards on grouped backgrounds. The ring metaphor and its overflow lap. | Nothing. Feeling native is the goal. |
| **Welling-style AI trackers** | Agent-logged entries carry a provenance glyph (a camera icon for "from photo") and a short note. | A chat UI. The agent lives on the server, not in the app. |

### Premium features worth having (all free here)

These are features other apps charge for that matter to a single user, mapped to where they live in Plate:

- **Full micronutrients vs targets** (Cronometer Gold, Foodnoms+): the Nutrients detail screen (§4.7) and the weakest-nutrients card in Trends.
- **Custom goals and overrides, adaptive TDEE** (MacroFactor, MFP Premium): Settings → Goals, showing the auto basis and per-nutrient overrides.
- **Meal split goals** (MFP Premium): each meal header shows its share of kcal as a faint target figure.
- **Copy meals / log yesterday again** (MFP, Lose It): "Yesterday's lunch" in the Add sheet and in empty meal sections, logged in one tap.
- **Favorites bar** (Foodnoms+): long-pressing the log button opens a favorites menu, and Recents/Favorites appear at the top of the Add sheet.
- **Recipe builder and import** (Cronometer Gold): the Library recipe builder. The agent can import a recipe from a URL with `food recipe add`.
- **Nutrient insights / "Oracle"** (Cronometer Gold): Nutrients detail → nutrient → "Your best sources", ranked from your own foods.
- **Streaks** (Lose It, Gentler): only a protein streak, shown in Trends. It's never a nag and never sends notifications.
- **Timestamps / meal timing** (Cronometer Gold): `logged_at` time shown in entry edit, plus a "first and last meal" line in the day summary.

---

## 2. Brand

### 2.1 Name

**Keep "Plate".** It's short, concrete, food-specific, and works as both a noun and a glyph (a circle, which is also a ring). MacroFactor uses "plate" internally for its logger UI, but that doesn't conflict with a personal app's name. The wordmark is never shown in the UI; the name appears only on the Home Screen and in Settings.

### 2.2 Color system

There's one signature accent, **Tangerine**, which doubles as the calorie color. Macro colors are spread around the hue wheel so the four bars never blur together. Every color has a **fill** value (for rings, bars and chart marks, at least 3:1 contrast on its card) and an **ink** value (for colored text, at least 4.5:1). In dark mode the fill value doubles as the ink.

Define these as asset-catalog colors with Any and Dark appearances. Name them exactly as in the "Token" column.

| Token | Role | Light fill | Light ink | Dark fill and ink |
|---|---|---|---|---|
| `accent` | Brand, kcal ring, primary actions, selection | `#E8631A` | `#C2470A` | `#FF8A3D` |
| `accentDeep` | kcal overflow lap, pressed state | `#B8430B` | — | `#E0601C` |
| `protein` | Protein | `#6457E8` | `#4F3FD9` | `#8F84FF` |
| `carbs` | Carbohydrates | `#0E9FB8` | `#0B7487` | `#35C8E0` |
| `fat` | Fat, and the lipid group | `#C28400` | `#8F6500` | `#FFCB3D` |
| `fiber` | Fiber | `#3DA35A` | `#277A3F` | `#5ED47C` |
| `water` | Water | `#2F7DEB` | `#1F60C4` | `#5A9EFF` |
| `vitamin` | Vitamin group marker | `#B15AD6` | `#8A3AAE` | `#D08BFF` |
| `mineral` | Mineral group marker | `#6F8197` | `#52637A` | `#9EB0C7` |
| `over` | A limit nutrient past its limit (only use) | `#E5484D` | `#C2292E` | `#FF6369` |
| `track` | Empty ring and bar tracks | `#787880` at 16% | — | `#787880` at 32% |
| `limitFill` | A limit bar under its limit | `#8E8E93` | — | `#98989F` |

Rules:

- **Backgrounds are system colors**: `systemGroupedBackground` (light `#F2F2F7`, dark `#000000`) and `secondarySystemGroupedBackground` for cards (light `#FFFFFF`, dark `#1C1C1E`). Don't use custom grays.
- **Today has a warm wash.** Behind the hero, draw a radial gradient of `accent` at 10% opacity in light mode and 14% in dark, centered 120 pt below the top safe area, radius 320 pt, fading to clear. It gives the glass toolbar something to refract. Only Today gets it.
- **The "other" group** (caffeine, alcohol, water) uses `secondaryLabel` gray.
- **Text on glass** uses system vibrant label colors and is never tinted. The only tinted glass in the app is the primary log control (§5).
- **No more than three hues in one card**, apart from the macro row on Today, which has four.
- **Charts use the fill values.** Today's bar is at 100% opacity, past days at 55%, and future days aren't drawn.
- **Rings and bars have rounded caps, and their tracks are always visible.**

### 2.3 Typography

SF Pro handles UI text. **SF Rounded** is used only for numbers that represent nutrition quantities (hero numbers, ring centers, stat tiles, entry kcal) so the data has a soft, friendly voice. Every number uses **monospaced digits**, and every number that changes uses `contentTransition(.numericText(value:))` inside an animation.

All styles scale with Dynamic Type. The custom sizes below are given at the default "Large" size and scale relative to the text style listed.

| Use | Font | Size / weight | Relative to | Notes |
|---|---|---|---|---|
| Hero number (kcal left) | SF Rounded | 52 pt, bold | `.largeTitle` | Tracking −0.5. The unit goes on its own line below. |
| Hero unit ("kcal left") | SF Pro | 13 pt, semibold | `.footnote` | `secondaryLabel` |
| Screen title | SF Pro | `.largeTitle`, bold | — | System navigation large title |
| Card title | SF Pro | `.headline` (17 semibold) | — | e.g. "Breakfast", "Calories" |
| Card trailing value | SF Rounded | 17 pt, semibold | `.headline` | e.g. meal kcal, `secondaryLabel` |
| Stat tile value | SF Rounded | 22 pt, semibold | `.title2` | e.g. "72.1" |
| Stat tile unit and label | SF Pro | 13 pt, regular | `.footnote` | `secondaryLabel` |
| Macro label | SF Pro | 15 pt, semibold | `.subheadline` | In the macro's ink color |
| Macro value ("96 / 150 g") | SF Rounded | 15 pt, medium | `.subheadline` | The "/ 150 g" part is `secondaryLabel` |
| Entry name | SF Pro | `.body` (17 regular) | — | One line, truncated at the tail |
| Entry detail | SF Pro | `.subheadline` (15) | — | `secondaryLabel`, e.g. "1.5 container · 255 g" |
| Entry kcal | SF Rounded | 17 pt, regular | `.body` | `secondaryLabel`, trailing |
| Section caps ("RECENT") | SF Pro | 13 pt, semibold, +0.4 tracking | `.footnote` | Uppercase. Only used inside the Add sheet. |
| Chart axis | SF Pro | `.caption2` (11) | — | `tertiaryLabel` |
| Nutrition label | SF Pro | Title 28 pt black; rows 15 pt regular or bold | `.body` | Mimics the FDA label (§4.3) |

Number formatting: use thousands separators ("1,240"). kcal and mg are whole numbers. Grams get one decimal under 10 and none above. Percentages are whole numbers. A missing value shows as an en dash "–" in `tertiaryLabel`.

### 2.4 Spacing, radii and sizes

- **Base unit 4 pt.** Tokens: `xs 4`, `s 8`, `m 12`, `l 16`, `xl 24`, `xxl 32`.
- **Screen side margin 16 pt** (the inset-grouped list default). Gap between cards 16 pt. Card inner padding 16 pt.
- **Card corner radius 26 pt**, continuous. This matches the iOS 26 inset-grouped section radius; on screens that use List, take the system value rather than hardcoding it. Elements inside a card that sit at its padding edge use `.rect(corner: .containerConcentric)` or `ConcentricRectangle` so their corners nest.
- **Chips**: capsules 36 pt tall, horizontal padding 14 pt, 8 pt apart.
- **Minimum tap target 44 × 44 pt.** Swipe-action buttons use the system size.
- **Rings**: hero 188 pt in diameter with a 20 pt stroke. Mini rings (in the week strip) 22 pt with a 3 pt stroke.
- **Bars**: macro bars 8 pt tall, nutrient bars 6 pt, water bar 10 pt. All are capsules.

---

## 3. Information architecture

```
TabView (tabBarMinimizeBehavior: .onScrollDown)
├── Today      [fork.knife]          the day: hero, meals, water, nutrients, health
├── Trends     [chart.xyaxis.line]   7 / 30 / 90-day charts
├── Library    [books.vertical]      favorites, my foods, recipes
└── Search     (role: .search)       find any food and log it
tabViewBottomAccessory → Quick Log bar ("+  Log lunch · 1,110 left" | barcode | water)
Settings → gear button in the Today toolbar (top trailing), pushed onto Today's stack
```

**Why this structure:**

- **Three destinations, one per time horizon**, as Oura does it: *today*, *over time*, and *my stuff*. The iOS 26 tab bar sizes itself to its items, so three tabs plus search looks deliberate rather than sparse.
- **Search is a real search tab, not a disguised "+" button.** Apple's guidance (and the Foodnoms developer's critique) is that the search-role tab is for finding content. Foods are the app's content: own foods, the USDA catalog and Open Food Facts. When it's selected, the tab bar turns into a bottom search field, which is the most reachable text field in iOS. Each result logs to the current meal in one tap. Search shares its component with the Add sheet.
- **The primary log action is the tab bar's bottom accessory, not a fake tab.** `tabViewBottomAccessory` is the system slot for a persistent action that floats above the tab bar in Liquid Glass and docks inline next to the minimized tab bar when you scroll. It's always within thumb reach, it uses native glass, and it doesn't take over the search tab. It also has room for context, such as "Log lunch · 1,110 left". *Fallback, only if the accessory proves unworkable:* a 56 pt circular accent-tinted glass button, 16 pt from the trailing edge and 12 pt above the tab bar, on Today only.
- **Settings is not a tab.** It's visited rarely; a gear in the Today toolbar is enough.

**Quick Log bar** (bottom accessory) layout:

```
expanded (placement .expanded), system height
╭───────────────────────────────────────────────────╮
│ (+)  Log lunch                       [▥]   [💧]   │
│      1,110 kcal left                              │
╰───────────────────────────────────────────────────╯
 (+) = 30 pt accent circle with a white "plus" glyph, 15 pt bold
 [▥] = barcode.viewfinder, 36 pt circular hit area, no own background
 [💧] = drop.fill in water color; tap adds 250 ml, long-press opens an amount menu

inline (placement .inline, tab bar minimized)
╭──────────────────╮
│ (+) Log lunch    │
╰──────────────────╯
```

- Tap anywhere except the trailing buttons: opens the **Add sheet** for the current meal (the meal comes from the time of day, using the CLI rules: before 10:30 breakfast, before 15:00 lunch, before 21:00 dinner, otherwise snack). It uses a zoom transition, with the accessory as the `matchedTransitionSource`.
- Long-press: a context menu with the top 4 favorites (each logs in one tap), a divider, then "Quick add", "Copy yesterday's lunch", and "Scan barcode".
- When a past day is selected in Today, the label reads "Log to Thu" and the subtitle shows that day's remaining kcal.

---

## 4. Screens

All screens support light and dark mode, Dynamic Type up to AX3 (layouts reflow to a single column), and VoiceOver. Every ring and bar has an accessibility label such as "Protein, 96 of 150 grams, 64 percent".

### 4.1 Today

Today is a `List` with `.insetGrouped` style, so swipe actions are native. The hero and week strip are rows with a clear background. Pull to refresh forces a sync.

```
┌─────────────────────────────────────────────┐
│ Today                           (⟳·)  (⚙)   │ large title; status pill only when unhealthy
│                                             │
│  M    T    W    T    F   [S]   S            │ week strip
│  3    4    5    6    7   (8)   9            │
│  ◔    ◕    ●    ◑    ◕    ◔    ·            │ 22 pt mini rings
│ ╭─────────────────────────────────────────╮ │
│ │              ╭───────────╮              │ │
│ │            ╱               ╲            │ │ hero ring 188 pt, stroke 20
│ │           │     1,110       │           │ │ 52 pt rounded bold
│ │           │   kcal left     │           │ │
│ │            ╲               ╱            │ │
│ │              ╰───────────╯              │ │
│ │      Eaten 1,240   ·   Goal 2,350       │ │ footnote, secondary
│ │                                         │ │
│ │  Protein          Carbs                 │ │ 2 × 2 macro grid
│ │  ▓▓▓▓▓▓▓░░░░      ▓▓▓▓▓░░░░░░           │ │
│ │  96 / 150 g       120 / 260 g           │ │
│ │  Fat              Fiber                 │ │
│ │  ▓▓▓▓▓▓░░░░░      ▓▓▓░░░░░░░░           │ │
│ │  44 / 78 g        12 / 33 g             │ │
│ ╰─────────────────────────────────────────╯ │
│ ╭ Breakfast                    420 · 590 ⊕ ╮ │ eaten · meal target, + button
│ │ 📷 Greek yogurt, Fage             135    │ │
│ │    1.5 container · 255 g                 │ │
│ │    Banana                         105    │ │
│ │    1 medium · 118 g                      │ │
│ ╰──────────────────────────────────────────╯ │
│ ╭ Lunch                         0 · 820 ⊕  ╮ │
│ │ ┄ Copy yesterday's lunch · 710 kcal  ⊕  ┄│ │ one tap
│ │ [Chipotle bowl 710] [Turkey wrap 480]    │ │ suggestion chips
│ ╰──────────────────────────────────────────╯ │
│ ╭ Dinner … ╮  ╭ Snacks … ╮                  │
│ ╭ Water                      1.25 / 3.0 L ╮ │
│ │ ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░   [+250] [+500]   │ │
│ ╰──────────────────────────────────────────╯ │
│ ╭ Nutrients                          All › ╮ │
│ │ Low so far: Vitamin D 12% · Potassium 41%│ │
│ │ ⚠ Sodium 2,640 / 2,300 mg               │ │ only if a limit is exceeded
│ ╰──────────────────────────────────────────╯ │
│ ╭ Weight ╮ ╭ Active ╮ ╭ Steps ╮              │ 3 stat tiles
│ │ 72.1 kg│ │ 540   │ │ 9,123 │              │
│ │ ↓0.3/wk│ │ kcal  │ │       │              │
│ ╰────────╯ ╰───────╯ ╰───────╯              │
│                                             │
│ ╭──── Quick Log bar (accessory) ────╮       │
│ [ Today ][ Trends ][ Library ]    (🔍)      │
└─────────────────────────────────────────────┘
```

**Toolbar.** The navigation title is "Today", "Yesterday", or "Thu, Nov 6". Top trailing: the gear (Settings). When the selected day isn't today, a "Today" text button joins the trailing group, separated by a fixed `ToolbarSpacer`. The sync status pill appears top leading only when sync isn't healthy (§4.11).

**Week strip.** Seven columns, each 44 pt wide and 64 pt tall: the weekday letter (`.caption`, `secondaryLabel`), the date number (17 pt rounded medium), and then a 22 pt mini ring showing kcal eaten against goal. The selected day has a 36 pt `accent` filled circle behind its date number, with the number in white. Today, when not selected, shows its date number in `accent` ink. Swipe horizontally to page by week (`scrollTargetBehavior(.paging)`), and tap to select a day. Future days are drawn at 30% opacity and can't be selected. A day change cross-fades the content and slides it 12 pt in the direction of travel over 0.25 s, and plays `.selection` haptic feedback.

**Hero card.**

- A ring 188 pt across with a 20 pt stroke, starting at 12 o'clock and running clockwise. The track uses `track`, the fill uses `accent`, and the cap is round.
- When over goal, the ring is full and an overflow lap in `accentDeep` draws over the start, as Activity rings do. The center then reads "180" with "kcal over" below it, in `label` color, not red.
- Tapping the center toggles between **left** ("1,110 / kcal left") and **eaten** ("1,240 / kcal eaten"). The choice persists in `@AppStorage`.
- The subline "Eaten 1,240 · Goal 2,350" swaps to "Left 1,110 · Goal 2,350" when the hero shows eaten.
- **Macro grid**: 2 × 2 with 16 pt column gap and 14 pt row gap. Each cell has a label in macro ink, an 8 pt capsule bar in macro fill on `track`, and a value line. Bars cap at 100% visually. Past 100%, the bar stays full and a small `checkmark` glyph in macro ink appears after the value. Protein gets the celebration (§6).
- Card padding: 20 pt at the top, 16 pt elsewhere. 20 pt between the ring and the subline, and 20 pt between the subline and the grid.

**Meal sections.** One section per meal, in order: breakfast, lunch, dinner, snack. Always show all four.

- **Header**, inside the card at its top: the meal name (`.headline`), then trailing "420 · 590" (eaten in `label`, then " · 590" meal target in `tertiaryLabel`; the target is `goals.meal_split × kcal`), then a 28 pt `plus.circle.fill` button in `accent` that opens the Add sheet preset to that meal.
- **Entry row**: 60 pt minimum height. The name goes on line 1, and the detail (`serving_label` with grams when known) on line 2. kcal is trailing. A 15 pt provenance glyph sits leading in `tertiaryLabel`: `camera.fill` for an agent entry whose note contains "photo", `sparkles` for other agent entries, `barcode` for barcode entries, and nothing for app entries. Indent so names align whether or not a glyph is present (reserve 20 pt).
- **Tap** a row to open Entry edit (§4.5) as a sheet.
- **Swipe trailing** (full swipe deletes): Delete (red, system destructive), then Edit (gray).
- **Swipe leading**: "Again" (`accent`, `arrow.clockwise`), which duplicates the entry into today's current meal and shows the undo toast.
- **Context menu**: Edit, Log again, Move to ▸ (the four meals), Copy to today (only shown on past days), Favorite food (only when `food_id` is set), and Delete.
- **Empty meal**: one dashed-outline row (1 pt dash in `separator`, inset 8 pt, 52 pt tall) reading "Copy yesterday's lunch · 710 kcal" with a trailing ⊕. Tapping it logs all of yesterday's entries for that meal at once. Under it, up to 3 suggestion chips from `/v1/suggest` (`frequent` for that meal), each logging in one tap. If there's no history at all, show just "Add lunch" (opens the Add sheet).
- **Rows from the agent** (synced in while the app is open) insert with a `.opacity.combined(with: .move(edge: .top))` transition, plus a background highlight of `accent` at 12% that fades out over 1.2 s.

**Water card.** The title "Water" with a trailing "1.25 / 3.0 L" (rounded, liters to two decimals). Below it, a 10 pt capsule bar in `water`, and two `.bordered` capsule buttons, "+250" and "+500", tinted `water` and 32 pt tall. Long-pressing either one opens a menu: 150, 330, 500 or 750 ml, and "Custom…". A water entry is an entry with `nutrients.water` set and the name "Water". Water entries are hidden from meal sections and counted only here. Moisture inside foods is not counted.

**Nutrients card.** This is one line of insight, not a table. It shows the 2 or 3 lowest target nutrients by percent of the daily target that have at least 2 logged entries of data. After 18:00 the line reads "Low today", and before that "Low so far". If a limit nutrient is over, a second line appears, starting with a 13 pt `exclamationmark.triangle.fill` in `over` and then "Sodium 2,640 / 2,300 mg". "All ›" pushes Nutrients detail (§4.7).

**Health tiles.** Three equal tiles in one row with 12 pt gaps, 84 pt tall, radius 20 pt, card background, and 12 pt padding. Each has a label (`.footnote`, secondary) at the top and the value (22 pt rounded semibold) with its unit at the bottom.
- **Weight** shows the latest `weight_kg` and a weekly trend rate from the trend line ("↓ 0.3 kg/wk" in `secondaryLabel`; never colored).
- **Active** shows today's `active_kcal`.
- **Steps** shows today's `steps`.
- Null values show "–". Tapping a tile opens Trends scrolled to that chart.
- If `health_days` has never synced, hide the row entirely.

**States.**
- **First launch with no cache**: the hero and three meal sections render with `.redacted(reason: .placeholder)` and a slow opacity pulse (0.5 ↔ 1.0, 1.2 s). No spinners.
- **Empty day**: the ring shows 0%, the center reads "2,350 / kcal to go", and every meal shows its empty-state row.
- **Offline**: everything still works from the cache. Only the status pill changes (§4.11).
- **Goals missing**: the hero shows "eaten" mode with no ring fill, and the subline reads "Goals sync from the server".

### 4.2 Add sheet (the log flow)

This is one sheet, opened from the Quick Log bar, from a meal's ⊕, or from an empty meal row. It's a `NavigationStack` inside a sheet with `.presentationDetents([.large])`. The search field is focused on open, so the keyboard comes up immediately. The same view, minus the close button, is the root of the Search tab.

```
╭─────────────────────────────────────────────╮
│ (✕)        Lunch ▾                  (▥)     │ glass toolbar: close · meal menu · barcode
│  2 added · 290 kcal                          │ appears after the first add
│                                             │
│ FAVORITES                                   │
│ [★ Fage yogurt 135] [★ Oats 300] [★ Whey…]  │ horizontal chips
│ RECENT                                      │
│ [Banana 105] [Chipotle bowl 710] [Egg 72]   │
│ FREQUENT AT LUNCH                           │
│  Turkey wrap             480 kcal    (⊕)    │ 52 pt rows
│  Chicken rice bowl       640 kcal    (⊕)    │
│ YESTERDAY'S LUNCH            Copy all (⊕)   │
│  Chipotle bowl · Diet coke   710 kcal       │
│                                             │
│ [⚡ Quick add]   [＋ Create food]           │ bordered capsule buttons
│    ╭── Logged Banana · 105 kcal   Undo ──╮  │ glass toast
│ ╭─────────────────────────────────────────╮ │
│ │ 🔍 Search foods                     (✕) │ │ bottom search field (system)
│ ╰─────────────────────────────────────────╯ │
│ [            keyboard                     ] │
╰─────────────────────────────────────────────╯
```

- **Toolbar**: leading close (system `xmark`). Principal: a meal `Menu` that shows the current meal with a chevron. Trailing: barcode (`barcode.viewfinder`), which pushes the scanner full screen. Once anything has been added, the close button becomes a checkmark (Done), and a subtitle "2 added · 290 kcal" appears under the meal name, animated with `.numericText`.
- **Chips** (Favorites, Recent): capsules 36 pt tall, on `secondarySystemFill`, showing the name (15 pt medium, up to 18 characters, truncated) and kcal (15 pt rounded, `secondaryLabel`). Favorites have a leading 11 pt `star.fill` in `accent`. Each row scrolls horizontally with 16 pt leading content inset. Favorites show at most 10 and Recents at most 15. If Favorites is empty, hide that row.
- **A chip tap logs immediately** with the food's default serving (or, for a Recent, the last-used serving) into the selected meal. The chip briefly scales to 0.92 and back, `.impact(.light)` plays, and the undo toast appears. A long-press on a chip opens Food detail instead.
- **Rows** (Frequent, Yesterday): the name, a kcal subline, and a trailing 28 pt `plus.circle.fill` in `accent` that logs in one tap. Tapping the row body pushes Food detail. "Copy all" logs every one of yesterday's entries for that meal.
- **Typing** replaces the suggestions with results. Debounce 200 ms. Own foods (and the local catalog cache, if any) appear instantly, followed by server `/v1/search` results.
- **Result groups**: "My foods", "Foods" (USDA), and "Products" (OFF). Each row shows the name, a brand/serving subline, kcal per serving, and the same ⊕ one-tap log. While the server is loading, a single thin indeterminate line runs under the field. Offline, a footer reads "Offline: showing your foods only".
- **No results**: "No match for 'xyz'" with three buttons: "Quick add", "Create 'xyz'", and "Scan barcode".
- **Quick add** pushes a compact form. A 34 pt rounded kcal field is focused with a decimal pad; optional Protein, Carbs and Fat fields sit in a row of three; Name is optional and defaults to "Quick add". When kcal is empty but macros are entered, the kcal placeholder shows 4/4/9 math in `tertiaryLabel` and that value is used. The bottom button reads "Add · 320 kcal" in `.glassProminent`.
- **Create food** pushes the custom food form (§4.8).
- **Multi-add**: the sheet stays open after each log, as MacroFactor's speed mode does. Swipe down or tap Done to dismiss.

**Undo toast** (shared component). A glass capsule 44 pt tall, with horizontal padding 16 pt. It sits 12 pt above the search field inside the sheet, or 12 pt above the Quick Log bar elsewhere.
- **Content**: a leading 15 pt `checkmark.circle.fill` in `accent`, then "Logged Banana · 105 kcal" (15 pt medium, one line), then a trailing "Undo" (15 pt semibold, `accent` ink).
- **Timing**: it slides in from 12 pt below with a spring (response 0.35, damping 0.8) and auto-dismisses after 4 s. A swipe down dismisses it early.
- **Stacking**: a new toast replaces the current one in place, morphing via `glassEffectID` inside the same `GlassEffectContainer`, and the text changes with `.numericText`. Three logs in quick succession read "Logged 3 items · 420 kcal", and Undo removes all three.
- **Undo** deletes the created entries (it sends tombstone mutations) and plays `.impact(.soft)`.

### 4.3 Food detail and serving picker

This is pushed inside the Add sheet, the Search tab, or Library.

```
╭─────────────────────────────────────────────╮
│ (‹)                              (☆)  (⋯)   │
│ Greek yogurt, plain nonfat                   │ title 22 pt bold, 2 lines max
│ Fage · USDA-verified                         │ subline + source badge
│                                             │
│ ╭─────────────── live preview ───────────╮  │
│ │  135 kcal                               │  │ 34 pt rounded bold, numericText
│ │  P 27 g   C 9 g   F 0 g   Fiber 0 g     │  │ macro inks, 15 pt rounded
│ │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░                 │  │ stacked kcal-share bar, 6 pt
│ ╰─────────────────────────────────────────╯  │
│                                             │
│  Amount              [ − ]  1.5  [ + ]      │ stepper ±0.25; tap value to type
│  [½] [1] [1½] [2] [3]                        │ quick multiplier chips
│  Unit          container (170 g)  ▾          │ Menu: serving, portions…, grams
│                                             │
│ ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓ │ nutrition label card
│ ┃ Nutrition Facts                         ┃ │
│ ┃ 1.5 container (255 g)                   ┃ │
│ ┃━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┃ │ 8 pt rule
│ ┃ Calories                          135   ┃ │
│ ┃─────────────────────────────────────────┃ │ 4 pt rule
│ ┃                              % of goal  ┃ │
│ ┃ Total Fat 0 g                      0%   ┃ │
│ ┃   Saturated Fat 0 g                0%   ┃ │
│ ┃ Cholesterol 15 mg                  5%   ┃ │
│ ┃ Sodium 95 mg                       4%   ┃ │
│ ┃ ...                                     ┃ │
│ ┃ Show all nutrients (31) ›               ┃ │
│ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛ │
│                                             │
│  [        Add to Lunch · 135 kcal        ]  │ bottom toolbar, .glassProminent, accent
╰─────────────────────────────────────────────╯
```

- **Live preview card**: kcal updates on every amount change, using `.numericText` inside `withAnimation(.snappy)`. The stacked bar shows each macro's share of kcal (P × 4, C × 4, F × 9), in macro fills with 2 pt gaps.
- **Amount**: the stepper steps by 0.25 servings, or by 5 g when the unit is grams. Tapping the number opens a decimal pad inline. The multiplier chips set the amount directly, and the selected chip is filled `accent` with white text. `.selection` haptics play on each step.
- **Unit Menu**: the food's serving first, then `portions` in order, then "grams" (only when `serving.grams` is known), then "ounces". Changing the unit keeps the total grams constant when possible.
- **Nutrition label**: an opaque card in `secondarySystemGroupedBackground` with a 1.5 pt border in `label` at 85% (the classic FDA look, inverted in dark mode). Inner padding 12 pt, radius 26. Rules are 8 pt, 4 pt and 1 pt in `label`. Rows are 15 pt: bold for the top-level nutrients and regular for sub-rows, which are indented 16 pt. The "% of goal" column uses the user's targets, not the FDA DVs. Unknown values show "–" with no percent. The first 12 rows follow FDA label order, then comes "Show all nutrients (n)", which expands in place, grouped as in §4.7.
- **Bottom button**: full width minus 32 pt, 52 pt tall, `.glassProminent` tinted `accent`. It reads "Add to Lunch · 135 kcal". When editing a recipe ingredient instead, it reads "Add to recipe".
- **Toolbar**: ☆ toggles favorite, with a `.bounce` symbol effect and `.impact(.light)`. The ⋯ menu offers "Edit food" (custom foods only), "Copy as new food", and "Delete food".

### 4.4 Barcode scanner

This is a `fullScreenCover` using VisionKit `DataScannerViewController` with EAN-13, EAN-8, UPC-E and Code 128 symbologies, without the system highlight.

```
┌─────────────────────────────────────────────┐
│ (✕)                                   (🔦)   │ 44 pt glass circles, 16 pt from edges
│                                             │
│          ┌──────────────────────┐           │ reticle 264 × 160, radius 24
│          │                      │           │ 3 pt white corners only (24 pt arms)
│          │                      │           │
│          └──────────────────────┘           │
│        Point at a barcode                    │ 15 pt semibold, white, shadow
│                                             │
│ ╭─────────────────────────────────────────╮ │ result card, glass, radius 32
│ │ Fage Total 0%                     ★     │ │ 16 pt from edges, 16 pt above home
│ │ 1 container (170 g) · 90 kcal           │ │
│ │ [ − ] 1 [ + ]        [ Add · 90 kcal ]  │ │
│ ╰─────────────────────────────────────────╯ │
└─────────────────────────────────────────────┘
```

- **Idle**: a dim scrim (black at 35%) outside the reticle. The reticle corners pulse slowly (opacity 0.6 ↔ 1, 1.6 s).
- **Detected**: the reticle corners snap to the barcode's bounds (spring 0.3 s), `.impact(.medium)` plays, and the app queries `GET /v1/barcode/{code}`. While that's in flight, a compact glass capsule "Looking up…" sits above the home area.
- **Found**: the capsule morphs into the result card (a `glassEffectID` morph inside one `GlassEffectContainer`). The card shows the name, the serving with kcal, a stepper, and an "Add · 90 kcal" `.glassProminent` button. Adding plays `.success`, shows the toast, and resumes scanning for the next item. Tapping the card body pushes full Food detail.
- **Not found**: the card reads "Not found in Open Food Facts", with a "Create food" button (opens §4.8 with the barcode pre-filled) and a "Search instead" button.
- **Offline**: "Can't look up barcodes offline". A barcode that matches one of your own foods still works from the local cache.
- **Camera denied**: a full-screen explainer with a "Open Settings" button.

### 4.5 Entry edit

This is a sheet with `.presentationDetents([.medium, .large])`. It opens at medium; the half sheet uses the inset glass background, which turns opaque at large. Changes save live (optimistic), so there's no Save button. The toolbar has Done (a checkmark) and a trailing ⋯ menu.

```
╭─────────────────────────────────────────────╮
│ (✓)        Greek yogurt               (⋯)   │
│  Fage · 📷 Logged by agent from photo        │ provenance line, footnote
│                                             │
│   135 kcal   P 27  C 9  F 0                 │ live summary, 28 pt rounded
│                                             │
│  Servings          [ − ]  1.5  [ + ]        │
│  Meal    [Breakfast][Lunch][Dinner][Snack]  │ segmented picker
│  Day     Sat, Nov 8                ▾        │ compact DatePicker
│  Time    8:42 AM                   ▾        │ logged_at
│  Note    from photo                         │ TextField
│                                             │
│  Nutrients ›                                │ pushes the scaled full list
│  [            Delete entry             ]    │ red text, bordered
╰─────────────────────────────────────────────╯
```

- Changing servings scales the nutrients snapshot proportionally (per the spec), and the summary animates.
- Quick entries (no `food_id`) show editable kcal/P/C/F fields in place of the servings stepper.
- The ⋯ menu: "Log again now", "Open food" (when `food_id` is set), and "Save as food".
- Delete closes the sheet and shows the undo toast ("Deleted Greek yogurt · Undo").

### 4.6 Trends

A `ScrollView` of chart cards. A range picker (segmented: 7D, 30D, 90D) sits in a glass toolbar at the top, as the `principal` item, and defaults to 7D. Changing the range animates the charts (`.smooth`, 0.35 s). Every card shows its key average for the selected range in its header.

```
┌─────────────────────────────────────────────┐
│ Trends                 [ 7D | 30D | 90D ]   │
│ ╭ Calories               avg 2,180 / 2,350 ╮│
│ │ ▇ ▆ █ ▅ ▇ ▆ ▃   - - - goal - - -        ││ bars + dashed goal rule
│ │ M T W T F S S                           ││
│ ╰─────────────────────────────────────────╯│
│ ╭ Macros                 P 28% C 44% F 28% ╮│
│ │ stacked kcal bars, P/C/F fills          ││
│ ╰─────────────────────────────────────────╯│
│ ╭ Protein  🔥 6-day streak      avg 142 g  ╮│
│ │ bars, goal rule, hit days get a cap dot ││
│ ╰─────────────────────────────────────────╯│
│ ╭ Weight          72.1 kg  ↓0.3 kg/wk      ╮│
│ │ · ·  ·· ·  ·  ─────── trend line        ││
│ ╰─────────────────────────────────────────╯│
│ ╭ Activity       avg 520 kcal · 8,400 steps╮│
│ ╰─────────────────────────────────────────╯│
│ ╭ Weakest nutrients               All ›    ╮│
│ │ Vitamin D   ▓▓░░░░░░░░  24%             ││
│ │ Potassium   ▓▓▓▓▓░░░░░  52%             ││
│ │ Magnesium   ▓▓▓▓▓▓░░░░  61%             ││
│ ╰─────────────────────────────────────────╯│
│ ╭ Nutrient map (30D/90D only)              ╮│
│ │ heatmap: rows nutrients × columns days   ││
│ ╰─────────────────────────────────────────╯│
└─────────────────────────────────────────────┘
```

**Chart rules (all charts):**
- Card padding 16 pt and chart height 180 pt. The weight chart is 200 pt.
- Horizontal gridlines are 0.5 pt in `separator`, three of them, with no vertical gridlines.
- Axis labels use `.caption2` in `tertiaryLabel`. In 7D the x-axis shows weekday letters; in 30D and 90D it shows dates every 7 or 30 days.
- Bars have corner radius 4 pt (2 pt at 90D) and fill the auto width with a 30% gap.
- Goal lines are a `RuleMark`, 1 pt dashed [4, 3] in `secondaryLabel`, with a trailing annotation "goal" in `.caption2`.
- **Selection**: `chartXSelection`. Dragging shows a vertical 1 pt `label` rule and a glass-free popover card (radius 12, `secondarySystemGroupedBackground`, shadow at 8% opacity) with that day's values. `.selection` haptics fire on each day crossed.
- Today's bar is at 100% opacity and the others at 55%. Days with no entries are blank, not 0.
- Tapping a card's header pushes a full-screen version with the same chart at 320 pt plus a table of daily values.

**Cards:**
1. **Calories**: `accent` bars against a goal rule. Bars over goal stay `accent` (adherence-neutral). The header reads "avg 2,180 / 2,350".
2. **Macros**: stacked bars of kcal from protein, carbs and fat in their fills, with the average split percentages in the header. Toggling the header switches to grams.
3. **Protein**: `protein` bars against the goal rule. On days the goal was met, a 5 pt dot in `protein` sits above the bar. The streak (consecutive days ≥ goal, ending today or yesterday) shows as a capsule in the header: `flame.fill` at 13 pt plus "6-day streak" in `protein` ink. The capsule is hidden when the streak is under 2 days.
4. **Weight**: raw weights are 5 pt circles in `secondaryLabel` at 60%. The trend line is a 2.5 pt `accent` line with catmullRom interpolation, using an exponentially weighted moving average (α = 0.1) computed for display only. The header shows the latest trend weight and the weekly rate (trend change over the last 14 days × 0.5). The y-axis domain is the data range ± 1 kg.
5. **Activity**: active kcal as bars in `accent` at 70%, with steps as a 2 pt `secondaryLabel` line on a secondary scale. A toggle in the header switches between the two.
6. **Weakest nutrients**: the bottom 5 target nutrients by average % of target over the range, considering only days with data. Bars are 6 pt in the nutrient's group color. Each row reads "24%", and tapping a row opens that nutrient's history (bars per day vs target) and "Your best sources" (§4.7).
7. **Nutrient map** (30D and 90D): rows are the 12 nutrients most often below target, and columns are days. Each cell is a 10 × 10 pt rounded square (radius 2.5) on a **single-hue** scale of `accent` at 10%, 30%, 55% or 85% for < 25%, < 50%, < 100% and ≥ 100% of target. Missing data is a hollow 1 pt `separator` outline. Single-hue keeps it from becoming a rainbow.

**Empty and loading.** With fewer than 3 days of data, a card shows its chart frame with "Log a few days to see trends" centered in `secondaryLabel`. The weight card with no health data reads "Weight syncs from Health on the server". There are no spinners; charts render from the cache.

### 4.7 Nutrients detail (for one day)

This is pushed from Today (Nutrients "All ›") or from Trends. It's a `List` with `.insetGrouped` sections in this order: **Macros** (energy, protein, carbs, fat, fiber, sugar, added sugar), **Fats** (sat, trans, mono, poly, omega-3, cholesterol), **Vitamins**, **Minerals**, and **Other** (caffeine, alcohol, water). Each section header has an 8 pt dot in the group color followed by the group name.

```
╭ ● Vitamins ─────────────────────────────────╮
│ Vitamin C          ▓▓▓▓▓▓▓▓▓▓│▓▓   112%  ✓ │ target, met
│ 101 / 90 mg                                 │
│ Vitamin D          ▓▓░░░░░░░░│      12%    │ target, low
│ ≥ 2.4 / 20 µg · partial data                │
╰─────────────────────────────────────────────╯
╭ ● Fats ─────────────────────────────────────╮
│ Saturated fat      ▒▒▒▒▒▒▒░░░┆       70%    │ limit, under
│ 14 / 20 g limit                             │
│ Sodium             ▒▒▒▒▒▒▒▒▒▒┆███  115%  ⚠ │ limit, over
│ 2,640 / 2,300 mg · 340 over                 │
╰─────────────────────────────────────────────╯
```

- **Row**: 56 pt tall. Line 1 has the name (`.body`), then a 6 pt bar 120 pt wide, then the percent (15 pt rounded, trailing, 44 pt wide). Line 2 has the amounts (`.subheadline`, `secondaryLabel`).
- **Targets**: the bar fill is the group color (macros use their own macro colors). A 1 pt `label` tick at 35% opacity marks 100%, placed at 80% of the bar width, so the bar has room to show up to 125%. Past 100%, the fill continues to the end of the bar and a 13 pt `checkmark` in the group ink appears after the percent.
- **Limits** are styled differently. The track has a 1 pt `separator` outline. The fill is `limitFill` gray up to the limit, and the limit tick is a 1.5 pt dashed line in `over`. Past the limit, the portion beyond the tick is filled `over`, and line 2 adds "· 340 over" in `over` ink with an `exclamationmark.triangle.fill`. The suffix reads "limit", not "goal".
- **Partial data**: if any of the day's entries lacks the nutrient, the amount gets a "≥" prefix and the suffix "partial data". A footnote at the bottom of the section gives the count: "3 of 9 entries have no vitamin D data".
- **Unknown** (no entry has the nutrient): the row reads "–" with an empty track, shown in `tertiaryLabel`.
- **Tapping a row** pushes the nutrient page. It has a 30-day bar chart against the target, then "Today's sources" (entries ranked by contribution), then "Your best sources", which lists the top 8 of your own foods and recipes by amount per 100 kcal, each with a one-tap ⊕ log button.

### 4.8 Library

A segmented picker in the toolbar's principal slot switches between Favorites, My foods and Recipes. Trailing "+" opens a menu with "New food" and "New recipe". Rows are 60 pt: the name, a subline (brand · serving · kcal), and a trailing ⊕ that logs to the current meal. Swipe actions: Favorite/Unfavorite (leading, `accent`) and Delete (trailing). The list is filtered with `.searchable` and `searchToolbarBehavior(.minimize)`.

**Empty states**: Favorites reads "Star a food to keep it one tap away" with a star glyph at 44 pt in `tertiaryLabel`. Recipes reads "Build a recipe from foods you eat" with a "New recipe" bordered button.

**Custom food form** (`Form`):
- **Name**, then **Brand**, then **Barcode** (with a scan button).
- **Serving**: amount, unit, and optional grams.
- **Calories & macros**: kcal, protein, carbs, fat and fiber, using decimal pads with units as trailing `secondaryLabel` text.
- **More nutrients**: a `DisclosureGroup` per group.
- **Portions**: add label and grams pairs.
- Save is a checkmark in the toolbar.

**Recipe builder:**

```
╭─────────────────────────────────────────────╮
│ (✕)         New recipe                (✓)   │
│ Name     Chicken rice bowl                  │
│ Makes    [ − ]  4 servings  [ + ]           │
│ ╭ Per serving ───────────────────────────╮  │ live, sticky at top while scrolling
│ │ 640 kcal   P 48  C 72  F 16            │  │
│ ╰────────────────────────────────────────╯  │
│ INGREDIENTS               1,810 kcal total  │
│  Chicken breast, raw     600 g    660 kcal  │ tap = amount editor
│  Jasmine rice, dry       320 g  1,150 kcal  │ swipe to delete, drag to reorder
│  ＋ Add ingredient                           │ pushes the search component
╰─────────────────────────────────────────────╯
```

The per-serving card updates live as the client-side sum divided by servings; the server recomputes it authoritatively when the recipe is saved. Saving shows a toast, "Recipe saved", with a "Log a serving" action.

### 4.9 Search tab

This is the Add sheet's search component as a full tab, with the system bottom search field. Its idle state shows "Recent searches" (up to 8, removable) and then the same Favorites and Recent chips. The meal for one-tap logging appears as a glass capsule menu at the top trailing, e.g. "Lunch ▾".

### 4.10 Settings

Pushed from the gear in Today. It's a `Form`.

```
╭ Server ────────────────────────────────────╮
│ ● Connected                    synced 3 s  │ dot: fiber green / gray / over red
│ plate.example.com               v 18,204   │ footnote, monospaced
│ Pending changes                 0          │
│ [ Sync now ]                               │
╰────────────────────────────────────────────╯
╭ Goals ─────────────────────────────────────╮
│ Mode          [ Auto | Manual ]            │
│ Plan          [ Cut | Maintain | Bulk ]    │
│ Calories      2,350 kcal          auto     │ badge
│ Protein       160 g        override  ✕     │ tap ✕ to clear the override
│ Carbs …  Fat …  Fiber …  Water 3.0 L       │
│ Micronutrients ›                           │
│ Meal split ›   Limits ›                    │
╰────────────────────────────────────────────╯
╭ How your goal is set ──────────────────────╮
│ BMR 1,720 kcal                             │
│   Mifflin–St Jeor · 72.1 kg · 178 cm · 22  │
│ + Active energy 520 kcal (14-day avg)      │
│ = TDEE 2,400 kcal                          │
│ Maintain → 2,400 · rounded to 2,350        │
│ Updated 12 min ago                         │
│ basis.note shown here in secondary text    │
╰────────────────────────────────────────────╯
```

- **Badges**: "auto" is a capsule with `secondarySystemFill` and `secondaryLabel` text. "override" is a capsule with `accent` at 15% and `accent` ink. Both are 11 pt semibold.
- **Tapping a goal row** opens an inline editor (stepper plus a typed field). Saving writes `goals.overrides[key]`. The app never computes goals itself; it shows "Recalculating…" until sync returns the new targets.
- Plan and Mode write to `goals`, and the server recomputes the targets.
- **Basis card**: its equation lines use 15 pt rounded, monospaced digits, aligned in a grid. Show only what `basis` contains. If `basis.note` exists, show it in a footnote.
- **App Icon** (after Apple Health): a 4-column grid of the eight icons as rounded-square thumbnails; the current one gets an accent ring and a checkmark. A tap switches the icon at once with a light haptic, and a toast explains if iOS refuses.
- **About**: the current app icon, version, "Your food log, on your own server", and the token status ("Token set" / "Missing").

### 4.11 Sync and offline status (global)

- **Healthy** (a long-poll is active, the outbox is empty, the last sync was under 60 s ago): no indicator at all.
- **Syncing with pending changes**: a top leading toolbar glass pill containing a 12 pt `arrow.triangle.2.circlepath` with a `.rotate` symbol effect and the count, e.g. "2".
- **Offline**: the pill shows `icloud.slash` and "Offline · 3 pending". Tapping it explains: "Changes are saved on this phone and will sync when your server is reachable."
- **Auth error**: the pill shows `exclamationmark.triangle.fill` in `over` and "Sign-in failed". Tapping it opens Settings.

---

## 5. Liquid Glass rules

1. **Glass lives only on the navigation layer**: the tab bar, toolbars, the bottom search field, the Quick Log accessory, toasts, the scanner's floating buttons and result card, and the status pill. **Never** on cards, list rows, charts, the nutrition label or chips.
2. **Prefer system components**, which get glass for free: `TabView`, toolbar items, `.searchable`, sheets, and `Menu`. Don't add custom backgrounds or shadows behind toolbar items, because that breaks the scroll-edge effect. Leave sheets with the default `presentationBackground`.
3. **Tint means "primary action", and nothing else.** Only these use `.glassProminent` or a `.tint(accent)`-ed glass: the "Add to …" buttons, the scanner's Add button, and Quick add's Add. Everything else is plain `.glass` with monochrome symbols.
4. **One `GlassEffectContainer` per floating cluster.** The scanner overlay (close, torch, lookup capsule, result card) is one container. The toast and the sheet's search field share one. Glass can't sample glass, so never stack two separate glass elements on top of each other.
5. **Morphs** use `glassEffectID` within a namespace: lookup capsule → result card (scanner), toast → updated toast, and status pill → expanded explainer. The morph animation is `.bouncy(duration: 0.4)`.
6. **`.interactive()`** goes only on custom glass controls that are tappable (the scanner buttons, the toast's Undo area, the status pill).
7. **Scroll edges**: use the default soft edge effect under toolbars. Use `.hard` only on Trends, where the segmented picker sits over charts with gridlines.
8. **Content under the glass**:
   - Cards use the opaque `secondarySystemGroupedBackground` at radius 26 pt, continuous.
   - Inner elements touching the padding edge use concentric corners.
   - Card shadows are none in light mode (the grouped background provides the contrast) and none in dark mode.
   - The Today accent wash (§2.2) is the only decorative background.
   - System materials (`.regularMaterial`) appear in one place only: behind the scanner's instruction label on the camera feed.
9. **Tab bar behavior**: `tabBarMinimizeBehavior(.onScrollDown)` on every tab. The accessory reads `tabViewBottomAccessoryPlacement` and switches to its inline layout when the bar minimizes.
10. **Accessibility**: when Reduce Transparency is on, the system glass becomes frosted automatically. Custom glass must also stay legible, so test the toast and scanner card with it on. When Increase Contrast is on, toast text uses `label`.

---

## 6. Haptics, motion and delight

**Motion defaults.** Interactions use `.snappy` (about 0.25 s), layout changes use `.smooth(duration: 0.35)`, and celebratory moments use `.bouncy`. When Reduce Motion is on, every spring becomes a 0.2 s ease-in-out cross-fade, and rings jump to their value.

| Moment | Visual | Haptic (`sensoryFeedback`) |
|---|---|---|
| App opens to Today | The hero ring and macro bars animate from 0 to their values, once per launch: spring with response 0.9 and damping 0.85, bars staggered 60 ms apart. Numbers count up via `.numericText`. | none |
| A log from any surface | The ring and bars extend to their new values (spring 0.6 / 0.85), and the toast appears | `.impact(weight: .light)` |
| Undo | The toast collapses, and the ring retracts | `.impact(flexibility: .soft)` |
| Stepper or day change | Number rolls | `.selection` |
| Barcode detected | The reticle snaps to the code | `.impact(weight: .medium)` |
| Barcode food added | The card's Add button briefly shows a checkmark | `.success` |
| kcal goal reached (≥ 100%) | Ring cap gets a single soft glow pulse (`accent` shadow radius 0 → 12 → 0 over 0.8 s) | `.impact(weight: .light)` |
| **Protein goal hit** (first time each day) | See below | `.success` |
| Delete via swipe | System | system |
| Agent entry arrives | Row slides in with a 12% accent highlight that fades over 1.2 s | none (it's passive) |
| Water +250 | Bar extends, and a single `drop.fill` floats up 16 pt from the button and fades over 0.6 s | `.impact(weight: .light)` |

**The protein moment.** When protein crosses its goal for the first time that day:
1. The protein bar fills to 100%.
2. A white highlight sweep, 30% opacity and 24 pt wide, moves across the bar left to right over 0.7 s.
3. `checkmark.seal.fill` in `protein` appears after the value with `.symbolEffect(.bounce)`.
4. The toast text becomes "Protein goal hit · 152 g" with a leading seal glyph instead of the checkmark.

There's no confetti, no sound and no modal. It happens once per day (store the date). If the streak reaches 7 or a multiple of 7, the toast adds " · 7-day streak".

**Copy tone.** Short and kind, with no exclamation marks except "Protein goal hit". Never "You failed" or "Over budget!"; say "180 over" instead.

---

## 7. App icon

**Shipped icon (Nov 2026):** the primary is the E1 "tomato linocut", a flat, hand-cut tomato on cream with an offset mustard print, plus a cocoa dark variant and a grayscale tinted one (masters in `app/icon/concepts/E1-tomato-linocut/`, generated into the catalog by `app/icon/make_icons.py`). Settings → App Icon offers seven alternates: Place Setting (D1), Plate P (D2), Steam Bowl (D3), Simple Tomato (D4), Market Bowl (E2), Paper Plate (E3) and Steamy Bowl (E4). The Ring Plate spec below is retired; its masters are in `app/icon/legacy-ring-plate/`.

The canvas is 1024 × 1024 px, delivered as an Icon Composer `.icon` file. Layers are square and unmasked, exported as SVG at full canvas size, with no baked-in highlights, shadows or blurs (the system adds them). Each concept below gives coordinates on that canvas, with the origin at the top-left and the center at (512, 512).

### Concept A: "Ring Plate" (recommended)

A top-down plate whose rim is a progress ring three-quarters full. It reads as both "plate" and "goal ring", and it's the same shape as the hero ring, so the icon *is* the app.

- **Background layer**: a linear gradient at 160° (top to bottom, slightly right of vertical). It runs from `#FF9A52` at 0%, through `#F26A1F` at 55%, to `#D9480F` at 100%.
- **Foreground group 1, "plate"**:
  - **Rim disc**: a circle centered at (512, 512) with radius 330 and fill `#FFFFFF` at 100%.
  - **Well**: a circle centered at (512, 512) with radius 214 and fill `#FFF1E6` at 100%. In Icon Composer, set this layer's opacity to 85% so the glass gives the well some depth.
- **Foreground group 2, "progress"**:
  - **Arc**: an arc centered at (512, 512) with radius 272 (the midline of the rim), stroke width 72, and round caps. It starts at −90° (12 o'clock) and sweeps 270° clockwise, ending at 180° (9 o'clock). Stroke color `#F26A1F`.
  - **Leading dot**: a solid circle with radius 36 at the arc's start (512, 240), same color, which makes the start cap read cleanly.
  - The unfilled quarter (9 o'clock to 12 o'clock) shows the white rim, which reads as "room left".
- Put the two groups in separate Icon Composer groups. The plate group gets the default Liquid Glass with specular highlights, and the progress group gets less translucency (about 10%) so the arc stays saturated.
- **Dark variant**:
  - Background: a gradient from `#3A2416` at the top to `#120B07` at the bottom.
  - Rim disc: `#2C2C2E`. Well: `#1C1C1E`.
  - Arc: `#FF8A3D`. Its glow reads well on dark.
- **Clear and tinted variants**: the background is system-provided. Rim at 55% white, well at 25% white, and the arc at 100% white, so the arc is the brightest element in mono. It passes the silhouette test: a ring with a gap.
- **Small-size check**: at 29 pt the arc is still about 2 pt thick, and the gap stays visible.

### Concept B: "Fork Bars"

Three rounded vertical bars of different heights (left 300, middle 420, right 360 px tall, each 96 px wide, with 40 px gaps, bottom-aligned at y = 720, corner radius 48) form the tines of a fork. A rounded handle (96 × 220, radius 48) is centered below the middle bar at y 720–940. The bars use the protein, carbs and fat fills on a deep ink background (`#1B1A2E` → `#2C2A4A`), and the handle is white. It says "data" and "food" at once, but three colors fight in tinted mode, and it looks like a generic chart app.

### Concept C: "Bite"

A solid circle (radius 340) in cream `#FFF4EA` on a tangerine gradient, with a single circular "bite" cut from its upper right: a circle of radius 120 centered at (790, 300) is subtracted. Inside it sits a small tangerine dot (radius 56) at (512, 512), like a pip. It's friendly and very simple, but it reads as "cookie" or "Pac-Man", and it loses the goal-ring tie-in.

**Recommendation: Concept A.** It's the only concept whose silhouette is the app's own hero element. It's built from two filled, overlapping shapes and one thick stroke, as the HIG recommends, so it survives the dark, clear and tinted variants. And the tangerine background owns a color that no system app uses as its full background.

---

## 8. Anti-patterns to avoid

- **MFP-style diary walls**: gray tables of every meal with "Add food" buttons in each row, totals rows, and remaining-calorie math in a grid. We have one hero and calm meal cards instead.
- **Ads, upsells, "premium" badges, feed content, articles, challenges.** None of them, ever.
- **Too many numbers**: no per-row macros on Today (entry rows show kcal only), and no more than one bold number per card. Micronutrients stay out of Today, apart from the one insight line.
- **Rainbow overload**: never color-code each entry or each meal. Group colors appear only as 8 pt dots and nutrient bars. The heatmap is single-hue.
- **Red for being over calories, or green for being under.** Moralizing colors make people avoid logging. Red means a limit nutrient was exceeded, and only that.
- **Treating missing as zero.** It makes the micronutrient view lie. Always show "partial data".
- **Glass on content**: frosted cards, glass chips, or glass charts. It kills legibility and fights the real navigation glass.
- **Fake tabs and hijacked search**: the "+" is never a tab, and the search tab only ever searches.
- **Confirmation dialogs for logging or deleting.** Undo replaces them.
- **Gamified streak guilt**: no broken-streak alerts and no flames on Today. The only notifications are opt-out meal reminders, which fire only when that meal is still empty, with short, warm copy and never a calorie warning.
- **Spinners and blocking loaders.** The cache renders instantly, and the network only refines it.
- **Custom tab bars, custom sheets, or custom search fields** that imitate the system. They lose glass, accessibility and future OS updates.

---

## Sources

1. Apple WWDC25, "Build a SwiftUI app with the new design": https://developer.apple.com/videos/play/wwdc2025/323/
2. Apple HIG, App icons: https://developer.apple.com/design/human-interface-guidelines/app-icons
3. MacStories, iOS and iPadOS 26 review (buttons, toolbars, tab bars): https://www.macstories.net/stories/ios-and-ipados-26-the-macstories-review/3
4. Create with Swift, "Adapting search to the Liquid Glass design system": https://www.createwithswift.com/adapting-search-to-the-liquid-glass-design-system/
5. Ryan Ashcraft (Foodnoms), "My beef with the iOS 26 tab bar": https://ryanwesley.com/ios-26-tab-bar-beef
6. MacroFactor, dashboard revamp: https://macrofactor.com/dashboard-revamp/
7. MacroFactor, Fastest Food Logger Index 2025: https://macrofactor.com/fastest-food-logger-2025/
8. MacStories, Foodnoms 2 review: https://www.macstories.net/reviews/foodnoms-2-refreshes-its-design-and-adds-refinements-to-nutrition-logging-and-goal-tracking-throughout/
9. Cronometer Gold features: https://cronometer.com/gold
10. Cronometer, Nutrition Scores: https://cronometer.com/blog/nutrition-scores/
11. MyFitnessPal Premium features: https://support.myfitnesspal.com/hc/en-us/articles/360032625951
12. Oura, the new Oura app experience: https://ouraring.com/blog/new-oura-app-experience/
13. iThinkDiff, Gentler Streak and Liquid Glass (Streak Tab 4.0): https://www.ithinkdiff.com/?p=335919
14. Bevel app review (Autonomous): https://www.autonomous.ai/ourblog/bevel-app-review
15. Lose It! App Store listing: https://apps.apple.com/us/app/lose-it-calorie-counter/id297368629
