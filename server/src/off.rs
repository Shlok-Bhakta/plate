//! Open Food Facts: barcode lookups (cached, misses for a day) and a quick text search. The data
//! is Open Food Facts' (openfoodfacts.org), under the Open Database License (ODbL). Requests carry
//! a User-Agent naming Plate and, if set, the `off_contact` setting.

use crate::{catalog, nutrients, store};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::time::Duration;

const FIELDS: &str = "code,product_name,product_name_en,generic_name,brands,serving_size,serving_quantity,nutriments";
const DAY_MS: i64 = 86_400_000;

/// (nutrient key, OFF field, factor from OFF's unit): OFF stores masses per 100 g in grams.
const MAP: &[(&str, &str, f64)] = &[
    ("kcal", "energy-kcal", 1.0), ("protein", "proteins", 1.0), ("carbs", "carbohydrates", 1.0), ("fat", "fat", 1.0),
    ("fiber", "fiber", 1.0), ("sugar", "sugars", 1.0), ("added_sugar", "added-sugars", 1.0),
    ("sat_fat", "saturated-fat", 1.0), ("trans_fat", "trans-fat", 1.0), ("mono_fat", "monounsaturated-fat", 1.0),
    ("poly_fat", "polyunsaturated-fat", 1.0), ("omega3", "omega-3-fat", 1.0), ("cholesterol", "cholesterol", 1e3),
    ("sodium", "sodium", 1e3), ("potassium", "potassium", 1e3), ("calcium", "calcium", 1e3), ("iron", "iron", 1e3),
    ("magnesium", "magnesium", 1e3), ("phosphorus", "phosphorus", 1e3), ("zinc", "zinc", 1e3), ("copper", "copper", 1e3),
    ("manganese", "manganese", 1e3), ("selenium", "selenium", 1e6), ("iodine", "iodine", 1e6),
    ("vit_a", "vitamin-a", 1e6), ("vit_c", "vitamin-c", 1e3), ("vit_d", "vitamin-d", 1e6), ("vit_e", "vitamin-e", 1e3),
    ("vit_k", "vitamin-k", 1e6), ("thiamin", "vitamin-b1", 1e3), ("riboflavin", "vitamin-b2", 1e3), ("niacin", "vitamin-pp", 1e3),
    ("pantothenic", "pantothenic-acid", 1e3), ("vit_b6", "vitamin-b6", 1e3), ("biotin", "biotin", 1e6),
    ("folate", "vitamin-b9", 1e6), ("vit_b12", "vitamin-b12", 1e6), ("choline", "choline", 1e3), ("caffeine", "caffeine", 1e3),
];

fn number(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())).filter(|x: &f64| x.is_finite() && *x >= 0.0)
}

pub fn per_100g(nutriments: &Value) -> Value {
    let mut out = Map::new();
    for (key, field, factor) in MAP {
        if let Some(x) = number(&nutriments[format!("{field}_100g")]) {
            out.insert(key.to_string(), json!(nutrients::round(x * factor)));
        }
    }
    if !out.contains_key("kcal") {
        if let Some(kj) = number(&nutriments["energy_100g"]) {
            out.insert("kcal".into(), json!(nutrients::round(kj / 4.184)));
        }
    }
    if !out.contains_key("sodium") {
        if let Some(salt) = number(&nutriments["salt_100g"]) {
            out.insert("sodium".into(), json!(nutrients::round(salt * 400.0)));
        }
    }
    // Alcohol is % vol; ethanol is 0.789 g/ml.
    if let Some(abv) = number(&nutriments["alcohol_100g"]).filter(|a| *a > 0.0) {
        out.insert("alcohol".into(), json!(nutrients::round(abv * 0.789)));
    }
    Value::Object(out)
}

/// An OFF product as an unsaved Food. None when it has no name or no calories.
pub fn to_food(product: &Value, code: &str) -> Option<Value> {
    let name = ["product_name_en", "product_name", "generic_name"]
        .iter()
        .find_map(|k| product[*k].as_str().map(str::trim).filter(|s| !s.is_empty()))?;
    let per100 = per_100g(&product["nutriments"]);
    per100.get("kcal")?;
    let brand = match &product["brands"] {
        Value::Array(list) => list.first().and_then(Value::as_str).map(str::to_string),
        Value::String(s) => s.split(',').next().map(|b| b.trim().to_string()),
        _ => None,
    }
    .filter(|b| !b.is_empty());
    let grams = number(&product["serving_quantity"]).filter(|g| *g > 0.0 && *g < 5000.0);
    let label = product["serving_size"].as_str().map(str::trim).filter(|s| !s.is_empty());
    let (serving, mut portions) = match grams {
        Some(g) => {
            let (amount, unit) = catalog::split_amount(label.unwrap_or("serving"));
            (json!({"amount": amount, "unit": unit, "grams": g}), vec![json!({"label": label.unwrap_or("1 serving"), "grams": g})])
        }
        None => (json!({"amount": 100, "unit": "g", "grams": 100}), vec![]),
    };
    portions.push(json!({"label": "100 g", "grams": 100}));
    let g = serving["grams"].as_f64().unwrap_or(100.0);
    Some(json!({
        "id": null, "kind": "food", "name": name, "brand": brand, "barcode": code,
        "serving": serving, "portions": portions, "nutrients": nutrients::scale(&per100, g / 100.0),
        "components": [], "recipe_servings": null, "source": "off", "source_ref": format!("off:{code}"), "favorite": false,
    }))
}

fn agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(timeout).user_agent(&crate::config::get().user_agent()).build()
}

/// Fetches a product. Ok(None) is a real miss; Err is a network problem (not cached).
pub fn fetch(code: &str) -> Result<Option<Value>, String> {
    let url = format!("https://world.openfoodfacts.org/api/v2/product/{code}.json?fields={FIELDS}");
    match agent(Duration::from_secs(8)).get(&url).call() {
        Ok(response) => {
            let body: Value = serde_json::from_str(&response.into_string().map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
            Ok((body["status"].as_i64() == Some(1)).then(|| to_food(&body["product"], code)).flatten())
        }
        Err(ureq::Error::Status(404, _)) => Ok(None),
        Err(e) => Err(format!("Open Food Facts: {e}")),
    }
}

pub enum Cached {
    Hit(Value),
    Miss,
    Unknown,
}

pub fn cached(db: &Connection, code: &str, now: i64) -> Result<Cached, String> {
    let row: Option<(i64, Option<String>)> = db
        .query_row("SELECT fetched_at, food FROM off_cache WHERE barcode = ?1", [store::normal_barcode(code)], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(|e| e.to_string())?;
    Ok(match row {
        Some((_, Some(food))) => Cached::Hit(serde_json::from_str(&food).map_err(|e| e.to_string())?),
        Some((at, None)) if now - at < DAY_MS => Cached::Miss,
        _ => Cached::Unknown,
    })
}

pub fn remember(db: &Connection, code: &str, food: Option<&Value>, now: i64) -> Result<(), String> {
    db.execute("INSERT OR REPLACE INTO off_cache (barcode, fetched_at, food) VALUES (?1, ?2, ?3)",
               params![store::normal_barcode(code), now, food.map(Value::to_string)])
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Text search, giving up after `timeout`.
pub fn search(text: &str, limit: usize, timeout: Duration) -> Vec<Value> {
    let text = text.to_string();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let found = agent(timeout)
            .get("https://search.openfoodfacts.org/search")
            .query("q", &text)
            .query("page_size", &limit.to_string())
            .query("fields", FIELDS)
            .query("langs", "en")
            .call()
            .ok()
            .and_then(|r| r.into_string().ok())
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .map(|body| {
                body["hits"].as_array().cloned().unwrap_or_default().iter()
                    .filter_map(|hit| hit["code"].as_str().and_then(|code| to_food(hit, code)))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let _ = tx.send(found);
    });
    rx.recv_timeout(timeout).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn products_map_to_foods_in_our_units() {
        let product = json!({"product_name": "Nutella", "brands": "Nutella, Ferrero", "serving_size": "15 g", "serving_quantity": "15",
            "nutriments": {"energy-kcal_100g": 539, "proteins_100g": 6.3, "fat_100g": 30.9, "sodium_100g": 0.0428,
                           "calcium_100g": 0.12, "vitamin-d_100g": 0.000002, "alcohol_100g": 0}});
        let food = to_food(&product, "3017620422003").unwrap();
        assert_eq!(food["brand"], "Nutella");
        assert_eq!(food["serving"], json!({"amount": 15.0, "unit": "g", "grams": 15.0}));
        assert_eq!(food["nutrients"]["kcal"], json!(80.85));
        assert_eq!(food["nutrients"]["sodium"], json!(6.42));
        assert_eq!(food["nutrients"]["calcium"], json!(18.0));
        assert_eq!(food["nutrients"]["vit_d"], json!(0.3));
        assert!(food["nutrients"].get("alcohol").is_none());
        assert_eq!(food["source_ref"], "off:3017620422003");
        assert!(to_food(&json!({"product_name": "Water"}), "1").is_none());
        let salted = per_100g(&json!({"energy_100g": 418.4, "salt_100g": 1.0}));
        assert_eq!(salted, json!({"kcal": 100.0, "sodium": 400.0}));
    }
}
