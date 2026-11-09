//! The fixed nutrient keys shared by the server, CLI, app and agents, with units, groups, FDA daily
//! values and adult RDAs. A nutrient map is a JSON object `{key: number}`; a missing key is unknown.

use serde_json::{json, Map, Value};

pub struct Nutrient {
    pub key: &'static str,
    pub name: &'static str,
    pub unit: &'static str,
    pub group: &'static str,
    /// FDA daily value for adults and children 4+ (2016 label rule). None: no DV.
    pub dv: Option<f64>,
    /// Adult RDA or AI, (male, female), for ages 19-50, where it differs from the DV.
    pub rda: Option<(f64, f64)>,
}

const fn n(key: &'static str, name: &'static str, unit: &'static str, group: &'static str, dv: Option<f64>, rda: Option<(f64, f64)>) -> Nutrient {
    Nutrient { key, name, unit, group, dv, rda }
}

pub const ALL: &[Nutrient] = &[
    n("kcal", "Calories", "kcal", "macro", Some(2000.0), None),
    n("protein", "Protein", "g", "macro", Some(50.0), None),
    n("carbs", "Carbohydrates", "g", "macro", Some(275.0), None),
    n("fat", "Fat", "g", "macro", Some(78.0), None),
    n("fiber", "Fiber", "g", "macro", Some(28.0), None),
    n("sugar", "Sugars", "g", "macro", None, None),
    n("added_sugar", "Added sugars", "g", "macro", Some(50.0), None),
    n("sat_fat", "Saturated fat", "g", "fat", Some(20.0), None),
    n("trans_fat", "Trans fat", "g", "fat", None, None),
    n("mono_fat", "Monounsaturated fat", "g", "fat", None, None),
    n("poly_fat", "Polyunsaturated fat", "g", "fat", None, None),
    n("omega3", "Omega-3", "g", "fat", None, Some((1.6, 1.1))),
    n("cholesterol", "Cholesterol", "mg", "fat", Some(300.0), None),
    n("sodium", "Sodium", "mg", "mineral", Some(2300.0), None),
    n("potassium", "Potassium", "mg", "mineral", Some(4700.0), Some((3400.0, 2600.0))),
    n("calcium", "Calcium", "mg", "mineral", Some(1300.0), Some((1000.0, 1000.0))),
    n("iron", "Iron", "mg", "mineral", Some(18.0), Some((8.0, 18.0))),
    n("magnesium", "Magnesium", "mg", "mineral", Some(420.0), Some((420.0, 320.0))),
    n("phosphorus", "Phosphorus", "mg", "mineral", Some(1250.0), Some((700.0, 700.0))),
    n("zinc", "Zinc", "mg", "mineral", Some(11.0), Some((11.0, 8.0))),
    n("copper", "Copper", "mg", "mineral", Some(0.9), None),
    n("manganese", "Manganese", "mg", "mineral", Some(2.3), Some((2.3, 1.8))),
    n("selenium", "Selenium", "ug", "mineral", Some(55.0), None),
    n("iodine", "Iodine", "ug", "mineral", Some(150.0), None),
    n("vit_a", "Vitamin A (RAE)", "ug", "vitamin", Some(900.0), Some((900.0, 700.0))),
    n("vit_c", "Vitamin C", "mg", "vitamin", Some(90.0), Some((90.0, 75.0))),
    n("vit_d", "Vitamin D", "ug", "vitamin", Some(20.0), Some((15.0, 15.0))),
    n("vit_e", "Vitamin E", "mg", "vitamin", Some(15.0), None),
    n("vit_k", "Vitamin K", "ug", "vitamin", Some(120.0), Some((120.0, 90.0))),
    n("thiamin", "Thiamin (B1)", "mg", "vitamin", Some(1.2), Some((1.2, 1.1))),
    n("riboflavin", "Riboflavin (B2)", "mg", "vitamin", Some(1.3), Some((1.3, 1.1))),
    n("niacin", "Niacin (B3)", "mg", "vitamin", Some(16.0), Some((16.0, 14.0))),
    n("pantothenic", "Pantothenic acid (B5)", "mg", "vitamin", Some(5.0), None),
    n("vit_b6", "Vitamin B6", "mg", "vitamin", Some(1.7), Some((1.3, 1.3))),
    n("biotin", "Biotin (B7)", "ug", "vitamin", Some(30.0), None),
    n("folate", "Folate (DFE)", "ug", "vitamin", Some(400.0), None),
    n("vit_b12", "Vitamin B12", "ug", "vitamin", Some(2.4), None),
    n("choline", "Choline", "mg", "vitamin", Some(550.0), Some((550.0, 425.0))),
    n("caffeine", "Caffeine", "mg", "other", None, None),
    n("alcohol", "Alcohol", "g", "other", None, None),
    n("water", "Water", "ml", "other", None, None),
];

pub fn find(key: &str) -> Option<&'static Nutrient> {
    ALL.iter().find(|n| n.key == key)
}

/// Nutrients whose targets are ceilings, not floors.
pub const DEFAULT_LIMITS: &[&str] = &["sodium", "sat_fat", "added_sugar", "cholesterol"];

/// `GET /v1/meta`.
pub fn meta() -> Value {
    let list: Vec<Value> = ALL
        .iter()
        .map(|n| json!({"key": n.key, "name": n.name, "unit": n.unit, "group": n.group, "dv": n.dv,
                        "limit": DEFAULT_LIMITS.contains(&n.key)}))
        .collect();
    json!({"nutrients": list, "meals": ["breakfast", "lunch", "dinner", "snack"],
           "groups": ["macro", "fat", "mineral", "vitamin", "other"], "timezone": crate::time::zone_name()})
}

/// Rounds to 3 decimals, enough for micrograms of B12 and whole kcal alike.
pub fn round(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

/// The largest amount a row may carry (grams, servings, a nutrient): far past any real food, and
/// small enough that clients can turn it into an integer.
pub const MAX_AMOUNT: f64 = 1e9;

/// Keeps only known keys with numbers from 0 to MAX_AMOUNT.
pub fn clean(map: &Value) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(object) = map.as_object() {
        for (key, value) in object {
            if let (Some(_), Some(x)) = (find(key), value.as_f64().filter(|x| (0.0..=MAX_AMOUNT).contains(x))) {
                out.insert(key.clone(), json!(round(x)));
            }
        }
    }
    out
}

pub fn scale(map: &Value, factor: f64) -> Value {
    let mut out = Map::new();
    if let Some(object) = map.as_object() {
        for (key, value) in object {
            if let Some(x) = value.as_f64() {
                out.insert(key.clone(), json!(round(x * factor)));
            }
        }
    }
    Value::Object(out)
}

/// Adds `b` into `a`. A key known in either stays known.
pub fn add_into(a: &mut Map<String, Value>, b: &Value) {
    if let Some(object) = b.as_object() {
        for (key, value) in object {
            if let Some(x) = value.as_f64() {
                let sum = a.get(key).and_then(Value::as_f64).unwrap_or(0.0) + x;
                a.insert(key.clone(), json!(round(sum)));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_unique_and_scaling_keeps_unknowns_unknown() {
        let mut keys: Vec<&str> = ALL.iter().map(|n| n.key).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), ALL.len());
        assert_eq!(ALL.len(), 41);
        let half = scale(&json!({"kcal": 90, "protein": 18}), 0.5);
        assert_eq!(half, json!({"kcal": 45.0, "protein": 9.0}));
        assert!(half.get("fat").is_none());
        let cleaned = clean(&json!({"kcal": 10, "bogus": 3, "fat": -1, "sodium": "x", "iron": 1e300}));
        assert_eq!(Value::Object(cleaned), json!({"kcal": 10.0}));
    }
}
