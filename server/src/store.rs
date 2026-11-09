//! Synced rows: reads, last-writer-wins writes, the sync snapshot, food dedupe by source_ref and
//! recipe math. Every write takes a new version from the global counter.

use crate::{db, goals, nutrients, time};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};

pub struct Row {
    pub data: Value,
    pub updated_at: i64,
    pub deleted: bool,
}

fn check_table(table: &str) -> Result<&'static str, String> {
    db::SYNCED.iter().find(|t| **t == table).copied().ok_or_else(|| format!("unknown table {table:?}"))
}

pub fn get(db: &Connection, table: &str, id: &str) -> Result<Option<Row>, String> {
    let table = check_table(table)?;
    db.query_row(&format!("SELECT data, updated_at, deleted FROM {table} WHERE id = ?1"), [id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
    })
    .optional()
    .map_err(|e| e.to_string())?
    .map(|(data, updated_at, deleted)| {
        Ok(Row { data: serde_json::from_str(&data).map_err(|e| e.to_string())?, updated_at, deleted: deleted != 0 })
    })
    .transpose()
}

/// A live (not deleted) row's data.
pub fn live(db: &Connection, table: &str, id: &str) -> Result<Option<Value>, String> {
    Ok(get(db, table, id)?.filter(|r| !r.deleted).map(|r| r.data))
}

pub fn normal_barcode(code: &str) -> String {
    let digits: String = code.chars().filter(char::is_ascii_digit).collect();
    let trimmed = digits.trim_start_matches('0');
    if trimmed.is_empty() { digits } else { trimmed.to_string() }
}

/// Writes a row as is (the caller has already decided it wins). Returns its new version.
pub fn put(db: &Connection, table: &str, data: &Value) -> Result<i64, String> {
    let table = check_table(table)?;
    let id = data["id"].as_str().ok_or("row needs an id")?;
    let updated_at = data["updated_at"].as_i64().unwrap_or_else(time::now_ms);
    let deleted = i64::from(data["deleted"].as_bool().unwrap_or(false));
    let version = db::next_version(db)?;
    let text = data.to_string();
    let s = |key: &str| data.get(key).and_then(Value::as_str).map(str::to_string);
    let result = match table {
        "foods" => db.execute(
            "INSERT OR REPLACE INTO foods (id, version, updated_at, deleted, data, kind, name, source_ref, barcode, favorite)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![id, version, updated_at, deleted, text, s("kind"), s("name"), s("source_ref").filter(|r| !r.is_empty()),
                    s("barcode").map(|b| normal_barcode(&b)).filter(|b| !b.is_empty()),
                    i64::from(data["favorite"].as_bool().unwrap_or(false))]),
        "entries" => db.execute(
            "INSERT OR REPLACE INTO entries (id, version, updated_at, deleted, data, day, meal, food_id, logged_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![id, version, updated_at, deleted, text, s("day"), s("meal"), s("food_id"), data["logged_at"].as_i64()]),
        "health_days" => db.execute(
            "INSERT OR REPLACE INTO health_days (id, version, updated_at, deleted, data, day) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, version, updated_at, deleted, text, s("day")]),
        _ => db.execute("INSERT OR REPLACE INTO goals (id, version, updated_at, deleted, data) VALUES (?1, ?2, ?3, ?4, ?5)",
                        params![id, version, updated_at, deleted, text]),
    };
    result.map_err(|e| e.to_string())?;
    Ok(version)
}

/// Everything with a version past `since`, tombstones included.
pub fn sync(db: &Connection, since: i64) -> Result<Value, String> {
    let mut out = Map::new();
    out.insert("version".into(), json!(db::version(db)));
    for table in db::SYNCED {
        let mut statement = db
            .prepare_cached(&format!("SELECT data, version FROM {table} WHERE version > ?1 ORDER BY version"))
            .map_err(|e| e.to_string())?;
        let rows = statement
            .query_map([since], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| e.to_string())?;
        let mut list = Vec::new();
        for row in rows {
            let (data, version) = row.map_err(|e| e.to_string())?;
            let mut value: Value = serde_json::from_str(&data).map_err(|e| e.to_string())?;
            value["version"] = json!(version);
            list.push(value);
        }
        out.insert(table.to_string(), Value::Array(list));
    }
    Ok(Value::Object(out))
}

#[derive(Debug)]
pub struct Outcome {
    pub applied: bool,
    /// The row's id after dedupe: a food whose source_ref already existed maps to the existing food.
    pub id: String,
}

fn resolve_alias(db: &Connection, id: &str) -> String {
    db.query_row("SELECT id FROM food_aliases WHERE alias = ?1", [id], |row| row.get(0)).unwrap_or_else(|_| id.to_string())
}

fn food_by_source_ref(db: &Connection, source_ref: &str) -> Option<String> {
    db.query_row("SELECT id FROM foods WHERE source_ref = ?1 AND deleted = 0 ORDER BY version LIMIT 1", [source_ref], |r| r.get(0)).ok()
}

/// Who sent a write. The app's bad rows are rejected with a per-mutation error; the CLI's
/// out-of-range timestamps are its own clock's, so they're replaced with now.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Origin {
    App,
    Cli,
}

/// 2020-01-01T00:00:00Z. Nothing in Plate is older.
const EARLIEST_MS: i64 = 1_577_836_800_000;
const DAY_MS: i64 = 86_400_000;
/// The largest row a client may write, as JSON.
pub const MAX_ROW_BYTES: usize = 256 * 1024;

/// A timestamp field: absent (or null, or 0 for created_at and logged_at, which clients use for
/// "unknown") is None. Otherwise it must be whole ms from 2020 to a day from now.
fn timestamp(row: &Map<String, Value>, key: &str, origin: Origin, now: i64) -> Result<Option<i64>, String> {
    let Some(value) = row.get(key).filter(|v| !v.is_null()) else { return Ok(None) };
    if key != "updated_at" && value.as_f64() == Some(0.0) {
        return Ok(None);
    }
    let ms = value.as_i64().or_else(|| value.as_f64().filter(|x| x.fract() == 0.0 && x.abs() < 1e15).map(|x| x as i64));
    match ms.filter(|ms| (EARLIEST_MS..=now + DAY_MS).contains(ms)) {
        Some(ms) => Ok(Some(ms)),
        None if origin == Origin::Cli => Ok(Some(now)),
        None => Err(format!("{key} must be whole ms since the epoch, from 2020 to a day from now")),
    }
}

/// An amount a row may carry: absent or null, or a number from 0 to MAX_AMOUNT.
fn amount(value: &Value, name: &str) -> Result<(), String> {
    match value {
        Value::Null => Ok(()),
        v if v.as_f64().is_some_and(|x| (0.0..=nutrients::MAX_AMOUNT).contains(&x)) => Ok(()),
        _ => Err(format!("{name} must be a number from 0 to 1e9")),
    }
}

/// The numeric fields clients read, checked on the way in and again after the server's own math,
/// so a stored row always passes when a client sends it back.
fn check_amounts(table: &str, row: &Value) -> Result<(), String> {
    match table {
        "foods" => {
            amount(&row["recipe_servings"], "recipe_servings")?;
            amount(&row["serving"]["amount"], "serving.amount")?;
            amount(&row["serving"]["grams"], "serving.grams")?;
            if let Some(portions) = row["portions"].as_array() {
                for portion in portions {
                    if !portion.is_object() {
                        return Err("each portion must be an object".to_string());
                    }
                    amount(&portion["grams"], "portion grams")?;
                }
            }
            if let Some(components) = row["components"].as_array() {
                for component in components {
                    amount(&component["servings"], "component servings")?;
                    amount(&component["grams"], "component grams")?;
                }
            }
        }
        "entries" => {
            amount(&row["servings"], "servings")?;
            amount(&row["grams"], "grams")?;
        }
        _ => {
            amount(&row["water_ml"], "water_ml")?;
            if let Some(split) = row["meal_split"].as_object() {
                for (meal, share) in split {
                    amount(share, &format!("meal_split.{meal}"))?;
                }
            }
        }
    }
    Ok(())
}

/// One CLI mutation. See `apply_from`.
pub fn apply(db: &Connection, table: &str, op: &str, row: &Value) -> Result<Outcome, String> {
    apply_from(db, table, op, row, Origin::Cli)
}

/// One client or CLI mutation. Last writer wins by `updated_at`; an older write is ignored. A row
/// that could hurt a client (too big, a timestamp out of range, a number that isn't one) is an error.
pub fn apply_from(db: &Connection, table: &str, op: &str, row: &Value, origin: Origin) -> Result<Outcome, String> {
    if !matches!(table, "foods" | "entries" | "goals") {
        return Err(format!("{table:?} can't be written; use foods, entries or goals"));
    }
    if !matches!(op, "upsert" | "delete") {
        return Err(format!("unknown op {op:?}"));
    }
    let mut data = row.as_object().cloned().ok_or("row must be an object")?;
    if row.to_string().len() > MAX_ROW_BYTES {
        return Err("row is over 256 KB".to_string());
    }
    let mut id = data.get("id").and_then(Value::as_str).filter(|s| !s.is_empty() && s.len() <= 128)
        .ok_or("row needs an id")?.to_string();
    if table == "goals" && id != "current" {
        return Err("the goals row is id \"current\"".to_string());
    }
    // A write to a food merged into another (see merge_duplicate) lands on that food. The alias's
    // tombstone keeps the merge time: anything not newer is the duplicate's creation again (a
    // retry whose reply was lost), not an edit, so it changes nothing.
    let mut merged_at = None;
    if table == "foods" {
        let original = resolve_alias(db, &id);
        if original != id {
            merged_at = Some(get(db, "foods", &id)?.filter(|r| r.deleted).map_or(i64::MIN, |r| r.updated_at));
            id = original;
        }
    }
    let now = time::now_ms();
    let updated_at = timestamp(&data, "updated_at", origin, now)?.unwrap_or(now);
    if merged_at.is_some_and(|at| updated_at <= at) {
        return Ok(Outcome { applied: false, id });
    }
    for key in ["created_at", "logged_at"] {
        match timestamp(&data, key, origin, now)? {
            Some(ms) => data.insert(key.into(), json!(ms)),
            None => data.remove(key),
        };
    }
    let existing = get(db, table, &id)?;
    if existing.as_ref().is_some_and(|e| e.updated_at > updated_at) {
        return Ok(Outcome { applied: false, id });
    }
    data.insert("id".into(), json!(id));
    data.insert("updated_at".into(), json!(updated_at));
    data.remove("version");
    let was_live = existing.as_ref().is_some_and(|e| !e.deleted);

    if op == "delete" {
        let mut tomb = existing.as_ref().and_then(|e| e.data.as_object().cloned()).unwrap_or_default();
        tomb.insert("id".into(), json!(id));
        tomb.insert("updated_at".into(), json!(updated_at));
        tomb.insert("deleted".into(), json!(true));
        let tomb = Value::Object(tomb);
        if existing.as_ref().is_some_and(|e| e.deleted && e.data == tomb) {
            return Ok(Outcome { applied: false, id });
        }
        put(db, table, &tomb)?;
        if table == "foods" && was_live {
            recompute_dependents(db, &id)?;
        }
        return Ok(Outcome { applied: true, id });
    }

    let deleted = match data.get("deleted") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err("deleted must be true or false".to_string()),
    };
    data.insert("deleted".into(), json!(deleted));
    let mut value = Value::Object(data);
    if !deleted {
        check_amounts(table, &value)?;
    }
    match table {
        "foods" => {
            if !value["kind"].is_null() && !matches!(value["kind"].as_str(), Some("food" | "recipe" | "quick")) {
                return Err("kind must be food, recipe or quick".to_string());
            }
            normalize_food(&mut value);
            if merged_at.is_some() {
                // An edit through the alias, not a re-creation: the food keeps its own identity.
                if let (Some(e), Some(object)) = (&existing, value.as_object_mut()) {
                    for key in ["created_at", "source_ref"] {
                        match e.data.get(key) {
                            Some(v) => object.insert(key.into(), v.clone()),
                            None => object.remove(key),
                        };
                    }
                }
            }
            let source_ref = value["source_ref"].as_str().unwrap_or("").to_string();
            if existing.is_none() && !deleted && !source_ref.is_empty() {
                if let Some(original) = food_by_source_ref(db, &source_ref).filter(|o| *o != id) {
                    return merge_duplicate(db, &id, &original, &value);
                }
            }
            if value["kind"] == "recipe" && !deleted {
                compute_recipe(db, &mut value)?;
            }
        }
        "entries" => normalize_entry(db, &mut value),
        _ => {
            // The basis belongs to the server; clients only choose mode, plan and overrides.
            let stored = existing.as_ref().map(|e| e.data.clone()).unwrap_or_else(goals::default_row);
            value["basis"] = stored["basis"].clone();
            goals::fill(&mut value);
            goals::apply_targets(&mut value);
        }
    }
    if !deleted {
        check_amounts(table, &value)?;
    }
    if existing.as_ref().is_some_and(|e| e.data == value) {
        return Ok(Outcome { applied: false, id });
    }
    put(db, table, &value)?;
    if table == "foods" && was_live == deleted && existing.is_some() {
        // Deleted, or back from the dead: the recipes using it count it again, or stop counting it.
        recompute_dependents(db, &id)?;
    }
    Ok(Outcome { applied: true, id })
}

/// A new food duplicated `original` by source_ref: remember the alias, tombstone the duplicate so
/// the client drops it, and keep a favorite flag the client set.
fn merge_duplicate(db: &Connection, duplicate: &str, original: &str, incoming: &Value) -> Result<Outcome, String> {
    db.execute("INSERT OR REPLACE INTO food_aliases (alias, id) VALUES (?1, ?2)", params![duplicate, original]).map_err(|e| e.to_string())?;
    let at = incoming["updated_at"].as_i64().unwrap_or_else(time::now_ms);
    put(db, "foods", &json!({"id": duplicate, "deleted": true, "updated_at": at, "merged_into": original}))?;
    if incoming["favorite"] == true {
        if let Some(mut food) = live(db, "foods", original)? {
            if food["favorite"] != true {
                food["favorite"] = json!(true);
                food["updated_at"] = json!(at.max(food["updated_at"].as_i64().unwrap_or(0)));
                put(db, "foods", &food)?;
            }
        }
    }
    // Entries written under the duplicate's id point at the original from now on.
    let stale: Vec<String> = {
        let mut statement = db.prepare("SELECT id FROM entries WHERE food_id = ?1").map_err(|e| e.to_string())?;
        let ids = statement.query_map([duplicate], |r| r.get(0)).map_err(|e| e.to_string())?;
        ids.collect::<Result<_, _>>().map_err(|e| e.to_string())?
    };
    for entry_id in stale {
        if let Some(row) = get(db, "entries", &entry_id)? {
            let mut data = row.data;
            data["food_id"] = json!(original);
            put(db, "entries", &data)?;
        }
    }
    Ok(Outcome { applied: true, id: original.to_string() })
}

pub fn normalize_food(food: &mut Value) {
    if !food["kind"].is_string() {
        food["kind"] = json!("food");
    }
    food["nutrients"] = Value::Object(nutrients::clean(&food["nutrients"]));
    if !food["favorite"].is_boolean() {
        food["favorite"] = json!(false);
    }
    if !food["created_at"].is_i64() {
        food["created_at"] = food["updated_at"].clone();
    }
    if !food["portions"].is_array() {
        food["portions"] = json!([]);
    }
    if !food["serving"].is_object() {
        food["serving"] = json!({"amount": 1, "unit": "serving"});
    }
}

fn normalize_entry(db: &Connection, entry: &mut Value) {
    entry["nutrients"] = Value::Object(nutrients::clean(&entry["nutrients"]));
    if let Some(food_id) = entry["food_id"].as_str().map(str::to_string) {
        entry["food_id"] = json!(resolve_alias(db, &food_id));
    }
    let logged_at = entry["logged_at"].as_i64().unwrap_or_else(|| entry["updated_at"].as_i64().unwrap_or_else(time::now_ms));
    entry["logged_at"] = json!(logged_at);
    let day_ok = entry["day"].as_str().is_some_and(|d| {
        time::parse_day(d).map(time::format_day).as_deref() == Some(d) && ("2000".."2101").contains(&&d[..4])
    });
    if !day_ok {
        entry["day"] = json!(time::day_of(logged_at));
    }
    if !matches!(entry["meal"].as_str(), Some("breakfast" | "lunch" | "dinner" | "snack")) {
        entry["meal"] = json!(time::meal_at(logged_at));
    }
    if !entry["servings"].is_number() {
        entry["servings"] = json!(1);
    }
}

pub fn serving_grams(food: &Value) -> Option<f64> {
    food["serving"]["grams"].as_f64().filter(|g| *g > 0.0)
}

/// Totals for `servings` of each component food, divided over `recipe_servings`. Returns the
/// per-serving nutrients and grams per serving when every component's weight is known.
pub fn recipe_math(parts: &[(Value, f64)], recipe_servings: f64) -> (Value, Option<f64>) {
    let mut total = Map::new();
    let mut grams = Some(0.0);
    for (food, servings) in parts {
        nutrients::add_into(&mut total, &nutrients::scale(&food["nutrients"], *servings));
        grams = grams.zip(serving_grams(food)).map(|(sum, g)| sum + g * servings);
    }
    let per = recipe_servings.max(f64::MIN_POSITIVE);
    (nutrients::scale(&Value::Object(total), 1.0 / per), grams.filter(|g| *g > 0.0).map(|g| nutrients::round(g / per)))
}

/// Resolves each component's food (and grams to servings) and recomputes the recipe's nutrients.
/// A component whose food is gone (deleted, or never synced) stays in `components` but is left out
/// of the math, and the recipe says so with `partial: true` and `missing_food_ids`.
fn compute_recipe(db: &Connection, recipe: &mut Value) -> Result<(), String> {
    let components = match &recipe["components"] {
        Value::Null => Vec::new(),
        Value::Array(list) => list.clone(),
        _ => return Err("components must be a list".to_string()),
    };
    let mut parts = Vec::new();
    let mut resolved = Vec::new();
    let mut missing = Vec::new();
    for component in components {
        let food_id = component["food_id"].as_str().filter(|id| !id.is_empty()).ok_or("each recipe component needs a food_id")?;
        let food_id = resolve_alias(db, food_id);
        if recipe["id"] == food_id.as_str() {
            return Err("a recipe can't contain itself".to_string());
        }
        let (servings, grams) = (component["servings"].as_f64(), component["grams"].as_f64());
        let Some(food) = live(db, "foods", &food_id)? else {
            let mut kept = json!({"food_id": food_id});
            match (servings, grams) {
                (Some(s), _) => kept["servings"] = json!(s),
                (None, Some(g)) => kept["grams"] = json!(g),
                (None, None) => kept["servings"] = json!(1.0),
            }
            resolved.push(kept);
            missing.push(json!(food_id));
            continue;
        };
        let servings = match (servings, grams) {
            (Some(s), _) => s,
            (None, Some(g)) => g / serving_grams(&food).ok_or_else(|| format!("{} has no gram weight; give servings", food["name"]))?,
            (None, None) => 1.0,
        };
        resolved.push(json!({"food_id": food_id, "servings": nutrients::round(servings)}));
        parts.push((food, servings));
    }
    let recipe_servings = recipe["recipe_servings"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0);
    let (per_serving, grams) = recipe_math(&parts, recipe_servings);
    recipe["components"] = Value::Array(resolved);
    recipe["recipe_servings"] = json!(recipe_servings);
    recipe["nutrients"] = Value::Object(nutrients::clean(&per_serving));
    let mut serving = json!({"amount": 1, "unit": "serving"});
    if let Some(g) = grams.filter(|g| *g <= nutrients::MAX_AMOUNT) {
        serving["grams"] = json!(g);
    }
    recipe["serving"] = serving;
    recipe["source"] = json!("recipe");
    let object = recipe.as_object_mut().ok_or("a recipe must be an object")?;
    if missing.is_empty() {
        object.remove("partial");
        object.remove("missing_food_ids");
    } else {
        object.insert("partial".into(), json!(true));
        object.insert("missing_food_ids".into(), Value::Array(missing));
    }
    Ok(())
}

/// After a food is deleted (or comes back), recomputes the live recipes that use it, and the
/// recipes that use those. Like the goals recompute, this keeps each recipe's `updated_at`, so a
/// client's newer edit still wins; the new version is what tells clients.
fn recompute_dependents(db: &Connection, food_id: &str) -> Result<(), String> {
    let mut queue = vec![food_id.to_string()];
    let mut seen = std::collections::HashSet::new();
    while let Some(changed) = queue.pop() {
        if !seen.insert(changed.clone()) {
            continue;
        }
        let quoted = json!(changed).to_string();
        for recipe in select(db, "foods", "kind = 'recipe' AND instr(data, ?1) > 0", &[&quoted])? {
            let uses = recipe["components"].as_array().is_some_and(|list| list.iter().any(|c| c["food_id"] == changed.as_str()));
            let Some(id) = recipe["id"].as_str().filter(|_| uses).map(str::to_string) else { continue };
            let mut updated = recipe.clone();
            // A recipe that no longer computes keeps what it had; its next write reports why.
            if compute_recipe(db, &mut updated).is_err() || check_amounts("foods", &updated).is_err() || updated == recipe {
                continue;
            }
            put(db, "foods", &updated)?;
            queue.push(id);
        }
    }
    Ok(())
}

/// A food's portion as a label for entries: `container (170 g)`.
pub fn serving_label(food: &Value, servings: f64) -> String {
    let unit = food["serving"]["unit"].as_str().unwrap_or("serving");
    let amount = food["serving"]["amount"].as_f64().unwrap_or(1.0);
    let base = if amount == 1.0 { unit.to_string() } else { format!("{} {unit}", trim_number(amount)) };
    match serving_grams(food) {
        Some(g) if unit != "g" => format!("{base} ({} g)", trim_number(g)),
        _ => {
            let _ = servings;
            base
        }
    }
}

pub fn trim_number(x: f64) -> String {
    let rounded = (x * 100.0).round() / 100.0;
    if rounded.fract() == 0.0 { format!("{}", rounded as i64) } else { format!("{rounded}") }
}

/// An entry for `servings` of `food` (or `grams` of it, when its serving weight is known).
pub fn entry_for(food: &Value, servings: Option<f64>, grams: Option<f64>) -> Result<Value, String> {
    let per = serving_grams(food);
    let servings = match (servings, grams) {
        (Some(s), _) => s,
        (None, Some(g)) => g / per.ok_or_else(|| format!("{} has no gram weight; use --servings", food["name"].as_str().unwrap_or("this food")))?,
        (None, None) => 1.0,
    };
    if !(servings > 0.0 && servings.is_finite()) {
        return Err("servings must be positive".to_string());
    }
    let grams = grams.or(per.map(|g| g * servings));
    let mut entry = json!({
        "food_id": food["id"], "name": food["name"], "brand": food["brand"],
        "servings": nutrients::round(servings), "serving_label": serving_label(food, servings),
        "nutrients": nutrients::scale(&food["nutrients"], servings),
    });
    if let Some(g) = grams {
        entry["grams"] = json!(nutrients::round(g));
    }
    Ok(entry)
}

/// Scales an entry's snapshot to new servings or grams, as editing on the phone does.
pub fn rescale_entry(entry: &mut Value, servings: Option<f64>, grams: Option<f64>) -> Result<(), String> {
    let old_servings = entry["servings"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0);
    let old_grams = entry["grams"].as_f64().filter(|g| *g > 0.0);
    let factor = match (servings, grams) {
        (Some(s), _) => s / old_servings,
        (None, Some(g)) => g / old_grams.ok_or("this entry has no gram weight; use --servings")?,
        (None, None) => return Ok(()),
    };
    if !(factor > 0.0 && factor.is_finite()) {
        return Err("servings and grams must be positive".to_string());
    }
    entry["nutrients"] = nutrients::scale(&entry["nutrients"], factor);
    entry["servings"] = json!(nutrients::round(old_servings * factor));
    if let Some(g) = old_grams {
        entry["grams"] = json!(nutrients::round(g * factor));
    }
    Ok(())
}

/// Live rows of a table matching a WHERE clause, as data objects.
pub fn select(db: &Connection, table: &str, clause: &str, args: &[&dyn rusqlite::ToSql]) -> Result<Vec<Value>, String> {
    let table = check_table(table)?;
    let mut statement = db.prepare(&format!("SELECT data FROM {table} WHERE deleted = 0 AND {clause}")).map_err(|e| e.to_string())?;
    let rows = statement.query_map(args, |row| row.get::<_, String>(0)).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for row in rows {
        out.push(serde_json::from_str(&row.map_err(|e| e.to_string())?).map_err(|e| e.to_string())?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-09-21, a real clock time: writes are checked against 2020 to a day from now.
    const T: i64 = 1_790_000_000_000;

    fn upsert(db: &Connection, table: &str, row: Value) -> Outcome {
        apply(db, table, "upsert", &row).unwrap()
    }

    #[test]
    fn sync_returns_rows_past_a_version_with_tombstones() {
        let db = db::memory();
        upsert(&db, "foods", json!({"id": "a", "name": "Apple", "updated_at": T + 10, "nutrients": {"kcal": 95}}));
        let v1 = db::version(&db);
        upsert(&db, "entries", json!({"id": "e1", "day": "2026-11-08", "meal": "lunch", "name": "Apple", "updated_at": T + 11, "nutrients": {"kcal": 95}}));
        let full = sync(&db, 0).unwrap();
        assert_eq!(full["foods"].as_array().unwrap().len(), 1);
        assert_eq!(full["entries"].as_array().unwrap().len(), 1);
        let since = sync(&db, v1).unwrap();
        assert_eq!(since["foods"].as_array().unwrap().len(), 0);
        assert_eq!(since["entries"][0]["id"], "e1");
        apply(&db, "entries", "delete", &json!({"id": "e1", "updated_at": T + 12})).unwrap();
        let after = sync(&db, since["version"].as_i64().unwrap()).unwrap();
        assert_eq!(after["entries"][0]["deleted"], true);
        assert_eq!(after["entries"][0]["name"], "Apple");
        assert!(after["version"].as_i64().unwrap() > since["version"].as_i64().unwrap());
    }

    #[test]
    fn last_writer_wins_and_repeats_are_idempotent() {
        let db = db::memory();
        assert!(upsert(&db, "entries", json!({"id": "e", "name": "new", "servings": 2, "updated_at": T + 200, "day": "2026-11-08"})).applied);
        assert!(!upsert(&db, "entries", json!({"id": "e", "name": "old", "updated_at": T + 100, "day": "2026-11-08"})).applied);
        assert_eq!(live(&db, "entries", "e").unwrap().unwrap()["name"], "new");
        let v = db::version(&db);
        assert!(!upsert(&db, "entries", json!({"id": "e", "name": "new", "servings": 2, "updated_at": T + 200, "day": "2026-11-08"})).applied);
        assert_eq!(db::version(&db), v, "a repeat doesn't bump the version");
        // An old delete loses to a newer write, too.
        assert!(!apply(&db, "entries", "delete", &json!({"id": "e", "updated_at": T + 150})).unwrap().applied);
        assert!(apply(&db, "entries", "delete", &json!({"id": "e", "updated_at": T + 300})).unwrap().applied);
        assert!(live(&db, "entries", "e").unwrap().is_none());
        assert!(apply(&db, "health_days", "upsert", &json!({"id": "x"})).is_err());
    }

    #[test]
    fn foods_dedupe_by_source_ref() {
        let db = db::memory();
        upsert(&db, "foods", json!({"id": "first", "name": "Bananas, raw", "source_ref": "fdc:173944", "updated_at": T + 1}));
        let second = upsert(&db, "foods", json!({"id": "second", "name": "Bananas, raw", "source_ref": "fdc:173944", "favorite": true, "updated_at": T + 2}));
        assert_eq!(second.id, "first");
        assert_eq!(get(&db, "foods", "second").unwrap().unwrap().deleted, true);
        assert_eq!(live(&db, "foods", "first").unwrap().unwrap()["favorite"], true);
        let entry = upsert(&db, "entries", json!({"id": "e", "food_id": "second", "updated_at": T + 3, "day": "2026-11-08"}));
        assert!(entry.applied);
        assert_eq!(live(&db, "entries", "e").unwrap().unwrap()["food_id"], "first");
        // Later writes to the alias land on the original.
        upsert(&db, "foods", json!({"id": "second", "name": "Banana", "source_ref": "fdc:173944", "updated_at": T + 4}));
        assert_eq!(live(&db, "foods", "first").unwrap().unwrap()["name"], "Banana");
    }

    #[test]
    fn a_retried_duplicate_does_not_overwrite_the_food_it_merged_into() {
        let db = db::memory();
        let app = |op: &str, row: Value| apply_from(&db, "foods", op, &row, Origin::App).unwrap();
        // A is customized after it was created; B duplicates it by source_ref and merges.
        app("upsert", json!({"id": "a", "name": "Oats", "source_ref": "fdc:1", "created_at": T, "updated_at": T + 1,
                             "serving": {"amount": 1, "unit": "cup", "grams": 80}, "nutrients": {"kcal": 300}}));
        let b = json!({"id": "b", "name": "Oats, rolled", "source_ref": "fdc:1", "created_at": T + 5, "updated_at": T + 5,
                       "serving": {"amount": 100, "unit": "g", "grams": 100}, "nutrients": {"kcal": 380}});
        assert_eq!(app("upsert", b.clone()).id, "a");
        let merged = live(&db, "foods", "a").unwrap().unwrap();
        assert_eq!(merged["serving"]["grams"], json!(80));
        // The reply was lost and the client sends B again, unchanged: a no-op that still maps B to A.
        let version = db::version(&db);
        let retry = app("upsert", b.clone());
        assert_eq!((retry.applied, retry.id.as_str()), (false, "a"));
        assert_eq!(live(&db, "foods", "a").unwrap().unwrap(), merged);
        assert_eq!(db::version(&db), version);
        assert!(!app("delete", json!({"id": "b", "updated_at": T + 5})).applied, "a replayed delete is a no-op too");
        // A genuine later edit made through the alias applies to A, as an edit.
        let mut edit = b.clone();
        edit["name"] = json!("Oats, steel cut");
        edit["source_ref"] = json!("fdc:2");
        edit["updated_at"] = json!(T + 9);
        let edited = app("upsert", edit);
        assert_eq!((edited.applied, edited.id.as_str()), (true, "a"));
        let a = live(&db, "foods", "a").unwrap().unwrap();
        assert_eq!((a["name"].as_str(), a["source_ref"].as_str(), a["created_at"].as_i64()), (Some("Oats, steel cut"), Some("fdc:1"), Some(T)));
        assert!(get(&db, "foods", "b").unwrap().unwrap().deleted, "the alias stays a tombstone");
    }

    #[test]
    fn recipes_are_recomputed_on_the_server() {
        let db = db::memory();
        upsert(&db, "foods", json!({"id": "oats", "name": "Oats", "serving": {"amount": 1, "unit": "cup", "grams": 80},
                                     "nutrients": {"kcal": 300, "protein": 10, "fiber": 8}, "updated_at": T + 1}));
        upsert(&db, "foods", json!({"id": "milk", "name": "Milk", "serving": {"amount": 1, "unit": "cup", "grams": 244},
                                     "nutrients": {"kcal": 120, "protein": 8}, "updated_at": T + 1}));
        upsert(&db, "foods", json!({"id": "r", "kind": "recipe", "name": "Overnight oats", "recipe_servings": 2, "updated_at": T + 2,
                                     "nutrients": {"kcal": 1},
                                     "components": [{"food_id": "oats", "servings": 2}, {"food_id": "milk", "grams": 244}]}));
        let recipe = live(&db, "foods", "r").unwrap().unwrap();
        assert_eq!(recipe["nutrients"], json!({"kcal": 360.0, "protein": 14.0, "fiber": 8.0}));
        assert_eq!(recipe["serving"]["grams"], json!(202.0));
        assert_eq!(recipe["components"][1]["servings"], json!(1.0));
        let (per, grams) = recipe_math(&[(json!({"nutrients": {"kcal": 100}}), 3.0)], 4.0);
        assert_eq!((per, grams), (json!({"kcal": 75.0}), None));
    }

    #[test]
    fn a_deleted_ingredient_leaves_a_partial_recipe_that_still_takes_writes() {
        let db = db::memory();
        let app = |row: Value| apply_from(&db, "foods", "upsert", &row, Origin::App);
        upsert(&db, "foods", json!({"id": "oats", "name": "Oats", "nutrients": {"kcal": 300, "protein": 10}, "updated_at": T + 1}));
        upsert(&db, "foods", json!({"id": "milk", "name": "Milk", "serving": {"amount": 1, "unit": "cup", "grams": 244},
                                     "nutrients": {"kcal": 120, "protein": 8}, "updated_at": T + 1}));
        let recipe = json!({"id": "r", "kind": "recipe", "name": "Overnight oats", "updated_at": T + 2,
                            "components": [{"food_id": "oats", "servings": 1}, {"food_id": "milk", "grams": 244}]});
        app(recipe.clone()).unwrap();
        upsert(&db, "foods", json!({"id": "bowl", "kind": "recipe", "name": "Oats bowl", "updated_at": T + 3,
                                     "components": [{"food_id": "r", "servings": 2}]}));
        assert_eq!(live(&db, "foods", "bowl").unwrap().unwrap()["nutrients"]["kcal"], json!(840.0));

        // Deleting the milk recomputes the recipe, and the recipe that uses it, keeping updated_at.
        apply_from(&db, "foods", "delete", &json!({"id": "milk", "updated_at": T + 4}), Origin::App).unwrap();
        let r = live(&db, "foods", "r").unwrap().unwrap();
        assert_eq!(r["nutrients"], json!({"kcal": 300.0, "protein": 10.0}));
        assert_eq!((r["partial"].clone(), r["missing_food_ids"].clone()), (json!(true), json!(["milk"])));
        assert_eq!(r["components"][1], json!({"food_id": "milk", "servings": 1.0}), "the deleted ingredient stays listed");
        assert_eq!(r["updated_at"], json!(T + 2));
        assert_eq!(live(&db, "foods", "bowl").unwrap().unwrap()["nutrients"]["kcal"], json!(600.0));

        // Renaming and favoriting it still work, from the app and from the CLI.
        let mut renamed = recipe.clone();
        renamed["name"] = json!("Oats, no milk");
        renamed["updated_at"] = json!(T + 5);
        assert!(app(renamed).unwrap().applied);
        let mut fav = live(&db, "foods", "r").unwrap().unwrap();
        fav["favorite"] = json!(true);
        fav["updated_at"] = json!(T + 6);
        assert!(apply(&db, "foods", "upsert", &fav).unwrap().applied);
        let r = live(&db, "foods", "r").unwrap().unwrap();
        assert_eq!((r["name"].as_str(), r["favorite"].as_bool(), r["partial"].as_bool()), (Some("Oats, no milk"), Some(true), Some(true)));

        // A recipe whose every ingredient is gone is empty, not an error.
        apply(&db, "foods", "delete", &json!({"id": "oats", "updated_at": T + 7})).unwrap();
        let r = live(&db, "foods", "r").unwrap().unwrap();
        assert_eq!((r["nutrients"].clone(), r["missing_food_ids"].clone()), (json!({}), json!(["oats", "milk"])));

        // Bringing the milk back heals it.
        upsert(&db, "foods", json!({"id": "milk", "name": "Milk", "serving": {"amount": 1, "unit": "cup", "grams": 244},
                                     "nutrients": {"kcal": 120, "protein": 8}, "updated_at": T + 8}));
        let r = live(&db, "foods", "r").unwrap().unwrap();
        assert_eq!(r["nutrients"]["kcal"], json!(120.0));
        assert_eq!(r["missing_food_ids"], json!(["oats"]));

        // Malformed recipes are still rejected.
        let bad = |components: Value| app(json!({"id": "x", "kind": "recipe", "name": "X", "updated_at": T + 9, "components": components}));
        assert!(bad(json!("oats")).is_err());
        assert!(bad(json!([{"servings": 1}])).is_err());
        assert!(bad(json!([{"food_id": "milk", "servings": -1}])).is_err());
        assert!(bad(json!([{"food_id": "milk", "servings": "2"}])).is_err());
        assert!(bad(json!([{"food_id": "x", "servings": 1}])).is_err(), "a recipe can't contain itself");
        assert!(bad(json!([{"food_id": "milk", "servings": 2}])).is_ok());
    }

    #[test]
    fn timestamps_out_of_range_are_rejected_from_the_app_and_clamped_from_the_cli() {
        let db = db::memory();
        let app = |table: &str, row: Value| apply_from(&db, table, "upsert", &row, Origin::App);
        for bad in [json!(i64::MAX), json!(u64::MAX), json!(1e300), json!(-1), json!(0), json!(1_500_000_000_000_i64),
                    json!(time::now_ms() + 2 * DAY_MS), json!("1790000000000"), json!(1.79e12 + 0.5), json!(true)] {
            let error = app("entries", json!({"id": "e", "day": "2026-11-08", "updated_at": bad})).unwrap_err();
            assert!(error.contains("updated_at"), "{bad}: {error}");
            if bad != json!(0) {
                assert!(app("entries", json!({"id": "e", "day": "2026-11-08", "updated_at": T, "logged_at": bad})).is_err());
                assert!(app("foods", json!({"id": "f", "name": "F", "updated_at": T, "created_at": bad})).is_err());
            }
        }
        assert!(get(&db, "entries", "e").unwrap().is_none() && get(&db, "foods", "f").unwrap().is_none());
        // Whole floats are fine, and 0 means unknown for created_at and logged_at.
        app("foods", json!({"id": "f", "name": "F", "updated_at": 1.79e12, "created_at": 0})).unwrap();
        assert_eq!(live(&db, "foods", "f").unwrap().unwrap()["created_at"], json!(1_790_000_000_000_i64));
        app("entries", json!({"id": "e", "day": "2026-11-08", "updated_at": T, "logged_at": 0})).unwrap();
        assert_eq!(live(&db, "entries", "e").unwrap().unwrap()["logged_at"], json!(T));
        // The CLI's bad clock becomes now.
        let before = time::now_ms();
        apply(&db, "entries", "upsert", &json!({"id": "c", "day": "2026-11-08", "updated_at": i64::MAX, "logged_at": 1e300})).unwrap();
        let row = get(&db, "entries", "c").unwrap().unwrap();
        assert!(row.updated_at >= before && row.updated_at <= time::now_ms());
        assert!(row.data["logged_at"].as_i64().is_some_and(|t| t >= before));
    }

    #[test]
    fn rows_that_could_hurt_a_client_are_rejected() {
        let db = db::memory();
        let app = |table: &str, row: Value| apply_from(&db, table, "upsert", &row, Origin::App);
        let entry = |extra: Value| {
            let mut row = json!({"id": "e", "day": "2026-11-08", "updated_at": T});
            row.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            row
        };
        assert!(app("entries", json!(["not", "an", "object"])).is_err());
        assert!(app("entries", json!("text")).is_err());
        assert!(app("entries", entry(json!({"servings": "2"}))).is_err());
        assert!(app("entries", entry(json!({"servings": -2}))).is_err());
        assert!(app("entries", entry(json!({"grams": 1e300}))).is_err());
        assert!(app("entries", entry(json!({"deleted": "yes"}))).is_err());
        assert!(app("entries", entry(json!({"note": "x".repeat(MAX_ROW_BYTES)}))).is_err());
        assert!(app("foods", json!({"id": "f", "name": "F", "updated_at": T, "serving": {"amount": 1, "grams": "lots"}})).is_err());
        assert!(app("foods", json!({"id": "f", "name": "F", "updated_at": T, "portions": [{"label": "cup", "grams": -5}]})).is_err());
        assert!(app("foods", json!({"id": "f", "name": "F", "updated_at": T, "portions": ["cup"]})).is_err());
        assert!(app("foods", json!({"id": "f", "name": "F", "updated_at": T, "kind": "drink"})).is_err());
        assert!(app("goals", json!({"id": "current", "updated_at": T, "water_ml": 1e300})).is_err());
        assert!(app("goals", json!({"id": "current", "updated_at": T, "meal_split": {"lunch": "most"}})).is_err());
        assert_eq!(db::version(&db), 0, "nothing was written");
        // Nutrients stay lenient: nonsense values are dropped, so unknown stays unknown.
        app("entries", entry(json!({"servings": null, "note": "x".repeat(1000), "nutrients": {"kcal": 1e300, "protein": 5}}))).unwrap();
        let saved = live(&db, "entries", "e").unwrap().unwrap();
        assert_eq!((saved["nutrients"].clone(), saved["servings"].clone()), (json!({"protein": 5.0}), json!(1)));
        // A day that doesn't exist comes from logged_at instead.
        app("entries", json!({"id": "d", "day": "2026-02-31", "logged_at": T, "updated_at": T})).unwrap();
        assert_eq!(live(&db, "entries", "d").unwrap().unwrap()["day"], json!(time::day_of(T)));
    }

    #[test]
    fn servings_and_grams_scale_entries() {
        let food = json!({"id": "y", "name": "Greek yogurt", "brand": "Fage", "serving": {"amount": 1, "unit": "container", "grams": 170},
                          "nutrients": {"kcal": 90, "protein": 18}});
        let entry = entry_for(&food, Some(1.5), None).unwrap();
        assert_eq!(entry["nutrients"], json!({"kcal": 135.0, "protein": 27.0}));
        assert_eq!(entry["grams"], json!(255.0));
        assert_eq!(entry["serving_label"], "container (170 g)");
        let mut by_grams = entry_for(&food, None, Some(85.0)).unwrap();
        assert_eq!(by_grams["servings"], json!(0.5));
        rescale_entry(&mut by_grams, Some(2.0), None).unwrap();
        assert_eq!(by_grams["nutrients"]["kcal"], json!(180.0));
        assert_eq!(by_grams["grams"], json!(340.0));
        rescale_entry(&mut by_grams, None, Some(170.0)).unwrap();
        assert_eq!(by_grams["nutrients"]["protein"], json!(18.0));
        let no_weight = json!({"name": "Bar", "serving": {"amount": 1, "unit": "bar"}, "nutrients": {"kcal": 200}});
        assert!(entry_for(&no_weight, None, Some(30.0)).is_err());
        assert_eq!(normal_barcode("0049000028911"), "49000028911");
    }
}
