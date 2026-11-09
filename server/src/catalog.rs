//! The USDA FoodData Central catalog: Foundation, SR Legacy and FNDDS survey foods, per 100 g,
//! with USDA portions. Searched with FTS5; results come back as Food objects with `id: null`.

use crate::{db, nutrients};
use rusqlite::{params, Connection};
use serde_json::{json, Value};

/// Stores one batch from `food seed-usda`. Replaces rows with the same fdc_id, so reruns are safe.
pub fn import(db: &Connection, items: &[Value]) -> Result<usize, String> {
    let mut insert = db
        .prepare_cached("INSERT OR REPLACE INTO catalog (fdc_id, dataset, name, category, nutrients, portions) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
        .map_err(|e| e.to_string())?;
    let mut n = 0;
    for item in items {
        let (Some(fdc_id), Some(name)) = (item["fdc_id"].as_i64(), item["name"].as_str()) else { continue };
        let dataset = item["dataset"].as_str().unwrap_or("sr_legacy");
        let portions: Vec<Value> = item["portions"]
            .as_array()
            .map(|list| list.iter().filter(|p| p["label"].is_string() && p["grams"].as_f64().is_some_and(|g| g > 0.0)).cloned().collect())
            .unwrap_or_default();
        let nutrients = Value::Object(nutrients::clean(&item["nutrients"]));
        n += insert
            .execute(params![fdc_id, dataset, name, item["category"].as_str(), nutrients.to_string(), Value::Array(portions).to_string()])
            .map_err(|e| e.to_string())?;
    }
    Ok(n)
}

/// Rebuilds the search index after an import and records what was seeded.
pub fn finish(db: &Connection, sources: &Value) -> Result<Value, String> {
    db.execute("INSERT INTO catalog_fts (catalog_fts) VALUES ('rebuild')", []).map_err(|e| e.to_string())?;
    let (counts, _) = db::run_query(db, "SELECT dataset, count(*) AS foods FROM catalog GROUP BY 1 ORDER BY 1")?;
    let summary = json!({"sources": sources, "counts": counts, "at": crate::time::now_utc()});
    db::meta_set(db, "usda_seed", &summary.to_string())?;
    Ok(summary)
}

/// Ways of cooking. A query word from this list may match its near-synonyms, and may be dropped
/// when nothing matches it ("oatmeal cooked" still finds "Oatmeal, NFS").
const PREP: &[(&str, &[&str])] = &[
    ("cooked", &["boiled", "steamed", "baked", "roasted", "broiled", "grilled", "prepared", "stewed"]),
    ("steamed", &["boiled", "cooked"]),
    ("boiled", &["cooked", "steamed"]),
    ("grilled", &["broiled", "roasted"]),
    ("broiled", &["grilled", "roasted", "baked"]),
    ("roasted", &["baked", "broiled", "grilled"]),
    ("baked", &["roasted", "broiled"]),
    ("stewed", &["cooked"]),
    ("braised", &["cooked"]),
    ("microwaved", &["cooked"]),
    ("dry", &["uncooked"]),
    ("raw", &[]), ("fried", &[]), ("sauteed", &[]), ("poached", &[]), ("scrambled", &[]), ("toasted", &[]),
    ("smoked", &[]), ("mashed", &[]),
];

const STOP: &[&str] = &["a", "an", "and", "of", "or", "the", "with", "in", "on"];
const NEGATIONS: &[&str] = &["no", "not", "without", "non"];

/// Words in a name that say it isn't the plain food: sauces, processing, dishes, fast food, baby food.
const HEAVY: &[&str] = &[
    "sauce", "gravy", "glutinous", "fast", "food", "foods", "babyfood", "baby", "infant", "toddler", "junior", "strained",
    "canned", "restaurant", "school", "chain", "stuffed", "breaded", "battered", "coated", "candied", "sweetened",
    "flavored", "dry", "mix", "powder", "dehydrated", "imitation", "substitute", "reduced", "low", "lite", "light",
    "diet", "free", "concentrate", "salad", "soup", "sandwich", "casserole", "pudding", "cookie", "cookies", "bar",
    "bars", "chips", "snack", "snacks", "beverage", "beverages", "dough", "filling", "frosted", "glazed", "syrup",
    "meatless", "vegetarian", "roll", "rolls", "spread",
];
const MEDIUM: &[&str] = &["extra", "wheat", "gluten", "added", "vitamin", "fortified", "mixture"];
/// Words that only describe the plain food more precisely.
const LIGHT: &[&str] = &[
    "regular", "plain", "enriched", "unenriched", "long", "grain", "whole", "fresh", "only", "boneless",
    "skinless", "nfs", "ns", "as", "to", "type", "salt", "mature", "seeds", "crust", "thin", "thick", "topping",
    "from", "of", "the", "prepared", "made", "home", "style", "drained", "ripe", "all", "purpose", "broiler", "broilers",
    "fryer", "fryers", "quick", "form", "specified", "water", "cooked", "frozen", "fat",
];
/// What a name can leave out ("without salt", "skin not eaten") and still be the plain food.
const OMITTABLE: &[&str] = &[
    "sauce", "salt", "sugar", "skin", "eaten", "pulp", "fortified", "concentrate", "reconstituted", "added", "butter",
    "oil", "margarine", "dressing", "bone", "fat", "vitamin", "seeds", "peel",
];
/// Group names that SR Legacy and FNDDS put first: "Fish, salmon", "Cheese, cheddar", "Beef, steak".
const GROUPS: &[&str] = &[
    "fish", "crustaceans", "mollusks", "nuts", "seeds", "spices", "cheese", "cereal", "cereals", "beef", "pork", "lamb",
    "veal",
];

/// A rough root for plurals and verb endings, and which kind of ending it had: "bananas" and
/// "banana" share one, and so do "grilled" and "grill", but "rolled" and "rolls" don't quite.
fn root(word: &str) -> (String, u8) {
    let mut w = word.to_lowercase();
    let mut ending = 0;
    if w.len() > 4 && w.ends_with("ies") {
        w = format!("{}y", &w[..w.len() - 3]);
        ending = 1;
    } else {
        for (suffix, kind) in [("ing", 2), ("ed", 2), ("es", 1), ("s", 1)] {
            if w.len() >= suffix.len() + 3 && w.ends_with(suffix) && !(suffix == "s" && w.ends_with("ss")) {
                w.truncate(w.len() - suffix.len());
                ending = kind;
                break;
            }
        }
    }
    if w.len() > 3 && w.ends_with('e') {
        w.pop();
    }
    (w, ending)
}

fn tokens(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_lowercase).collect()
}

fn prep_synonyms(word: &str) -> Option<&'static [&'static str]> {
    PREP.iter().find(|(w, _)| *w == word).map(|(_, s)| *s)
}

/// An FTS5 query that needs every word (a cooking word or one of its synonyms), or with " OR "
/// any word, and the last word as a prefix when `prefix` is set. Words are quoted, so nothing in
/// them is FTS syntax.
fn fts_query(words: &[String], joiner: &str, prefix: bool) -> Option<String> {
    let last = words.len().checked_sub(1)?;
    let parts: Vec<String> = words
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let star = if prefix && i == last { "*" } else { "" };
            match prep_synonyms(w).filter(|s| !s.is_empty() && joiner == " AND ") {
                Some(synonyms) => {
                    let mut group = vec![format!("\"{w}\"{star}")];
                    group.extend(synonyms.iter().map(|s| format!("\"{s}\"")));
                    format!("({})", group.join(" OR "))
                }
                None => format!("\"{w}\"{star}"),
            }
        })
        .collect();
    Some(parts.join(joiner))
}

/// What one name word the query didn't ask for costs.
fn extra_cost(original: &str, word: &str, asks_cooked: bool, asks_raw: bool) -> f64 {
    if original.chars().filter(char::is_ascii_uppercase).count() >= 2 && !matches!(word, "nfs" | "ns") {
        2.5 // a brand: DIGIORNO, PIZZA HUT, McDONALD'S
    } else if word.chars().any(|c| c.is_ascii_digit()) {
        0.5
    } else if prep_synonyms(word).is_some() && !matches!(word, "cooked" | "dry") {
        // "raw" when a cooked food was asked for, or the other way round.
        let conflict = if word == "raw" { asks_cooked } else { asks_raw };
        // Unasked, "raw" is the plain form; "fried" or "smoked" is a different dish.
        if conflict { 2.0 } else if asks_cooked { 1.0 } else if word == "raw" { 0.3 } else { 0.8 }
    } else if HEAVY.contains(&word) {
        2.5
    } else if MEDIUM.contains(&word) {
        1.5
    } else if LIGHT.contains(&word) {
        0.2
    } else {
        1.0
    }
}

/// How far a catalog name is from the plain food the query asks for; lower is better. Every query
/// word missing from the name costs a lot, and every word the name adds costs by kind: a sauce,
/// a brand, fast food or "with ..." costs more than "raw" or "enriched", "without ..." or "no added
/// fat" almost nothing, and words in the first segment ("Rice crackers") more than later ones.
/// More comma segments cost a little, and survey (FNDDS) foods a little more than Foundation and
/// SR Legacy, so a single ingredient comes from the lab data while a named dish, which only the
/// survey has, still finds its survey food.
fn distance(name: &str, dataset: &str, words: &[String]) -> f64 {
    // "(Includes foods for USDA's Food Distribution Program)" says nothing about the food.
    let mut plain = String::new();
    let mut depth = 0;
    for c in name.chars() {
        match c {
            '(' => depth += 1,
            ')' => depth = (depth - 1).max(0),
            _ if depth == 0 => plain.push(c),
            _ => {}
        }
    }
    let roots: Vec<(String, u8)> = words.iter().map(|w| root(w)).collect();
    let last = &words[words.len() - 1];
    let asks_raw = words.iter().any(|w| matches!(w.as_str(), "raw" | "dry"));
    let asks_cooked = !asks_raw && words.iter().any(|w| prep_synonyms(w).is_some());
    let asks_negation = words.iter().any(|w| NEGATIONS.contains(&w.as_str()));
    // How each query word was found: 0 itself, 1 a near form or prefix, 2 a cooking synonym.
    let mut found: Vec<Option<u8>> = vec![None; words.len()];
    let mut cost = 0.0;
    let mut segments = 0;
    for segment in plain.split(',') {
        let originals: Vec<&str> = segment.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
        if originals.is_empty() {
            continue;
        }
        segments += 1;
        let (mut negated, mut addition) = (false, false);
        let alone = originals.len() == 1;
        for (position, &original) in originals.iter().enumerate() {
            let word = original.to_lowercase();
            let head = segments == 1 && position == 0;
            let (r, ending) = root(&word);
            let hit = if let Some(i) = roots.iter().position(|(q, e)| *q == r && (*e == ending || *e == 0 || ending == 0)) {
                Some((i, 0))
            } else if let Some(i) = roots.iter().position(|(q, _)| *q == r) {
                Some((i, 1))
            } else if last.len() >= 2 && word.starts_with(last.as_str()) {
                Some((words.len() - 1, 1))
            } else {
                words.iter().position(|q| prep_synonyms(q).is_some_and(|s| s.iter().any(|s| root(s).0 == r))).map(|i| (i, 2))
            };
            if NEGATIONS.contains(&word.as_str()) {
                negated = true;
                if let Some((i, _)) = hit.filter(|_| asks_negation) {
                    found[i] = Some(0);
                } else {
                    cost += 0.1;
                }
                continue;
            }
            if word == "with" {
                addition = true;
            }
            if matches!(word.as_str(), "with" | "and" | "or") {
                cost += 0.1;
                continue;
            }
            match hit {
                // "Pizza, no cheese" is the opposite of what "pizza cheese" asks for.
                Some(_) if negated && !asks_negation => cost += 4.0,
                Some((i, kind)) => found[i] = Some(found[i].map_or(kind, |f| f.min(kind))),
                None if negated => cost += if OMITTABLE.contains(&word.as_str()) || LIGHT.contains(&word.as_str()) { 0.15 } else { 1.5 },
                None if head && alone && GROUPS.contains(&word.as_str()) => cost += 0.6,
                // "meat only" is the plain cut; "meat topping" is not.
                None if word == "meat" && originals.get(position + 1).is_some_and(|w| w.eq_ignore_ascii_case("only")) => cost += 0.2,
                None => {
                    let base = extra_cost(original, &word, asks_cooked, asks_raw);
                    let base = if addition && matches!(word.as_str(), "water" | "salt") {
                        0.3
                    } else if addition {
                        base.max(1.5)
                    } else {
                        base
                    };
                    // The first segment names the food: "Rice crackers" aren't rice.
                    cost += if segments == 1 { base.max(1.0) * 2.0 } else { base };
                    if head {
                        cost += 1.5; // "Pepper, banana, raw" isn't a banana
                    }
                }
            }
        }
    }
    for (word, f) in words.iter().zip(&found) {
        cost += match f {
            Some(0) => 0.0,
            Some(1) => 1.5,
            Some(_) => 0.4,
            None if prep_synonyms(word).is_some() => 1.0,
            None => 4.0,
        };
    }
    cost += 0.15 * (segments.max(1) - 1) as f64;
    if dataset == "survey" {
        cost += 0.4;
    }
    cost
}

fn row_to_item(row: &rusqlite::Row) -> rusqlite::Result<Value> {
    let nutrients: String = row.get(4)?;
    let portions: String = row.get(5)?;
    Ok(json!({
        "fdc_id": row.get::<_, i64>(0)?, "dataset": row.get::<_, String>(1)?, "name": row.get::<_, String>(2)?,
        "category": row.get::<_, Option<String>>(3)?,
        "nutrients": serde_json::from_str::<Value>(&nutrients).unwrap_or(json!({})),
        "portions": serde_json::from_str::<Value>(&portions).unwrap_or(json!([])),
    }))
}

/// Catalog rows for a text query, best first. Candidates are the foods matching every word (a
/// cooking word may match a synonym or be left out), else every word with the last as a prefix,
/// else any word; then they are ordered by `distance`, so among foods that match, the plainest name
/// wins: "rice white cooked" is "Rice, white, cooked, no added fat", not "..., glutinous".
pub fn search(db: &Connection, text: &str, limit: usize) -> Result<Vec<Value>, String> {
    const POOL: i64 = 300;
    let sql = "SELECT c.fdc_id, c.dataset, c.name, c.category, c.nutrients, c.portions FROM catalog_fts
               JOIN catalog c ON c.fdc_id = catalog_fts.rowid WHERE catalog_fts MATCH ?1
               ORDER BY bm25(catalog_fts, 10.0, 1.0) + length(c.name) * 0.04 LIMIT ?2";
    let all = tokens(text);
    let kept: Vec<String> = all.iter().filter(|w| !STOP.contains(&w.as_str())).cloned().collect();
    let words = if kept.is_empty() { all } else { kept };
    if words.is_empty() {
        return Ok(Vec::new());
    }
    let core: Vec<String> = words.iter().filter(|w| prep_synonyms(w).is_none()).cloned().collect();
    let mut queries = vec![fts_query(&words, " AND ", false)];
    if !core.is_empty() && core.len() < words.len() {
        queries.push(fts_query(&core, " AND ", false));
    }
    let mut pool: Vec<Value> = Vec::new();
    let mut ids = std::collections::HashSet::new();
    let mut run = |query: Option<String>, pool: &mut Vec<Value>| -> Result<(), String> {
        let Some(query) = query else { return Ok(()) };
        let mut statement = db.prepare_cached(sql).map_err(|e| e.to_string())?;
        let rows = statement.query_map(params![query, POOL], row_to_item).map_err(|e| e.to_string())?;
        for row in rows {
            let row = row.map_err(|e| e.to_string())?;
            if ids.insert(row["fdc_id"].as_i64().unwrap_or(0)) {
                pool.push(row);
            }
        }
        Ok(())
    };
    for query in queries {
        run(query, &mut pool)?;
    }
    if pool.len() < limit {
        run(fts_query(&words, " AND ", true), &mut pool)?;
    }
    if pool.is_empty() && words.len() > 1 {
        run(fts_query(&words, " OR ", true), &mut pool)?;
    }
    let mut scored: Vec<(f64, Value)> = pool
        .into_iter()
        .map(|row| (distance(row["name"].as_str().unwrap_or(""), row["dataset"].as_str().unwrap_or(""), &words), row))
        .collect();
    scored.sort_by(|(a, x), (b, y)| {
        let len = |v: &Value| v["name"].as_str().map_or(0, str::len);
        a.total_cmp(b).then(len(x).cmp(&len(y))).then(x["fdc_id"].as_i64().cmp(&y["fdc_id"].as_i64()))
    });
    // Foundation repeats a name across releases; keep the first.
    let mut names = std::collections::HashSet::new();
    Ok(scored
        .into_iter()
        .map(|(_, row)| row)
        .filter(|row| names.insert(row["name"].as_str().unwrap_or("").to_lowercase()))
        .take(limit)
        .collect())
}

pub fn by_id(db: &Connection, fdc_id: i64) -> Result<Option<Value>, String> {
    let mut statement = db
        .prepare_cached("SELECT fdc_id, dataset, name, category, nutrients, portions FROM catalog WHERE fdc_id = ?1")
        .map_err(|e| e.to_string())?;
    let mut rows = statement.query_map([fdc_id], row_to_item).map_err(|e| e.to_string())?;
    rows.next().transpose().map_err(|e| e.to_string())
}

/// `fdc:171284`, `171284` or a text query to one catalog item.
pub fn resolve(db: &Connection, text: &str) -> Result<Value, String> {
    let digits = text.trim().trim_start_matches("fdc:");
    if let Ok(id) = digits.parse::<i64>() {
        return by_id(db, id)?.ok_or_else(|| format!("no catalog food fdc:{id}"));
    }
    search(db, text, 1)?.into_iter().next().ok_or_else(|| format!("nothing in the USDA catalog matches {text:?}"))
}

/// `1 cup, chopped` to (1, "cup, chopped"); `1/2 cup` to (0.5, "cup").
pub fn split_amount(label: &str) -> (f64, String) {
    let label = label.trim();
    let (head, rest) = label.split_once(' ').unwrap_or((label, ""));
    let amount = if let Some((a, b)) = head.split_once('/') {
        a.parse::<f64>().ok().zip(b.parse::<f64>().ok()).filter(|(_, b)| *b != 0.0).map(|(a, b)| a / b)
    } else {
        head.parse::<f64>().ok()
    };
    match amount {
        Some(a) if a > 0.0 && !rest.is_empty() => (a, rest.trim().to_string()),
        _ => (1.0, label.to_string()),
    }
}

/// A catalog item as an unsaved Food: one serving is the first USDA portion, or 100 g.
pub fn to_food(item: &Value) -> Value {
    let mut portions: Vec<Value> = item["portions"].as_array().cloned().unwrap_or_default();
    let first = portions.iter().find(|p| !p["label"].as_str().unwrap_or("").to_lowercase().contains("not specified")).cloned();
    portions.push(json!({"label": "100 g", "grams": 100}));
    let serving = match &first {
        Some(p) => {
            let (amount, unit) = split_amount(p["label"].as_str().unwrap_or("serving"));
            json!({"amount": amount, "unit": unit, "grams": p["grams"]})
        }
        None => json!({"amount": 100, "unit": "g", "grams": 100}),
    };
    let grams = serving["grams"].as_f64().unwrap_or(100.0);
    json!({
        "id": null, "kind": "food", "name": item["name"], "brand": null, "barcode": null,
        "serving": serving, "portions": portions,
        "nutrients": nutrients::scale(&item["nutrients"], grams / 100.0),
        "components": [], "recipe_servings": null,
        "source": "usda", "source_ref": format!("fdc:{}", item["fdc_id"]),
        "category": item["category"], "dataset": item["dataset"], "favorite": false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seeded() -> Connection {
        let db = db::memory();
        import(&db, &[
            json!({"fdc_id": 173944, "dataset": "sr_legacy", "name": "Bananas, raw", "category": "Fruits and Fruit Juices",
                   "nutrients": {"kcal": 89, "protein": 1.09, "potassium": 358}, "portions": [{"label": "1 medium (7\" to 7-7/8\" long)", "grams": 118}]}),
            json!({"fdc_id": 1, "dataset": "survey", "name": "Banana bread", "nutrients": {"kcal": 326}, "portions": [{"label": "1 slice", "grams": 60}]}),
            json!({"fdc_id": 2, "dataset": "survey", "name": "Pizza, cheese, regular crust", "nutrients": {"kcal": 266}, "portions": [{"label": "Quantity not specified", "grams": 107}]}),
        ]).unwrap();
        finish(&db, &json!([])).unwrap();
        db
    }

    /// Real catalog names around each query, including the over-specific foods the old ranking
    /// picked ("..., grilled with sauce, skin eaten", "Rice, white, cooked, glutinous").
    const REAL: &[(i64, &str, &str)] = &[
        (167737, "sr_legacy", "Oil, corn, peanut, and olive"),
        (168054, "sr_legacy", "Fish, salmon, chum, dried (Alaska Native)"),
        (168510, "sr_legacy", "Broccoli, cooked, boiled, drained, with salt"),
        (168878, "sr_legacy", "Rice, white, long-grain, regular, enriched, cooked"),
        (168880, "sr_legacy", "Rice, white, medium-grain, enriched, cooked"),
        (168882, "sr_legacy", "Rice, white, short-grain, enriched, cooked"),
        (168930, "sr_legacy", "Rice, white, medium-grain, cooked, unenriched"),
        (168932, "sr_legacy", "Rice, white, short-grain, cooked, unenriched"),
        (169392, "sr_legacy", "Broccoli, chinese, cooked"),
        (169394, "sr_legacy", "Pepper, banana, raw"),
        (169757, "sr_legacy", "Rice, white, long-grain, regular, unenriched, cooked without salt"),
        (169904, "sr_legacy", "Eggs, scrambled, frozen mixture"),
        (169967, "sr_legacy", "Broccoli, cooked, boiled, drained, without salt"),
        (170317, "sr_legacy", "Pizza, cheese topping, regular crust, frozen, cooked"),
        (170373, "sr_legacy", "Pizza, cheese topping, thin crust, frozen, cooked"),
        (170382, "sr_legacy", "Broccoli raab, cooked"),
        (170714, "sr_legacy", "Pizza, cheese topping, rising crust, frozen, cooked"),
        (170845, "sr_legacy", "Cheese, mozzarella, whole milk"),
        (170851, "sr_legacy", "Cheese, ricotta, whole milk"),
        (171078, "sr_legacy", "Chicken, broilers or fryers, breast, meat only, cooked, fried"),
        (171284, "sr_legacy", "Yogurt, plain, whole milk"),
        (171413, "sr_legacy", "Oil, olive, salad or cooking"),
        (171443, "sr_legacy", "Mayonnaise, reduced fat, with olive oil"),
        (171477, "sr_legacy", "Chicken, broilers or fryers, breast, meat only, cooked, roasted"),
        (171478, "sr_legacy", "Chicken, broilers or fryers, breast, meat only, cooked, stewed"),
        (171534, "sr_legacy", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled"),
        (172185, "sr_legacy", "Egg, whole, cooked, omelet"),
        (172187, "sr_legacy", "Egg, whole, cooked, scrambled"),
        (172188, "sr_legacy", "Egg, whole, dried"),
        (172225, "sr_legacy", "Milk, buttermilk, fluid, whole"),
        (172469, "sr_legacy", "Peanut butter, chunk style, without salt"),
        (172470, "sr_legacy", "Peanut butter, smooth style, without salt"),
        (172678, "sr_legacy", "Bread, oatmeal"),
        (173423, "sr_legacy", "Egg, whole, cooked, fried"),
        (173687, "sr_legacy", "Fish, salmon, chinook, smoked"),
        (173734, "sr_legacy", "Beans, black, mature seeds, raw"),
        (173735, "sr_legacy", "Beans, black, mature seeds, cooked, boiled, without salt"),
        (173944, "sr_legacy", "Bananas, raw"),
        (174265, "sr_legacy", "Peanut butter, chunk style, with salt"),
        (174266, "sr_legacy", "Peanut butter, smooth style, with salt (Includes foods for USDA's Food Distribution Program)"),
        (174294, "sr_legacy", "Peanut Butter, smooth (Includes foods for USDA's Food Distribution Program)"),
        (175186, "sr_legacy", "Beans, black turtle, mature seeds, raw"),
        (175187, "sr_legacy", "Beans, black turtle, mature seeds, cooked, boiled, without salt"),
        (175237, "sr_legacy", "Beans, black, mature seeds, cooked, boiled, with salt"),
        (324860, "foundation", "Peanut butter, smooth style, with salt"),
        (790774, "foundation", "Bananas, overripe, raw"),
        (790991, "foundation", "Bananas, ripe and slightly ripe, raw"),
        (2259796, "foundation", "Cheese, feta, whole milk, crumbled"),
        (2262072, "foundation", "Peanut butter, creamy"),
        (2705385, "survey", "Milk, whole"),
        (2705399, "survey", "Milk, evaporated, whole"),
        (2705467, "survey", "Chocolate milk, whole"),
        (2705660, "survey", "Banana split"),
        (2705966, "survey", "Chicken breast, stewed, skin not eaten"),
        (2705967, "survey", "Chicken breast, grilled without sauce, skin eaten"),
        (2705968, "survey", "Chicken breast, grilled without sauce, skin not eaten"),
        (2705969, "survey", "Chicken breast, grilled with sauce, skin eaten"),
        (2705970, "survey", "Chicken breast, grilled with sauce, skin not eaten"),
        (2705972, "survey", "Chicken breast, sauteed, skin not eaten"),
        (2706245, "survey", "Fish, cod, steamed"),
        (2706285, "survey", "Fish, salmon, NFS"),
        (2706286, "survey", "Fish, salmon, baked or broiled"),
        (2706287, "survey", "Fish, salmon, grilled"),
        (2706288, "survey", "Fish, salmon, baked or broiled, coated"),
        (2706289, "survey", "Fish, salmon, fried"),
        (2706290, "survey", "Fish, salmon, steamed"),
        (2706292, "survey", "Fish, salmon, smoked"),
        (2706299, "survey", "Fish, bass, steamed"),
        (2706353, "survey", "Oysters, steamed"),
        (2707179, "survey", "Egg, creamed"),
        (2707180, "survey", "Egg, Benedict"),
        (2707181, "survey", "Egg, deviled"),
        (2707205, "survey", "Egg omelet or scrambled egg, no added fat"),
        (2707359, "survey", "Black beans, NFS"),
        (2707361, "survey", "Black beans, from dried, no added fat"),
        (2707366, "survey", "Black beans with meat"),
        (2707395, "survey", "Black bean salad"),
        (2707404, "survey", "Black bean sauce"),
        (2707537, "survey", "Peanut butter"),
        (2707543, "survey", "Peanut butter and jelly"),
        (2707945, "survey", "Cookie, oatmeal"),
        (2707946, "survey", "Cookie, oatmeal, with raisins"),
        (2707986, "survey", "Cookie, oatmeal, reduced sugar"),
        (2708016, "survey", "Pie, oatmeal"),
        (2708380, "survey", "Oatmeal, NFS"),
        (2708381, "survey", "Oatmeal, regular or quick, made with water, no added fat"),
        (2708382, "survey", "Oatmeal, regular or quick, made with water, fat added"),
        (2708383, "survey", "Oatmeal, regular or quick, made with milk, no added fat"),
        (2708387, "survey", "Oatmeal, instant, plain, made with water, no added fat"),
        (2708398, "survey", "Oatmeal, multigrain"),
        (2708403, "survey", "Rice, white, cooked, NS as to fat"),
        (2708404, "survey", "Rice, white, cooked, made with oil"),
        (2708408, "survey", "Rice, white, cooked, no added fat"),
        (2708422, "survey", "Rice, white, cooked, glutinous"),
        (2708612, "survey", "Pizza, cheese, from frozen, thin crust"),
        (2708613, "survey", "Pizza, cheese, from frozen, thick crust"),
        (2708618, "survey", "Pizza, cheese, stuffed crust"),
        (2708622, "survey", "Pizza, extra cheese, thin crust"),
        (2708623, "survey", "Pizza, extra cheese, thick crust"),
        (2708674, "survey", "Pizza, no cheese, thin crust"),
        (2708675, "survey", "Pizza, no cheese, thick crust"),
        (2708687, "survey", "Pizza, cheese, whole wheat thin crust"),
        (2709224, "survey", "Banana, raw"),
        (2709225, "survey", "Banana, baked"),
        (2709342, "survey", "Banana nectar"),
        (2709645, "survey", "Broccoli, fresh, cooked, no added fat"),
        (2709646, "survey", "Broccoli, frozen, cooked, no added fat"),
        (2709647, "survey", "Broccoli, NS as to form, cooked"),
        (2710186, "survey", "Olive oil"),
        (2710221, "survey", "Mayonnaise, reduced fat,  with olive oil"),
        (2710792, "survey", "Broccoli, cooked, as ingredient"),
        (2747652, "foundation", "Anchovies, canned in olive oil, with salt, drained"),
    ];

    #[test]
    fn the_plainest_matching_name_wins() {
        let db = db::memory();
        let items: Vec<Value> = REAL
            .iter()
            .map(|(id, dataset, name)| json!({"fdc_id": id, "dataset": dataset, "name": name, "nutrients": {"kcal": 100}, "portions": []}))
            .collect();
        import(&db, &items).unwrap();
        finish(&db, &json!([])).unwrap();
        let cases: &[(&str, &[&str])] = &[
            ("chicken breast grilled", &["Chicken breast, grilled without sauce, skin not eaten",
                                         "Chicken, broilers or fryers, breast, meat only, cooked, roasted",
                                         "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled"]),
            ("rice white cooked", &["Rice, white, cooked, no added fat", "Rice, white, cooked, NS as to fat",
                                    "Rice, white, long-grain, regular, enriched, cooked"]),
            ("rice white cooked no added fat", &["Rice, white, cooked, no added fat"]),
            ("banana raw", &["Bananas, raw"]),
            ("egg scrambled", &["Egg, whole, cooked, scrambled", "Egg omelet or scrambled egg, no added fat"]),
            ("oatmeal cooked", &["Oatmeal, NFS", "Oatmeal, regular or quick, made with water, no added fat"]),
            ("broccoli steamed", &["Broccoli, cooked, boiled, drained, without salt", "Broccoli, fresh, cooked, no added fat"]),
            ("pizza cheese", &["Pizza, cheese topping, thin crust, frozen, cooked", "Pizza, cheese topping, regular crust, frozen, cooked",
                               "Pizza, cheese, from frozen, thin crust"]),
            ("salmon baked", &["Fish, salmon, baked or broiled"]),
            ("black beans", &["Black beans, NFS", "Beans, black, mature seeds, cooked, boiled, without salt"]),
            ("whole milk", &["Milk, whole", "Milk, whole, 3.25% milkfat, with added vitamin D"]),
            ("peanut butter", &["Peanut butter", "Peanut butter, smooth style, with salt", "Peanut butter, creamy"]),
            ("olive oil", &["Olive oil", "Oil, olive, salad or cooking"]),
        ];
        for (query, accepted) in cases {
            let top: Vec<String> = search(&db, query, 3).unwrap().iter().map(|r| r["name"].as_str().unwrap().to_string()).collect();
            assert!(accepted.contains(&top[0].as_str()), "{query:?} picked {top:?}");
        }
    }

    #[test]
    fn distance_reads_qualifiers() {
        let words = |q: &str| tokens(q);
        let d = |name: &str, q: &str| distance(name, "sr_legacy", &words(q));
        assert!(d("Pizza, cheese, thin crust", "pizza cheese") < d("Pizza, no cheese, thin crust", "pizza cheese"));
        assert!(d("Chicken breast, grilled without sauce", "chicken breast grilled") < d("Chicken breast, grilled with sauce", "chicken breast grilled"));
        assert!(d("Bananas, raw", "banana") < d("Pepper, banana, raw", "banana"));
        assert!(d("Rice, cooked", "rice") < d("Rice crackers", "rice"));
        assert!(d("Pizza, cheese", "pizza") < d("DIGIORNO Pizza, cheese", "pizza"));
        assert!(d("Broccoli, cooked, boiled", "broccoli steamed") < d("Broccoli, raw", "broccoli steamed"));
        assert_eq!(root("bananas").0, root("banana").0);
        assert_eq!(root("rolled").0, root("rolls").0);
        assert_ne!(root("rolled").1, root("rolls").1);
        assert!(fts_query(&words("chicken grilled"), " AND ", true).unwrap().contains("(\"grilled\"* OR \"broiled\""));
    }

    #[test]
    fn search_and_resolve() {
        let db = seeded();
        assert_eq!(search(&db, "banana raw", 5).unwrap()[0]["fdc_id"], 173944);
        assert_eq!(search(&db, "pizzas", 5).unwrap()[0]["fdc_id"], 2);
        assert_eq!(resolve(&db, "fdc:1").unwrap()["name"], "Banana bread");
        assert_eq!(resolve(&db, "banana bread").unwrap()["fdc_id"], 1);
        assert!(resolve(&db, "zzzz").is_err());
        assert!(search(&db, "\"*", 5).unwrap().is_empty());
    }

    #[test]
    fn catalog_items_become_foods() {
        let db = seeded();
        let food = to_food(&by_id(&db, 173944).unwrap().unwrap());
        assert_eq!(food["source_ref"], "fdc:173944");
        assert_eq!(food["serving"]["grams"], 118);
        assert_eq!(food["serving"]["unit"], "medium (7\" to 7-7/8\" long)");
        assert_eq!(food["nutrients"]["kcal"], json!(105.02));
        let pizza = to_food(&by_id(&db, 2).unwrap().unwrap());
        assert_eq!(pizza["serving"], json!({"amount": 100, "unit": "g", "grams": 100}));
        assert_eq!(split_amount("1/2 cup"), (0.5, "cup".to_string()));
        assert_eq!(split_amount("serving"), (1.0, "serving".to_string()));
    }
}
