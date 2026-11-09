//! What the app and the CLI can do, shared by the HTTP side and the socket. Network calls to Open
//! Food Facts happen outside the database lock.

use crate::db::State;
use crate::{catalog, db, goals, nutrients, off, store, time};
use rusqlite::Connection;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

// MARK: Foods

/// Saves an unsaved Food (a catalog or OFF result), or returns the food that already has its
/// source_ref.
pub fn save_food(db: &Connection, food: &Value) -> Result<Value, String> {
    if let Some(id) = food["id"].as_str() {
        if let Some(existing) = store::live(db, "foods", id)? {
            return Ok(existing);
        }
    }
    if let Some(source_ref) = food["source_ref"].as_str().filter(|s| !s.is_empty()) {
        if let Some(existing) = store::select(db, "foods", "source_ref = ?1", &[&source_ref])?.into_iter().next() {
            return Ok(existing);
        }
    }
    let mut food = food.clone();
    let now = time::now_ms();
    food["id"] = json!(db::uuid());
    food["created_at"] = json!(now);
    food["updated_at"] = json!(now);
    for key in ["category", "dataset"] {
        if let Some(o) = food.as_object_mut() { o.remove(key); }
    }
    let outcome = store::apply(db, "foods", "upsert", &food)?;
    store::live(db, "foods", &outcome.id)?.ok_or_else(|| "food vanished".to_string())
}

/// An id, a unique prefix of one (4+ characters), or for foods an alias.
pub fn resolve_id(db: &Connection, table: &str, text: &str) -> Result<String, String> {
    if store::live(db, table, text)?.is_some() {
        return Ok(text.to_string());
    }
    if table == "foods" {
        if let Ok(id) = db.query_row("SELECT id FROM food_aliases WHERE alias = ?1", [text], |r| r.get::<_, String>(0)) {
            return Ok(id);
        }
    }
    if text.len() >= 4 {
        let like = format!("{}%", text.replace(['%', '_'], ""));
        let mut statement = db.prepare(&format!("SELECT id FROM {table} WHERE deleted = 0 AND id LIKE ?1 LIMIT 2")).map_err(|e| e.to_string())?;
        let ids: Vec<String> = statement.query_map([like], |r| r.get(0)).map_err(|e| e.to_string())?.filter_map(Result::ok).collect();
        if ids.len() == 1 {
            return Ok(ids[0].clone());
        }
        if ids.len() > 1 {
            return Err(format!("{text} matches more than one {table} row; give more of the id"));
        }
    }
    Err(format!("no {} with id {text}", if table == "foods" { "food" } else { "entry" }))
}

/// An id, `fdc:N`, `off:CODE` or any stored source_ref to a saved food.
fn food_ref(db: &Connection, text: &str) -> Result<Value, String> {
    if let Some(found) = store::select(db, "foods", "source_ref = ?1", &[&text])?.into_iter().next() {
        return Ok(found);
    }
    if let Some(code) = text.strip_prefix("fdc:") {
        return save_food(db, &catalog::to_food(&catalog::resolve(db, code)?));
    }
    if let Some(code) = text.strip_prefix("off:") {
        if let off::Cached::Hit(food) = off::cached(db, code, time::now_ms())? {
            return save_food(db, &food);
        }
        return Err(format!("{text} isn't saved; look it up with `food barcode {code}` first"));
    }
    let id = resolve_id(db, "foods", text)?;
    store::live(db, "foods", &id)?.ok_or_else(|| format!("no food {text}"))
}

fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_lowercase).collect()
}

/// Log counts per food, for ranking.
fn log_counts(db: &Connection) -> Result<HashMap<String, i64>, String> {
    let mut statement = db
        .prepare_cached("SELECT food_id, count(*) FROM entries WHERE deleted = 0 AND food_id IS NOT NULL GROUP BY 1")
        .map_err(|e| e.to_string())?;
    let rows = statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))).map_err(|e| e.to_string())?;
    Ok(rows.filter_map(Result::ok).collect())
}

pub fn own_foods(db: &Connection, text: &str, limit: usize) -> Result<Vec<Value>, String> {
    let wanted = words(text);
    let counts = log_counts(db)?;
    let mut found: Vec<(bool, i64, Value)> = store::select(db, "foods", "1", &[])?
        .into_iter()
        .filter(|f| {
            let hay = format!("{} {}", f["name"].as_str().unwrap_or(""), f["brand"].as_str().unwrap_or("")).to_lowercase();
            wanted.iter().all(|w| hay.contains(w.trim_end_matches('s')))
        })
        .map(|f| (f["favorite"] == true, counts.get(f["id"].as_str().unwrap_or("")).copied().unwrap_or(0), f))
        .collect();
    found.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
    Ok(found.into_iter().take(limit).map(|(_, n, mut f)| { f["times_logged"] = json!(n); f }).collect())
}

/// `GET /v1/search`: the user's foods first (favorites, then most logged), then USDA, then OFF.
pub fn search(state: &State, text: &str, limit: usize, with_off: bool) -> Result<Value, String> {
    let limit = limit.clamp(1, 100);
    let remote = (with_off && text.trim().len() >= 3).then(|| {
        let text = text.to_string();
        std::thread::spawn(move || off::search(&text, 10, Duration::from_millis(1500)))
    });
    let (mut results, mut seen) = {
        let db = state.lock();
        let own = own_foods(&db, text, limit)?;
        let mut seen: HashSet<String> = own.iter().filter_map(|f| f["source_ref"].as_str().map(str::to_string)).collect();
        let mut results = own;
        for item in catalog::search(&db, text, limit)? {
            let food = catalog::to_food(&item);
            if seen.insert(food["source_ref"].as_str().unwrap_or("").to_string()) {
                results.push(food);
            }
        }
        (results, seen)
    };
    let mut off_results = Vec::new();
    if let Some(handle) = remote {
        for food in handle.join().unwrap_or_default() {
            if seen.insert(food["source_ref"].as_str().unwrap_or("").to_string()) {
                off_results.push(food);
            }
        }
    }
    // OFF fills what's left, and keeps a fifth of the list even when the catalog fills it: those
    // are the branded foods.
    let room = limit.saturating_sub(results.len()).max((limit / 5).max(1)).min(off_results.len());
    results.truncate(limit - room);
    results.extend(off_results.into_iter().take(room));
    Ok(json!({"results": results}))
}

/// `GET /v1/barcode/{code}`: the user's foods, then the OFF cache, then OFF. A found food is saved.
pub fn barcode(state: &State, code: &str) -> Result<Option<Value>, String> {
    lookup_barcode(state, code, true)
}

/// The same lookup, saving a found product as a food only with `save`. Without it only the OFF
/// cache (not synced) is written, and `{"food": "off:<code>"}` logs the product later.
pub fn lookup_barcode(state: &State, code: &str, save: bool) -> Result<Option<Value>, String> {
    let code: String = code.chars().filter(char::is_ascii_digit).collect();
    if code.len() < 6 || code.len() > 14 {
        return Err("a barcode is 6 to 14 digits".to_string());
    }
    let now = time::now_ms();
    {
        let db = state.lock();
        let normal = store::normal_barcode(&code);
        if let Some(found) = store::select(&db, "foods", "barcode = ?1", &[&normal])?.into_iter().next() {
            return Ok(Some(found));
        }
        match off::cached(&db, &code, now)? {
            off::Cached::Miss => return Ok(None),
            off::Cached::Hit(food) if !save => return Ok(Some(food)),
            off::Cached::Hit(food) => {
                drop(db);
                return state.write(|db| save_food(db, &food)).map(Some);
            }
            off::Cached::Unknown => {}
        }
    }
    let fetched = off::fetch(&code)?;
    state.write(|db| {
        off::remember(db, &code, fetched.as_ref(), now)?;
        if !save {
            return Ok(fetched.clone());
        }
        fetched.as_ref().map(|food| save_food(db, food)).transpose()
    })
}

/// `GET /v1/suggest`: recents, frequent foods for this time of day, and yesterday's same meal.
pub fn suggest(db: &Connection, meal: Option<&str>, day: Option<&str>) -> Result<Value, String> {
    let now = time::now_ms();
    let meal = meal.filter(|m| matches!(*m, "breakfast" | "lunch" | "dinner" | "snack")).unwrap_or(time::meal_at(now));
    let day = day.map(str::to_string).unwrap_or_else(time::today);
    let since = time::add_days(&day, -90).unwrap_or_default();
    let entries = store::select(db, "entries", "day >= ?1 ORDER BY logged_at DESC", &[&since])?;
    let foods: HashMap<String, Value> = store::select(db, "foods", "1", &[])?
        .into_iter()
        .filter_map(|f| f["id"].as_str().map(|id| (id.to_string(), f.clone())))
        .collect();
    let mut recents = Vec::new();
    let mut seen = HashSet::new();
    let now_minutes = time::local_minutes(now) as f64;
    let mut scores: HashMap<String, f64> = HashMap::new();
    for entry in &entries {
        let Some(id) = entry["food_id"].as_str() else { continue };
        if !foods.contains_key(id) {
            continue;
        }
        if seen.insert(id.to_string()) && recents.len() < 20 {
            recents.push(foods[id].clone());
        }
        let logged = entry["logged_at"].as_i64().unwrap_or(now);
        let minutes = time::local_minutes(logged) as f64;
        let gap = (minutes - now_minutes).abs().min(1440.0 - (minutes - now_minutes).abs());
        let clock = (-(gap / 120.0).powi(2) / 2.0).exp();
        let same_meal = if entry["meal"] == meal { 1.0 } else { 0.0 };
        let age_days = (now - logged).max(0) as f64 / 86_400_000.0;
        *scores.entry(id.to_string()).or_default() += (0.6 * same_meal + 0.4 * clock) * 0.5_f64.powf(age_days / 30.0);
    }
    let mut ranked: Vec<(String, f64)> = scores.into_iter().collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1));
    let frequent: Vec<Value> = ranked.into_iter().take(20).map(|(id, _)| foods[&id].clone()).collect();
    let yesterday = time::add_days(&day, -1).unwrap_or_default();
    let last = store::select(db, "entries", "day = ?1 AND meal = ?2 ORDER BY logged_at", &[&yesterday, &meal])?;
    Ok(json!({"meal": meal, "recents": recents, "frequent": frequent, "yesterday": last}))
}

// MARK: Logging (the CLI)

fn custom_food_kind(nutrients: &Value) -> &'static str {
    let macros_only = nutrients.as_object().is_some_and(|m| m.keys().all(|k| matches!(k.as_str(), "kcal" | "protein" | "carbs" | "fat")));
    if macros_only { "quick" } else { "food" }
}

fn slug(text: &str) -> String {
    words(text).join("-")
}

/// One item of `food log`: {catalog | food | name + nutrients, grams?, servings?, meal?, date?, note?}.
fn build_entry(db: &Connection, item: &Value, now: i64) -> Result<(Value, Option<Value>), String> {
    let servings = item["servings"].as_f64();
    let grams = item["grams"].as_f64();
    let (mut entry, food) = if let Some(query) = item["catalog"].as_str().or_else(|| item["catalog"].as_i64().map(|_| "")) {
        let query = if query.is_empty() { item["catalog"].to_string() } else { query.to_string() };
        if servings.is_none() && grams.is_none() {
            return Err(format!("catalog item {query:?} needs grams or servings"));
        }
        let food = save_food(db, &catalog::to_food(&catalog::resolve(db, &query)?))?;
        (store::entry_for(&food, servings, grams)?, food)
    } else if let Some(reference) = item["food"].as_str() {
        let food = food_ref(db, reference)?;
        (store::entry_for(&food, servings, grams)?, food)
    } else {
        let name = item["name"].as_str().map(str::trim).filter(|n| !n.is_empty()).ok_or("each item needs catalog, food, or name")?;
        let per_serving = Value::Object(nutrients::clean(&item["nutrients"]));
        if per_serving.get("kcal").is_none() {
            return Err(format!("{name}: give at least kcal, or use --catalog"));
        }
        let count = servings.unwrap_or(1.0);
        if !(count > 0.0) {
            return Err("servings must be positive".to_string());
        }
        // Saved as an agent food, so the phone can log it again in one tap.
        let brand = item["brand"].as_str().filter(|b| !b.is_empty());
        let source_ref = format!("agent:{}", slug(&format!("{name} {}", brand.unwrap_or(""))));
        let mut serving = json!({"amount": 1, "unit": item["serving_unit"].as_str().unwrap_or("serving")});
        if let Some(g) = grams {
            serving["grams"] = json!(nutrients::round(g / count));
        }
        let existing = store::select(db, "foods", "source_ref = ?1", &[&source_ref])?.into_iter().next();
        let mut food = existing.clone().unwrap_or_else(|| json!({"id": db::uuid(), "created_at": now, "favorite": false}));
        food["kind"] = json!(custom_food_kind(&per_serving));
        food["name"] = json!(name);
        food["brand"] = json!(brand);
        food["serving"] = serving;
        food["portions"] = json!([]);
        food["nutrients"] = per_serving;
        food["source"] = json!("agent");
        food["source_ref"] = json!(source_ref);
        food["updated_at"] = json!(now.max(existing.as_ref().and_then(|e| e["updated_at"].as_i64()).unwrap_or(0) + 1));
        let id = store::apply(db, "foods", "upsert", &food)?.id;
        let food = store::live(db, "foods", &id)?.ok_or("food vanished")?;
        let mut entry = store::entry_for(&food, Some(count), None)?;
        if let Some(g) = grams {
            entry["grams"] = json!(g);
        }
        (entry, food)
    };
    let day = match item["date"].as_str() {
        Some(d) => time::resolve_day(d)?,
        None => time::today(),
    };
    let meal = match item["meal"].as_str() {
        Some(m @ ("breakfast" | "lunch" | "dinner" | "snack")) => m.to_string(),
        Some(other) => return Err(format!("meal must be breakfast, lunch, dinner or snack, not {other:?}")),
        None => time::meal_at(now).to_string(),
    };
    entry["id"] = json!(db::uuid());
    entry["day"] = json!(day);
    entry["meal"] = json!(meal);
    entry["logged_at"] = json!(now);
    entry["note"] = item["note"].clone();
    entry["source"] = json!(item["source"].as_str().unwrap_or("agent"));
    entry["updated_at"] = json!(now);
    entry["deleted"] = json!(false);
    Ok((entry, Some(food)))
}

/// `food log` (and `--json` batches): every item, or none of them.
pub fn log(state: &State, items: &[Value]) -> Result<Value, String> {
    if items.is_empty() {
        return Err("nothing to log".to_string());
    }
    state.write(|db| log_items(db, items))
}

/// Exactly what `log` would return for these items, with nothing written (AI logging's draft).
pub fn preview(state: &State, items: &[Value]) -> Result<Value, String> {
    if items.is_empty() {
        return Err("nothing to log".to_string());
    }
    state.dry_run(|db| log_items(db, items))
}

fn log_items(db: &Connection, items: &[Value]) -> Result<Value, String> {
    let now = time::now_ms();
    let mut logged = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let (entry, food) = build_entry(db, item, now + i as i64).map_err(|e| format!("item {}: {e}", i + 1))?;
        store::apply(db, "entries", "upsert", &entry)?;
        let saved = store::live(db, "entries", entry["id"].as_str().unwrap())?.unwrap_or(entry);
        logged.push(json!({"entry": saved, "matched": food.map(|f| json!({"id": f["id"], "name": f["name"], "source_ref": f["source_ref"]}))}));
    }
    let day = logged[0]["entry"]["day"].as_str().unwrap_or("").to_string();
    Ok(json!({"logged": logged, "today": day_summary(db, &day)?}))
}

pub fn edit(state: &State, id: &str, changes: &Value) -> Result<Value, String> {
    state.write(|db| {
        let id = resolve_id(db, "entries", id)?;
        let mut entry = store::live(db, "entries", &id)?.ok_or("entry vanished")?;
        store::rescale_entry(&mut entry, changes["servings"].as_f64(), changes["grams"].as_f64())?;
        if let Some(meal) = changes["meal"].as_str() {
            if !matches!(meal, "breakfast" | "lunch" | "dinner" | "snack") {
                return Err(format!("bad meal {meal:?}"));
            }
            entry["meal"] = json!(meal);
        }
        if let Some(day) = changes["date"].as_str() {
            entry["day"] = json!(time::resolve_day(day)?);
        }
        for key in ["name", "note"] {
            if let Some(text) = changes[key].as_str() {
                entry[key] = json!(text);
            }
        }
        if let Some(extra) = changes["nutrients"].as_object() {
            for (key, value) in nutrients::clean(&Value::Object(extra.clone())) {
                entry["nutrients"][key] = value;
            }
        }
        let previous = entry["updated_at"].as_i64().unwrap_or(0);
        entry["updated_at"] = json!(time::now_ms().max(previous + 1));
        store::apply(db, "entries", "upsert", &entry)?;
        store::live(db, "entries", &id)?.ok_or_else(|| "entry vanished".to_string())
    })
}

pub fn remove(state: &State, table: &str, ids: &[String]) -> Result<Value, String> {
    state.write(|db| {
        let mut removed = Vec::new();
        for text in ids {
            let id = resolve_id(db, table, text)?;
            let row = store::get(db, table, &id)?.ok_or("row vanished")?;
            store::apply(db, table, "delete", &json!({"id": id, "updated_at": time::now_ms().max(row.updated_at + 1)}))?;
            removed.push(json!({"id": id, "name": row.data["name"]}));
        }
        Ok(json!({"removed": removed}))
    })
}

// MARK: Reading the log

fn sum(entries: &[Value]) -> (Map<String, Value>, HashMap<String, usize>) {
    let mut total = Map::new();
    let mut known = HashMap::new();
    for entry in entries {
        nutrients::add_into(&mut total, &entry["nutrients"]);
        if let Some(map) = entry["nutrients"].as_object() {
            for key in map.keys() {
                *known.entry(key.clone()).or_default() += 1;
            }
        }
    }
    (total, known)
}

pub fn day_summary(db: &Connection, day: &str) -> Result<Value, String> {
    let goals = goals::current(db)?;
    let targets = &goals["targets"];
    let limits: Vec<String> = goals["limits"].as_array().map(|l| l.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
    let entries = store::select(db, "entries", "day = ?1 ORDER BY logged_at", &[&day])?;
    let (total, known) = sum(&entries);
    let mut meals = Map::new();
    for meal in ["breakfast", "lunch", "dinner", "snack"] {
        let list: Vec<Value> = entries.iter().filter(|e| e["meal"] == meal).cloned().collect();
        let (meal_total, _) = sum(&list);
        meals.insert(meal.into(), json!({"entries": list, "totals": meal_total}));
    }
    let mut remaining = Map::new();
    for key in ["kcal", "protein", "carbs", "fat", "fiber"] {
        if let Some(target) = targets[key].as_f64() {
            remaining.insert(key.into(), json!((target - total.get(key).and_then(Value::as_f64).unwrap_or(0.0)).round()));
        }
    }
    let mut gaps = Vec::new();
    let mut over = Vec::new();
    let mut no_data = Vec::new();
    for n in nutrients::ALL {
        let Some(target) = targets[n.key].as_f64().filter(|t| *t > 0.0) else { continue };
        let value = total.get(n.key).and_then(Value::as_f64).unwrap_or(0.0);
        let row = json!({"key": n.key, "name": n.name, "unit": n.unit, "total": nutrients::round(value), "target": target,
                         "pct": (value / target * 100.0).round(), "entries_with_data": known.get(n.key).copied().unwrap_or(0)});
        if limits.iter().any(|l| l == n.key) {
            if value > target { over.push(row); }
        } else if !matches!(n.key, "kcal" | "protein" | "carbs" | "fat" | "water") && value < target {
            // Unknown isn't zero: a nutrient no entry reports is listed apart, not as a gap.
            if known.contains_key(n.key) { gaps.push(row) } else if !entries.is_empty() { no_data.push(json!(n.key)) }
        }
    }
    gaps.sort_by(|a, b| a["pct"].as_f64().unwrap_or(0.0).total_cmp(&b["pct"].as_f64().unwrap_or(0.0)));
    let health = store::live(db, "health_days", day)?;
    Ok(json!({
        "date": day, "entry_count": entries.len(), "totals": total, "targets": targets, "remaining": remaining,
        "meals": meals, "gaps": gaps, "no_data": no_data, "over_limits": over, "goals": {"mode": goals["mode"], "plan": goals["plan"]},
        "health": health,
    }))
}

pub fn entries(db: &Connection, from: &str, to: &str) -> Result<Value, String> {
    Ok(json!({"from": from, "to": to, "entries": store::select(db, "entries", "day >= ?1 AND day <= ?2 ORDER BY day, logged_at", &[&from, &to])?}))
}

pub fn report(db: &Connection, days: i64) -> Result<Value, String> {
    let days = days.clamp(1, 400);
    let today = time::today();
    let from = time::add_days(&today, -(days - 1)).unwrap_or_default();
    let goals = goals::current(db)?;
    let targets = goals["targets"].clone();
    let all = store::select(db, "entries", "day >= ?1 AND day <= ?2 ORDER BY day", &[&from, &today])?;
    let health: HashMap<String, Value> = store::select(db, "health_days", "day >= ?1", &[&from])?
        .into_iter().filter_map(|h| h["day"].as_str().map(|d| (d.to_string(), h.clone()))).collect();
    let mut per_day = Vec::new();
    for i in 0..days {
        let day = time::add_days(&from, i).unwrap_or_default();
        let list: Vec<Value> = all.iter().filter(|e| e["day"] == day.as_str()).cloned().collect();
        let (total, _) = sum(&list);
        per_day.push(json!({"day": day, "entries": list.len(), "totals": total, "partial": day == today,
                            "health": health.get(&day).cloned()}));
    }
    // Averages use logged days before today; today is still going.
    let mut complete: Vec<&Value> = per_day.iter().filter(|d| d["entries"].as_u64() > Some(0) && d["partial"] == false).collect();
    let includes_today = complete.is_empty();
    if includes_today {
        complete = per_day.iter().filter(|d| d["entries"].as_u64() > Some(0)).collect();
    }
    // Each nutrient is averaged over the days that have data for it: a day whose entries never
    // mention iron says nothing about iron, so it isn't a zero.
    let mut averages = Map::new();
    let mut coverage = Map::new();
    for nutrient in nutrients::ALL {
        let known: Vec<f64> = complete.iter().filter_map(|d| d["totals"].get(nutrient.key).and_then(Value::as_f64)).collect();
        if !known.is_empty() {
            averages.insert(nutrient.key.into(), json!(nutrients::round(known.iter().sum::<f64>() / known.len() as f64)));
            coverage.insert(nutrient.key.into(), json!(known.len()));
        }
    }
    // Shortfalls and limits only count a nutrient known on at least half the logged days.
    let enough = |key: &str| coverage.get(key).and_then(Value::as_u64).unwrap_or(0) as usize * 2 >= complete.len().max(1);
    let kcal_target = targets["kcal"].as_f64();
    let protein_target = targets["protein"].as_f64();
    let on_kcal = complete.iter().filter(|d| kcal_target.is_some_and(|t| (d["totals"]["kcal"].as_f64().unwrap_or(0.0) - t).abs() <= t * 0.1)).count();
    let on_protein = complete.iter().filter(|d| protein_target.is_some_and(|t| d["totals"]["protein"].as_f64().unwrap_or(0.0) >= t * 0.9)).count();
    let limits: Vec<&str> = goals["limits"].as_array().map(|l| l.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    let mut weakest: Vec<Value> = nutrients::ALL
        .iter()
        .filter(|n| !limits.contains(&n.key) && !matches!(n.key, "kcal" | "protein" | "carbs" | "fat" | "water"))
        .filter_map(|n| {
            let target = targets[n.key].as_f64().filter(|t| *t > 0.0)?;
            let average = averages.get(n.key).and_then(Value::as_f64).filter(|_| enough(n.key))?;
            Some(json!({"key": n.key, "name": n.name, "unit": n.unit, "avg": average, "target": target, "pct": (average / target * 100.0).round(),
                        "days": coverage[n.key]}))
        })
        .collect();
    weakest.sort_by(|a, b| a["pct"].as_f64().unwrap_or(0.0).total_cmp(&b["pct"].as_f64().unwrap_or(0.0)));
    weakest.truncate(6);
    let over: Vec<Value> = limits.iter().filter_map(|key| {
        let target = targets[*key].as_f64()?;
        let average = averages.get(*key).and_then(Value::as_f64).filter(|_| enough(key))?;
        (average > target).then(|| json!({"key": key, "avg": average, "target": target, "days": coverage[*key]}))
    }).collect();
    let half = complete.len() / 2;
    let trend = |key: &str| -> Value {
        if complete.len() < 4 { return Value::Null; }
        let mean = |part: &[&Value]| {
            let known: Vec<f64> = part.iter().filter_map(|d| d["totals"][key].as_f64()).collect();
            (!known.is_empty()).then(|| (known.iter().sum::<f64>() / known.len() as f64).round())
        };
        match (mean(&complete[..half]), mean(&complete[half..])) {
            (Some(first), Some(second)) => json!({"first_half": first, "second_half": second}),
            _ => Value::Null,
        }
    };
    let weights: Vec<(String, f64)> = per_day.iter()
        .filter_map(|d| Some((d["day"].as_str()?.to_string(), d["health"]["weight_kg"].as_f64()?))).collect();
    let active: Vec<f64> = per_day.iter().filter_map(|d| d["health"]["active_kcal"].as_f64()).collect();
    Ok(json!({
        "from": from, "to": today, "days": days, "logged_days": complete.len(), "includes_today": includes_today, "averages": averages, "coverage": coverage, "targets": targets,
        "adherence": {"kcal_within_10pct": on_kcal, "protein_hit": on_protein, "of_days": complete.len()},
        "weakest": weakest, "over_limits": over, "trends": {"kcal": trend("kcal"), "protein": trend("protein")},
        "weight": {"first": weights.first().map(|w| json!({"day": w.0, "kg": w.1})), "last": weights.last().map(|w| json!({"day": w.0, "kg": w.1}))},
        "active_kcal_avg": if active.is_empty() { Value::Null } else { json!((active.iter().sum::<f64>() / active.len() as f64).round()) },
        "per_day": per_day.iter().map(|d| json!({"day": d["day"], "entries": d["entries"], "kcal": d["totals"]["kcal"], "protein": d["totals"]["protein"], "partial": d["partial"]})).collect::<Vec<_>>(),
    }))
}

// MARK: Goals, foods and recipes

/// `food goals set` and friends: {plan?, mode?, water_ml?, overrides: {key: number | null}}.
pub fn update_goals(state: &State, changes: &Value) -> Result<Value, String> {
    state.write(|db| {
        let mut goals = goals::current(db)?;
        for key in ["plan", "mode"] {
            if let Some(v) = changes[key].as_str() {
                goals[key] = json!(v);
            }
        }
        if let Some(w) = changes["water_ml"].as_f64() {
            goals["water_ml"] = json!(w);
        }
        if let Some(set) = changes["overrides"].as_object() {
            for (key, value) in set {
                if nutrients::find(key).is_none() {
                    return Err(format!("unknown nutrient {key:?}; see `food help nutrients`"));
                }
                if value.is_null() {
                    goals["overrides"].as_object_mut().map(|o| o.remove(key));
                } else {
                    goals["overrides"][key] = value.clone();
                }
            }
        }
        goals["updated_at"] = json!(time::now_ms().max(goals["updated_at"].as_i64().unwrap_or(0) + 1));
        store::apply(db, "goals", "upsert", &goals)?;
        goals::recompute(db)
    })
}

pub fn add_food(state: &State, food: &Value) -> Result<Value, String> {
    state.write(|db| {
        let mut food = food.clone();
        if !food.is_object() || food["name"].as_str().is_none_or(str::is_empty) {
            return Err("a food needs a name".to_string());
        }
        let now = time::now_ms();
        if food["id"].as_str().is_none() { food["id"] = json!(db::uuid()); }
        if food["source"].as_str().is_none() { food["source"] = json!("custom"); }
        food["updated_at"] = json!(now);
        if food["kind"] == "recipe" {
            resolve_components(db, &mut food)?;
        }
        let id = store::apply(db, "foods", "upsert", &food)?.id;
        store::live(db, "foods", &id)?.ok_or_else(|| "food vanished".to_string())
    })
}

/// Components given as food ids, source refs or catalog queries become saved food ids.
fn resolve_components(db: &Connection, recipe: &mut Value) -> Result<(), String> {
    let mut out = Vec::new();
    for component in recipe["components"].as_array().cloned().unwrap_or_default() {
        let food = if let Some(id) = component["food_id"].as_str() {
            match food_ref(db, id) {
                Ok(food) => food,
                // A deleted ingredient stays in the recipe, which the store marks partial.
                Err(_) if store::get(db, "foods", id)?.is_some_and(|row| row.deleted) => json!({"id": id}),
                Err(e) => return Err(e),
            }
        } else if let Some(r) = component["source_ref"].as_str().or(component["food"].as_str()) {
            food_ref(db, r)?
        } else if let Some(query) = component["catalog"].as_str() {
            save_food(db, &catalog::to_food(&catalog::resolve(db, query)?))?
        } else {
            return Err(format!("component {component} needs food_id, source_ref or catalog"));
        };
        let mut c = json!({"food_id": food["id"]});
        if let Some(s) = component["servings"].as_f64() { c["servings"] = json!(s); }
        if let Some(g) = component["grams"].as_f64() { c["grams"] = json!(g); }
        out.push(c);
    }
    if out.is_empty() {
        return Err("a recipe needs components".to_string());
    }
    recipe["components"] = Value::Array(out);
    Ok(())
}

pub fn list_foods(db: &Connection, favorites: bool) -> Result<Value, String> {
    let counts = log_counts(db)?;
    let mut foods = store::select(db, "foods", if favorites { "favorite = 1 ORDER BY name" } else { "1 ORDER BY name" }, &[])?;
    for food in &mut foods {
        food["times_logged"] = json!(counts.get(food["id"].as_str().unwrap_or("")).copied().unwrap_or(0));
    }
    Ok(json!({"foods": foods}))
}

pub fn favorite(state: &State, id: &str, on: bool) -> Result<Value, String> {
    state.write(|db| {
        let id = resolve_id(db, "foods", id)?;
        let mut food = store::live(db, "foods", &id)?.ok_or("food vanished")?;
        food["favorite"] = json!(on);
        food["updated_at"] = json!(time::now_ms().max(food["updated_at"].as_i64().unwrap_or(0) + 1));
        store::apply(db, "foods", "upsert", &food)?;
        store::live(db, "foods", &id)?.ok_or_else(|| "food vanished".to_string())
    })
}

// MARK: Health context

/// The profile keys the server keeps, each checked: (key, what it must be).
const PROFILE_KEYS: &[(&str, &str)] = &[
    ("dob", "a YYYY-MM-DD birth date"),
    ("sex", "male or female"),
    ("height_cm", "a height from 50 to 272 cm"),
    ("weight_kg", "a weight from 20 to 450 kg"),
    ("age", "an age from 14 to 110"),
    ("activity_factor", "an activity factor from 1.0 to 2.5"),
    ("weight_day", "a YYYY-MM-DD day"),
    ("height_day", "a YYYY-MM-DD day"),
    ("age_on", "a YYYY-MM-DD day"),
    ("active_through", "a YYYY-MM-DD day"),
];

/// One profile value, checked. Ok(None) clears the key; Err says what it must be.
fn profile_value(key: &str, value: &Value) -> Result<Option<Value>, String> {
    if value.is_null() {
        return Ok(None);
    }
    let what = PROFILE_KEYS.iter().find(|(k, _)| *k == key).map(|(_, w)| *w).ok_or_else(|| {
        let known: Vec<&str> = PROFILE_KEYS.iter().map(|(k, _)| *k).collect();
        format!("unknown profile key {key:?}; known: {}", known.join(", "))
    })?;
    let fail = || format!("profile {key} must be {what}");
    let range = |lo: f64, hi: f64| value.as_f64().filter(|x| (lo..=hi).contains(x)).map(|x| json!(nutrients::round(x))).ok_or_else(fail);
    Ok(Some(match key {
        "sex" => match value.as_str().map(str::to_ascii_lowercase).as_deref() {
            Some("male" | "m") => json!("male"),
            Some("female" | "f") => json!("female"),
            _ => return Err(fail()),
        },
        "height_cm" => range(50.0, 272.0)?,
        "weight_kg" => range(20.0, 450.0)?,
        "age" => range(14.0, 110.0)?,
        "activity_factor" => range(1.0, 2.5)?,
        _ => {
            let day = value.as_str().map(|d| d.get(..10).unwrap_or(d)).and_then(time::parse_day).map(time::format_day).ok_or_else(fail)?;
            json!(day)
        }
    }))
}

/// Merges `changes` into the stored profile: a value sets its key, null clears it. With `strict`
/// a bad value is an error; otherwise it's skipped and named in the returned list.
fn merge_profile(db: &Connection, changes: &Value, strict: bool) -> Result<(Value, Vec<String>), String> {
    let mut profile: Value = db::meta_get(db, "profile").and_then(|p| serde_json::from_str(&p).ok()).filter(Value::is_object).unwrap_or(json!({}));
    let mut ignored = Vec::new();
    if let Some(changes) = changes.as_object() {
        for (key, value) in changes {
            let key = if key == "birth_date" { "dob" } else { key.as_str() };
            match profile_value(key, value) {
                Ok(Some(v)) => { profile[key] = v; }
                Ok(None) => { profile.as_object_mut().map(|o| o.remove(key)); }
                Err(e) if strict => return Err(e),
                Err(_) => ignored.push(key.to_string()),
            }
        }
        db::meta_set(db, "profile", &profile.to_string())?;
    }
    Ok((profile, ignored))
}

/// Health data from `food health import`, `food health refresh` or `POST /v1/health_days`:
/// {profile?, days: [{day, weight_kg, active_kcal, basal_kcal, steps, exercise_min}]}. The profile
/// is merged into the stored one; days replace the stored rows for those days.
pub fn health(state: &State, push: &Value) -> Result<Value, String> {
    state.write(|db| {
        let now = time::now_ms();
        let (_, ignored) = merge_profile(db, &push["profile"], false)?;
        let oldest = time::add_days(&time::today(), -400).unwrap_or_default();
        let newest = time::add_days(&time::today(), 1).unwrap_or_default();
        let (mut written, mut skipped) = (0, 0);
        for day in push["days"].as_array().cloned().unwrap_or_default() {
            let Some(d) = day["day"].as_str().or(day["date"].as_str()).and_then(time::parse_day).map(time::format_day) else {
                skipped += 1;
                continue;
            };
            if d < oldest || d > newest {
                skipped += 1;
                continue;
            }
            let number = |k: &str| day[k].as_f64().filter(|x| (0.0..=1e7).contains(x)).map(|x| (x * 10.0).round() / 10.0);
            let mut row = json!({"id": d, "day": d, "weight_kg": number("weight_kg"), "active_kcal": number("active_kcal"),
                                 "basal_kcal": number("basal_kcal"), "steps": number("steps"), "exercise_min": number("exercise_min"),
                                 "updated_at": now, "deleted": false});
            if let Some(existing) = store::get(db, "health_days", &d)? {
                let mut same = existing.data.clone();
                same["updated_at"] = json!(now);
                if same == row && !existing.deleted {
                    continue;
                }
                row["updated_at"] = json!(now.max(existing.updated_at + 1));
            }
            store::put(db, "health_days", &row)?;
            written += 1;
        }
        let stale = store::select(db, "health_days", "day < ?1", &[&oldest])?;
        for row in &stale {
            store::put(db, "health_days", &json!({"id": row["id"], "day": row["day"], "deleted": true, "updated_at": now}))?;
        }
        let goals = goals::recompute(db)?;
        Ok(json!({"days_written": written, "days_skipped": skipped, "days_pruned": stale.len(), "profile_ignored": ignored, "goals": goals}))
    })
}

/// `food goals profile key=value ...`: sets body facts by hand, for goals without a health source.
pub fn set_profile(state: &State, changes: &Value) -> Result<Value, String> {
    let mut changes = changes.clone();
    // A weight or age given now is as of today, in the service's zone.
    for (key, on) in [("weight_kg", "weight_day"), ("age", "age_on")] {
        if changes[key].is_number() && changes[on].is_null() {
            changes[on] = json!(time::today());
        }
    }
    state.write(|db| {
        let (profile, _) = merge_profile(db, &changes, true)?;
        Ok(json!({"profile": profile, "goals": goals::recompute(db)?}))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> State {
        let db = db::memory();
        catalog::import(&db, &[json!({"fdc_id": 173944, "dataset": "sr_legacy", "name": "Bananas, raw",
            "nutrients": {"kcal": 89, "protein": 1.09, "potassium": 358}, "portions": [{"label": "1 medium", "grams": 118}]})]).unwrap();
        catalog::finish(&db, &json!([])).unwrap();
        State::new(db)
    }

    #[test]
    fn logging_editing_and_removing() {
        let state = state();
        let out = log(&state, &[json!({"catalog": "banana raw", "grams": 118, "meal": "breakfast"}),
                                json!({"name": "Burrito bowl", "nutrients": {"kcal": 750, "protein": 40}, "meal": "lunch", "grams": 520})]).unwrap();
        let banana = &out["logged"][0]["entry"];
        assert_eq!(banana["nutrients"]["kcal"], json!(105.02));
        assert_eq!(banana["source"], "agent");
        assert_eq!(out["today"]["totals"]["kcal"], json!(855.02));
        let bowl = &out["logged"][1]["entry"];
        assert_eq!(bowl["grams"], json!(520.0));
        // Logging the same catalog food again reuses the saved food.
        let again = log(&state, &[json!({"catalog": "fdc:173944", "servings": 2})]).unwrap();
        assert_eq!(again["logged"][0]["entry"]["food_id"], banana["food_id"]);
        assert_eq!(again["logged"][0]["entry"]["grams"], json!(236.0));
        let id = banana["id"].as_str().unwrap();
        let edited = edit(&state, &id[..8], &json!({"grams": 59})).unwrap();
        assert_eq!(edited["nutrients"]["kcal"], json!(52.51));
        remove(&state, "entries", &[id.to_string()]).unwrap();
        let db = state.lock();
        assert_eq!(day_summary(&db, &time::today()).unwrap()["entry_count"], 2);
        assert_eq!(suggest(&db, Some("lunch"), None).unwrap()["recents"].as_array().unwrap().len(), 2);
        assert_eq!(own_foods(&db, "burrito", 5).unwrap()[0]["source"], "agent");
    }

    #[test]
    fn health_push_writes_days_once_and_sets_goals() {
        let state = state();
        let yesterday = time::add_days(&time::today(), -1).unwrap();
        let days: Vec<Value> = (0..14).map(|i| json!({"day": time::add_days(&yesterday, -i).unwrap(), "active_kcal": 400})).collect();
        let push = json!({"profile": {"dob": "2004-07-07", "sex": "male", "height_cm": 185.4, "weight_kg": 116.1,
                                      "active_through": yesterday}, "days": days});
        let first = health(&state, &push).unwrap();
        assert_eq!(first["days_written"], 14);
        assert_eq!(first["goals"]["basis"]["active_kcal_avg14"], json!(400.0));
        let v = db::version(&state.lock());
        assert_eq!(health(&state, &push).unwrap()["days_written"], 0);
        assert_eq!(db::version(&state.lock()), v);
        let goals = update_goals(&state, &json!({"plan": "cut", "overrides": {"protein": 180}})).unwrap();
        assert_eq!(goals["targets"]["protein"], json!(180.0));
        let cleared = update_goals(&state, &json!({"plan": "maintain", "overrides": {"protein": null}})).unwrap();
        assert_eq!(cleared["targets"]["protein"], json!((116.1_f64 * 1.8).round()));
    }

    #[test]
    fn imported_days_and_a_hand_set_profile_drive_the_goals() {
        let state = state();
        // No health source at all: the default, and a note that says how to fix it.
        let goals = goals::recompute(&state.lock()).unwrap();
        assert_eq!(goals["targets"]["kcal"], json!(goals::DEFAULT_KCAL));
        assert!(goals["basis"]["note"].as_str().unwrap().contains("food goals profile"), "{}", goals["basis"]["note"]);
        // A profile by hand: Mifflin-St Jeor x the activity factor.
        let out = set_profile(&state, &json!({"weight_kg": 70, "height_cm": 165, "age": 35, "age_on": time::today(), "sex": "f",
                                              "weight_day": time::today()})).unwrap();
        let bmr: f64 = 10.0 * 70.0 + 6.25 * 165.0 - 5.0 * 35.0 - 161.0;
        assert_eq!(out["goals"]["basis"]["bmr"], json!(bmr.round()));
        assert_eq!(out["goals"]["basis"]["tdee"], json!((bmr * 1.35).round()));
        let out = set_profile(&state, &json!({"activity_factor": 1.55})).unwrap();
        assert_eq!(out["goals"]["basis"]["tdee"], json!((bmr * 1.55).round()));
        assert!(set_profile(&state, &json!({"height_cm": 9000})).unwrap_err().contains("height"));
        assert!(set_profile(&state, &json!({"shoe_size": 9})).is_err());
        // Imported days: active energy replaces the factor, and a newer weighing wins.
        let yesterday = time::add_days(&time::today(), -1).unwrap();
        let days: Vec<Value> = (0..10).map(|i| json!({"day": time::add_days(&yesterday, -i).unwrap(), "active_kcal": 300, "steps": 6000})).collect();
        let mut days = days;
        days.push(json!({"day": time::today(), "weight_kg": 68.0}));
        days.push(json!({"day": "1999-01-01", "weight_kg": 68.0}));
        days.push(json!({"day": "not a day"}));
        let out = health(&state, &json!({"days": days, "profile": {"birth_date": "1991-01-01", "height_cm": "tall"}})).unwrap();
        assert_eq!(out["days_written"], 11);
        assert_eq!(out["days_skipped"], 2);
        assert_eq!(out["profile_ignored"], json!(["height_cm"]));
        let basis = &out["goals"]["basis"];
        assert_eq!(basis["active_kcal_avg14"], json!(300.0));
        assert_eq!(basis["weight_kg"], json!(68.0));
        assert_eq!(basis["height_cm"], json!(165.0));
        // The birth date wins over the hand-set age.
        assert_eq!(basis["age"], json!(time::age("1991-01-01", &time::today()).unwrap()));
        // Clearing a key.
        let out = set_profile(&state, &json!({"sex": null})).unwrap();
        assert!(out["profile"].get("sex").is_none());
        assert!(out["goals"]["basis"]["note"].as_str().unwrap().contains("sex"));
    }

    #[test]
    fn days_follow_the_configured_zone() {
        // Logged now in Tokyo, the entry's day is Tokyo's today, whatever Chicago says.
        let tokyo = crate::tz::Zone::posix("Asia/Tokyo", "JST-9").unwrap();
        time::with_zone(tokyo, || {
            let state = state();
            let out = log(&state, &[json!({"name": "Onigiri", "nutrients": {"kcal": 180}})]).unwrap();
            let tokyo_today = time::format_day((time::now_ms() / 1000 + 9 * 3600).div_euclid(86_400));
            assert_eq!(out["logged"][0]["entry"]["day"], json!(tokyo_today));
            assert_eq!(out["today"]["date"], json!(tokyo_today));
            assert_eq!(report(&state.lock(), 1).unwrap()["to"], json!(tokyo_today));
            assert_eq!(nutrients::meta()["timezone"], "Asia/Tokyo");
        });
    }

    #[test]
    fn report_averages_each_nutrient_over_the_days_that_have_it() {
        let state = state();
        let today = time::today();
        let day = |back: i64| time::add_days(&today, -back).unwrap();
        // Four logged days before today: iron is known on two of them, vitamin D on one.
        let rows = [(1, json!({"kcal": 2000, "iron": 6})), (2, json!({"kcal": 2200, "iron": 10})), (3, json!({"kcal": 1800})),
                    (4, json!({"kcal": 2000, "vit_d": 1}))];
        {
            let db = state.lock();
            for (back, nutrients) in rows {
                store::apply(&db, "entries", "upsert", &json!({"id": format!("e{back}"), "day": day(back), "name": "Meal",
                                                               "nutrients": nutrients, "updated_at": time::now_ms()})).unwrap();
            }
        }
        let r = report(&state.lock(), 7).unwrap();
        assert_eq!(r["logged_days"], 4);
        assert_eq!(r["averages"]["iron"], json!(8.0), "not (6 + 10) / 4");
        assert_eq!(r["coverage"]["iron"], 2);
        assert_eq!((r["averages"]["vit_d"].clone(), r["coverage"]["vit_d"].clone()), (json!(1.0), json!(1)));
        assert_eq!(r["averages"]["kcal"], json!(2000.0));
        let weakest: Vec<&str> = r["weakest"].as_array().unwrap().iter().filter_map(|w| w["key"].as_str()).collect();
        assert!(weakest.contains(&"iron"), "{weakest:?}");
        assert!(!weakest.contains(&"vit_d"), "one day of four isn't enough to rank: {weakest:?}");
        let iron = r["weakest"].as_array().unwrap().iter().find(|w| w["key"] == "iron").unwrap();
        assert_eq!(iron["days"], 2);
    }

    #[test]
    fn recipes_from_catalog_components() {
        let state = state();
        let recipe = add_food(&state, &json!({"kind": "recipe", "name": "Banana smoothie", "recipe_servings": 2,
            "components": [{"catalog": "banana", "grams": 236}]})).unwrap();
        assert_eq!(recipe["nutrients"]["kcal"], json!(105.02));
        assert_eq!(recipe["serving"]["grams"], json!(118.0));
    }
}
