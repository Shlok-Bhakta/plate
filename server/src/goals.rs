//! Adaptive goals. In auto mode the basis comes from the profile (set by hand with `food goals
//! profile`, or by a health import or refresh) and the health days: latest weight, height, age,
//! sex and 14-day active energy. BMR is Mifflin-St Jeor, and the plan adjusts TDEE. Overrides
//! always win. Personal numbers are never invented: without data the basis says why.

use crate::{db, nutrients, store, time};
use rusqlite::Connection;
use serde_json::{json, Map, Value};

pub const DEFAULT_KCAL: f64 = 2200.0;
/// Without active energy, TDEE is BMR times this (or the profile's activity_factor).
pub const ACTIVITY_FACTOR: f64 = 1.35;
const NO_PROFILE: &str = "no profile or health data yet: default 2,200 kcal (set weight, height, age and sex with `food goals profile`, or import health data)";

pub fn default_row() -> Value {
    let mut row = json!({
        "id": "current", "mode": "auto", "plan": "maintain", "targets": {}, "overrides": {},
        "limits": nutrients::DEFAULT_LIMITS, "basis": {"note": NO_PROFILE, "computed_at": 0},
        "meal_split": {"breakfast": 0.25, "lunch": 0.35, "dinner": 0.3, "snack": 0.1},
        "water_ml": 3000, "updated_at": 0, "deleted": false
    });
    apply_targets(&mut row);
    row
}

/// Fills missing fields with defaults and drops nonsense values.
pub fn fill(goals: &mut Value) {
    if !matches!(goals["mode"].as_str(), Some("auto" | "manual")) {
        goals["mode"] = json!("auto");
    }
    if !matches!(goals["plan"].as_str(), Some("maintain" | "cut" | "bulk")) {
        goals["plan"] = json!("maintain");
    }
    goals["overrides"] = Value::Object(nutrients::clean(&goals["overrides"]));
    goals["targets"] = Value::Object(nutrients::clean(&goals["targets"]));
    if !goals["limits"].is_array() {
        goals["limits"] = json!(nutrients::DEFAULT_LIMITS);
    }
    if !goals["meal_split"].is_object() {
        goals["meal_split"] = json!({"breakfast": 0.25, "lunch": 0.35, "dinner": 0.3, "snack": 0.1});
    }
    if !goals["water_ml"].as_f64().is_some_and(|w| w > 0.0) {
        goals["water_ml"] = json!(if goals["basis"]["sex"] == "female" { 2200 } else { 3000 });
    }
    if !goals["basis"].is_object() {
        goals["basis"] = json!({});
    }
    goals["deleted"] = json!(false);
}

fn round_to(x: f64, step: f64) -> f64 {
    (x / step).round() * step
}

/// The RDA for this sex and age where it's more precise than the DV, else the DV.
fn micro_target(n: &nutrients::Nutrient, sex: Option<&str>, age: Option<i64>) -> Option<f64> {
    let rda = n.rda.and_then(|(male, female)| match sex {
        Some("male") => Some(male),
        Some("female") => Some(female),
        _ => None,
    });
    if n.key == "magnesium" && age.is_some_and(|a| a < 31) {
        // 19-30 year olds: 400 mg (men), 310 mg (women).
        return rda.map(|r| if sex == Some("male") { r - 20.0 } else { r - 10.0 }).or(n.dv);
    }
    rda.or(n.dv)
}

/// Recomputes `targets` from mode, plan, basis and overrides.
pub fn apply_targets(goals: &mut Value) {
    let overrides = nutrients::clean(&goals["overrides"]);
    let get = |key: &str| overrides.get(key).and_then(Value::as_f64);
    let mut targets = if goals["mode"] == "manual" {
        nutrients::clean(&goals["targets"])
    } else {
        let basis = &goals["basis"];
        let plan = goals["plan"].as_str().unwrap_or("maintain");
        let base = match basis["tdee"].as_f64() {
            Some(tdee) => round_to(tdee * match plan { "cut" => 0.8, "bulk" => 1.1, _ => 1.0 }, 10.0),
            None => DEFAULT_KCAL,
        };
        let kcal = get("kcal").unwrap_or(base);
        let protein = get("protein").unwrap_or_else(|| match basis["weight_kg"].as_f64() {
            Some(kg) => (kg * if plan == "cut" { 2.0 } else { 1.8 }).round(),
            None => (kcal * 0.2 / 4.0).round(),
        });
        let fat = get("fat").unwrap_or_else(|| (kcal * 0.3 / 9.0).round());
        let carbs = get("carbs").unwrap_or_else(|| ((kcal - protein * 4.0 - fat * 9.0) / 4.0).max(0.0).round());
        let mut t = Map::new();
        t.insert("kcal".into(), json!(kcal));
        t.insert("protein".into(), json!(protein));
        t.insert("fat".into(), json!(fat));
        t.insert("carbs".into(), json!(carbs));
        t.insert("fiber".into(), json!((kcal * 14.0 / 1000.0).round()));
        // Saturated fat and added sugar: under 10% of calories each (the basis of their DVs).
        t.insert("sat_fat".into(), json!((kcal * 0.1 / 9.0).round()));
        t.insert("added_sugar".into(), json!((kcal * 0.1 / 4.0).round()));
        let (sex, age) = (basis["sex"].as_str(), basis["age"].as_i64());
        for n in nutrients::ALL {
            if t.contains_key(n.key) || n.group == "macro" {
                continue;
            }
            if let Some(value) = micro_target(n, sex, age) {
                t.insert(n.key.into(), json!(value));
            }
        }
        t
    };
    if let Some(water) = goals["water_ml"].as_f64() {
        targets.entry("water").or_insert(json!(water));
    }
    for (key, value) in overrides {
        targets.insert(key, value);
    }
    goals["targets"] = Value::Object(targets);
}

/// The basis from the stored profile (dob or age, sex, height_cm, weight_kg and weight_day,
/// activity_factor, active_through) and recent health days, which may carry newer weighings.
pub fn basis_from(profile: &Value, days: &[Value], today: &str, previous: &Value) -> Value {
    // The newest weighing: the profile's, or a health day's if that's later.
    let mut weight = profile["weight_kg"].as_f64().filter(|w| *w > 20.0).map(|w| (w, profile["weight_day"].as_str().unwrap_or("").to_string()));
    for d in days {
        if let (Some(kg), Some(day)) = (d["weight_kg"].as_f64().filter(|w| *w > 20.0), d["day"].as_str()) {
            // A health day wins a tie with the profile: it's measured, not typed in.
            if weight.as_ref().is_none_or(|(_, on)| day >= on.as_str()) {
                weight = Some((kg, day.to_string()));
            }
        }
    }
    let height = profile["height_cm"].as_f64().filter(|h| *h > 100.0);
    let sex = profile["sex"].as_str().filter(|s| matches!(*s, "male" | "female"));
    let age = profile["dob"].as_str().and_then(|dob| time::age(dob, today)).or_else(|| {
        // An age given by hand counts up from the day it was given.
        let given = profile["age"].as_f64()? as i64;
        let since = profile["age_on"].as_str().and_then(|on| time::age(on, today)).unwrap_or(0);
        Some(given + since.max(0))
    }).filter(|a| (14..=110).contains(a));
    let mut missing = Vec::new();
    if weight.is_none() { missing.push("weight"); }
    if height.is_none() { missing.push("height"); }
    if age.is_none() { missing.push("age (or date of birth)"); }
    if sex.is_none() { missing.push("sex"); }
    if !missing.is_empty() {
        let note = format!("missing {}: set it with `food goals profile` or import health data", missing.join(", "));
        if previous["tdee"].is_number() {
            let mut kept = previous.clone();
            kept["note"] = json!(format!("{note}; kept the last basis"));
            return kept;
        }
        return json!({"note": format!("{note}; default 2,200 kcal"), "computed_at": time::now_ms()});
    }
    let ((w, weight_day), h, a) = (weight.unwrap(), height.unwrap(), age.unwrap());
    let bmr = 10.0 * w + 6.25 * h - 5.0 * a as f64 + if sex == Some("male") { 5.0 } else { -161.0 };
    // The 14 days ending at the last fully synced day; today and the latest day are usually partial.
    let through = profile["active_through"].as_str().map(str::to_string).or_else(|| time::add_days(today, -1)).unwrap_or_default();
    let from = time::add_days(&through, -13).unwrap_or_default();
    let active: Vec<f64> = days
        .iter()
        .filter(|d| d["day"].as_str().is_some_and(|day| day >= from.as_str() && day <= through.as_str()))
        .filter_map(|d| d["active_kcal"].as_f64())
        .collect();
    let weight_day = if weight_day.is_empty() { Value::Null } else { json!(weight_day) };
    let mut basis = json!({
        "weight_kg": nutrients::round(w), "weight_day": weight_day, "height_cm": (h * 10.0).round() / 10.0,
        "age": a, "sex": sex, "bmr": bmr.round(), "computed_at": time::now_ms(),
    });
    if active.len() >= 5 {
        let avg = active.iter().sum::<f64>() / active.len() as f64;
        basis["active_kcal_avg14"] = json!(avg.round());
        basis["active_days"] = json!(active.len());
        basis["tdee"] = json!((bmr + avg).round());
        basis["note"] = json!(format!("BMR (Mifflin-St Jeor) + average active energy over {} days, {from} to {through}", active.len()));
    } else {
        let factor = profile["activity_factor"].as_f64().filter(|f| (1.0..=2.5).contains(f));
        let f = factor.unwrap_or(ACTIVITY_FACTOR);
        basis["tdee"] = json!((bmr * f).round());
        basis["activity_factor"] = json!(f);
        basis["note"] = json!(match (active.len(), factor) {
            (0, Some(_)) => format!("no active energy data: TDEE = BMR x {f} (the profile's activity factor)"),
            (0, None) => format!("no active energy data: TDEE = BMR x {f} (change it with `food goals profile activity=...`)"),
            (n, _) => format!("only {n} days of active energy from {from} to {through}: TDEE = BMR x {f}"),
        });
    }
    basis
}

pub fn current(db: &Connection) -> Result<Value, String> {
    Ok(store::live(db, "goals", "current")?.unwrap_or_else(default_row))
}

/// Recomputes the basis from the stored profile and health days and writes the goals row if
/// anything changed. Keeps `updated_at`, which belongs to the last person who edited the goals.
pub fn recompute(db: &Connection) -> Result<Value, String> {
    let stored = store::live(db, "goals", "current")?;
    let mut goals = stored.clone().unwrap_or_else(default_row);
    fill(&mut goals);
    let profile: Value = db::meta_get(db, "profile").and_then(|p| serde_json::from_str(&p).ok()).unwrap_or(json!({}));
    let today = time::today();
    let from = time::add_days(&today, -30).unwrap_or_default();
    let days = store::select(db, "health_days", "day >= ?1", &[&from])?;
    let basis = basis_from(&profile, &days, &today, &goals["basis"]);
    let strip = |b: &Value| {
        let mut b = b.clone();
        if let Some(o) = b.as_object_mut() { o.remove("computed_at"); }
        b
    };
    if strip(&basis) != strip(&goals["basis"]) {
        goals["basis"] = basis;
    }
    apply_targets(&mut goals);
    if stored.as_ref() != Some(&goals) {
        store::put(db, "goals", &goals)?;
    }
    Ok(goals)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile() -> Value {
        json!({"dob": "2004-07-07", "sex": "male", "height_cm": 180.0, "weight_kg": 80.0, "active_through": "2026-11-06"})
    }

    fn days(n: i64, kcal: f64) -> Vec<Value> {
        (0..n).map(|i| json!({"day": time::add_days("2026-11-06", -i).unwrap(), "active_kcal": kcal})).collect()
    }

    #[test]
    fn mifflin_st_jeor_plus_active_energy() {
        let basis = basis_from(&profile(), &days(20, 500.0), "2026-11-08", &json!({}));
        // 10*80 + 6.25*180 - 5*22 + 5 = 1820
        assert_eq!(basis["bmr"], json!(1820.0));
        assert_eq!(basis["active_kcal_avg14"], json!(500.0));
        assert_eq!(basis["active_days"], json!(14));
        assert_eq!(basis["tdee"], json!(2320.0));
        let mut goals = default_row();
        goals["basis"] = basis;
        apply_targets(&mut goals);
        let t = &goals["targets"];
        assert_eq!(t["kcal"], json!(2320.0));
        assert_eq!(t["protein"], json!(144.0));
        assert_eq!(t["fat"], json!(77.0));
        assert_eq!(t["carbs"], json!(((2320.0 - 144.0 * 4.0 - 77.0 * 9.0) / 4.0_f64).round()));
        assert_eq!(t["fiber"], json!(32.0));
        assert_eq!(t["iron"], json!(8.0));
        assert_eq!(t["magnesium"], json!(400.0));
        assert_eq!(t["sodium"], json!(2300.0));
        goals["plan"] = json!("cut");
        apply_targets(&mut goals);
        assert_eq!(goals["targets"]["kcal"], json!(1860.0));
        assert_eq!(goals["targets"]["protein"], json!(160.0));
        goals["plan"] = json!("bulk");
        goals["overrides"] = json!({"protein": 170, "kcal": 3000});
        apply_targets(&mut goals);
        assert_eq!(goals["targets"]["protein"], json!(170.0));
        assert_eq!(goals["targets"]["fat"], json!(100.0), "macros follow an overridden kcal");
    }

    #[test]
    fn missing_data_never_invents_numbers() {
        let mut no_weight = profile();
        no_weight["weight_kg"] = Value::Null;
        let basis = basis_from(&no_weight, &[], "2026-11-08", &json!({}));
        assert!(basis["tdee"].is_null());
        assert!(basis["note"].as_str().unwrap().contains("weight"));
        let mut goals = default_row();
        goals["basis"] = basis;
        apply_targets(&mut goals);
        assert_eq!(goals["targets"]["kcal"], json!(DEFAULT_KCAL));
        let kept = basis_from(&no_weight, &[], "2026-11-08", &json!({"tdee": 2500, "bmr": 1800}));
        assert_eq!(kept["tdee"], json!(2500));
        let sparse = basis_from(&profile(), &days(3, 500.0), "2026-11-08", &json!({}));
        assert_eq!(sparse["tdee"], json!((1820.0_f64 * 1.35).round()));
    }

    #[test]
    fn manual_mode_keeps_targets_and_overrides_win() {
        let mut goals = default_row();
        goals["mode"] = json!("manual");
        goals["targets"] = json!({"kcal": 1900, "protein": 140});
        goals["overrides"] = json!({"protein": 150});
        apply_targets(&mut goals);
        assert_eq!(goals["targets"]["kcal"], json!(1900.0));
        assert_eq!(goals["targets"]["protein"], json!(150.0));
    }

    #[test]
    fn recompute_keeps_updated_at() {
        let db = db::memory();
        store::apply(&db, "goals", "upsert", &json!({"id": "current", "plan": "cut", "updated_at": 1_790_000_000_000_i64})).unwrap();
        db::meta_set(&db, "profile", &profile().to_string()).unwrap();
        let goals = recompute(&db).unwrap();
        assert_eq!(goals["updated_at"], json!(1_790_000_000_000_i64));
        assert_eq!(goals["plan"], "cut");
        assert!(goals["basis"]["bmr"].is_number());
        let v = db::version(&db);
        recompute(&db).unwrap();
        assert_eq!(db::version(&db), v, "no change, no write");
    }
}
