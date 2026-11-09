//! `food health refresh` (also `food health-refresh`): for setups with a separate Personal Health
//! server whose `health query` CLI reads Apple Health samples. Run as the user who may read
//! Health (the food service never reads that database itself), it applies the usual rules (one
//! source per day, Watch first; local days from each sample's own offset; units as recorded) and
//! pushes per-day rows and a profile to the food service, which recomputes the goals. Without a
//! health server, use `food health import` or POST /v1/health_days instead.

use crate::socket::call;
use crate::time;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};

const ACTIVE: &str = "HKQuantityTypeIdentifierActiveEnergyBurned";
const BASAL: &str = "HKQuantityTypeIdentifierBasalEnergyBurned";
const STEPS: &str = "HKQuantityTypeIdentifierStepCount";
const EXERCISE: &str = "HKQuantityTypeIdentifierAppleExerciseTime";
const WEIGHT: &str = "HKQuantityTypeIdentifierBodyMass";
const HEIGHT: &str = "HKQuantityTypeIdentifierHeight";

/// A sample's local day, from its own offset, or the configured zone's standard offset (the
/// smaller of January's and July's) for samples without one.
fn local_day() -> String {
    let year = time::today()[..4].parse::<i64>().unwrap_or(2026);
    let at = |month| time::days_from_civil(year, month, 1) * 86_400_000;
    let hours = time::utc_offset(at(1)).min(time::utc_offset(at(7))).div_euclid(3600);
    let fallback = format!("{}{:02}00", if hours < 0 { '-' } else { '+' }, hours.abs());
    format!("date(start_at, substr(coalesce(tz, '{fallback}'), 1, 3) || ' hours')")
}

fn health_binary() -> String {
    if let Some(command) = &crate::config::get().health_command {
        return command.clone();
    }
    if std::path::Path::new("/usr/local/bin/health").exists() { "/usr/local/bin/health".into() } else { "health".into() }
}

fn health_query(sql: &str) -> Result<Vec<Value>, String> {
    let binary = health_binary();
    let output = std::process::Command::new(&binary).arg("query").arg(sql).output().map_err(|e| {
        format!("can't run {binary:?}: {e}\n  `food health refresh` needs a Personal Health `health` CLI (set health_command); \
                 otherwise use `food health import` or `food goals profile`")
    })?;
    if !output.status.success() {
        return Err(format!("health query failed: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    let rows: Value = serde_json::from_slice(&output.stdout).map_err(|e| format!("health query output: {e}"))?;
    Ok(rows.as_array().cloned().unwrap_or_default())
}

pub fn kg(value: f64, unit: &str) -> Option<f64> {
    Some(match unit {
        "kg" => value,
        "lb" | "lbs" => value * 0.453_592_37,
        "g" => value / 1000.0,
        "st" => value * 6.350_293_18,
        "oz" => value * 0.028_349_523,
        _ => return None,
    })
}

pub fn cm(value: f64, unit: &str) -> Option<f64> {
    Some(match unit {
        "cm" => value,
        "m" => value * 100.0,
        "ft" => value * 30.48,
        "in" => value * 2.54,
        "mm" => value / 10.0,
        _ => return None,
    })
}

fn kcal(value: f64, unit: &str) -> Option<f64> {
    match unit {
        "Cal" | "kcal" | "Kcal" => Some(value),
        "kJ" => Some(value / 4.184),
        "cal" => Some(value / 1000.0),
        _ => None,
    }
}

/// The owner in a device name such as "Sam’s Apple Watch", if it has one.
fn owner_of(source: &str) -> Option<&str> {
    ["’s ", "'s ", "’ ", "' "].iter().find_map(|mark| source.split_once(mark)).map(|(owner, _)| owner.trim()).filter(|o| !o.is_empty())
}

/// Lower is better: the owner's Watch, any Watch, an iPhone, other apps. Another person's devices
/// ("Alex’s iPhone", when the owner is someone else) are skipped.
pub fn source_rank(source: &str, owner: Option<&str>) -> Option<u8> {
    let device_owner = owner_of(source);
    if let (Some(device), Some(me)) = (device_owner, owner) {
        if !device.eq_ignore_ascii_case(me) {
            return None;
        }
    }
    Some(match source {
        s if s.contains("Apple Watch") && device_owner.is_some() => 0,
        s if s.contains("Watch") => 1,
        s if s.contains("iPhone") => 2,
        _ => 3,
    })
}

/// Whose devices count when health_owner isn't set: the owner whose Watch reports active energy
/// on the most days (then whose devices do), so a family member's phone that shows up now and
/// then is left out.
pub fn infer_owner(rows: &[(String, String, f64)]) -> Option<String> {
    let mut seen: HashMap<&str, (HashSet<&str>, HashSet<&str>)> = HashMap::new();
    for (day, source, _) in rows {
        if let Some(owner) = owner_of(source) {
            let (watch, all) = seen.entry(owner).or_default();
            if source.contains("Watch") {
                watch.insert(day);
            }
            all.insert(day);
        }
    }
    seen.into_iter().max_by_key(|(owner, (watch, all))| (watch.len(), all.len(), std::cmp::Reverse(*owner))).map(|(o, _)| o.to_string())
}

/// One total per day: the best-ranked source's sum, never a sum across sources.
fn pick(rows: &[(String, String, f64)], owner: Option<&str>) -> BTreeMap<String, f64> {
    let mut best: BTreeMap<String, (u8, f64)> = BTreeMap::new();
    for (day, source, value) in rows {
        let Some(rank) = source_rank(source, owner) else { continue };
        let entry = best.entry(day.clone()).or_insert((u8::MAX, 0.0));
        if rank < entry.0 || (rank == entry.0 && *value > entry.1) {
            *entry = (rank, *value);
        }
    }
    best.into_iter().map(|(d, (_, v))| (d, v)).collect()
}

pub fn refresh() -> Result<Value, String> {
    let today = time::today();
    let from_day = time::add_days(&today, -400).unwrap_or_default();
    // A little before the first local day, since start_at is UTC.
    let from = format!("{}T00:00:00Z", time::add_days(&from_day, -1).unwrap_or_default());
    let mut profile = json!({});
    for row in health_query("SELECT key, value FROM profile")? {
        match (row["key"].as_str(), row["value"].as_str()) {
            (Some("HKCharacteristicTypeIdentifierDateOfBirth"), Some(v)) => profile["dob"] = json!(v.get(..10).unwrap_or(v)),
            (Some("HKCharacteristicTypeIdentifierBiologicalSex"), Some(v)) => {
                profile["sex"] = match v {
                    "HKBiologicalSexMale" => json!("male"),
                    "HKBiologicalSexFemale" => json!("female"),
                    _ => Value::Null,
                }
            }
            _ => {}
        }
    }
    let local = local_day();
    let latest = |kind: &str| health_query(&format!(
        "SELECT value, unit, {local} AS day, source FROM samples WHERE type = '{kind}' AND value IS NOT NULL ORDER BY start_at DESC LIMIT 1"));
    if let Some(row) = latest(HEIGHT)?.first() {
        profile["height_cm"] = json!(row["value"].as_f64().and_then(|v| cm(v, row["unit"].as_str().unwrap_or(""))));
        profile["height_day"] = row["day"].clone();
    }
    if let Some(row) = latest(WEIGHT)?.first() {
        profile["weight_kg"] = json!(row["value"].as_f64().and_then(|v| kg(v, row["unit"].as_str().unwrap_or(""))).map(|k| (k * 100.0).round() / 100.0));
        profile["weight_day"] = row["day"].clone();
    }

    let mut days: BTreeMap<String, Value> = BTreeMap::new();
    // Weight: the day's last weighing, whichever app recorded it.
    for row in health_query(&format!(
        "SELECT {local} AS day, value, unit FROM samples WHERE type = '{WEIGHT}' AND start_at >= '{from}' AND value IS NOT NULL ORDER BY start_at"))? {
        let (Some(day), Some(v)) = (row["day"].as_str(), row["value"].as_f64()) else { continue };
        if let Some(k) = kg(v, row["unit"].as_str().unwrap_or("")) {
            days.entry(day.to_string()).or_insert_with(|| json!({"day": day}))["weight_kg"] = json!((k * 100.0).round() / 100.0);
        }
    }
    let sums = health_query(&format!(
        "SELECT {local} AS day, type, source, unit, sum(value) AS total FROM samples
         WHERE type IN ('{ACTIVE}', '{BASAL}', '{STEPS}', '{EXERCISE}') AND start_at >= '{from}' AND value IS NOT NULL
         GROUP BY 1, 2, 3, 4"))?;
    let mut by_type: HashMap<&str, Vec<(String, String, f64)>> = HashMap::new();
    let mut last_active_day = String::new();
    for row in &sums {
        let (Some(day), Some(kind), Some(total)) = (row["day"].as_str(), row["type"].as_str(), row["total"].as_f64()) else { continue };
        let unit = row["unit"].as_str().unwrap_or("");
        let value = match kind {
            ACTIVE | BASAL => kcal(total, unit),
            EXERCISE => (unit == "min").then_some(total),
            _ => Some(total),
        };
        let Some(value) = value else { continue };
        let source = row["source"].as_str().unwrap_or("").to_string();
        let key = match kind { ACTIVE => "active_kcal", BASAL => "basal_kcal", STEPS => "steps", _ => "exercise_min" };
        by_type.entry(key).or_default().push((day.to_string(), source, value));
    }
    let owner = crate::config::get().health_owner.clone().or_else(|| by_type.get("active_kcal").and_then(|rows| infer_owner(rows)));
    for (day, source, _) in by_type.get("active_kcal").map(Vec::as_slice).unwrap_or(&[]) {
        if source_rank(source, owner.as_deref()) == Some(0) && day.as_str() > last_active_day.as_str() {
            last_active_day = day.clone();
        }
    }
    for (key, rows) in by_type {
        for (day, value) in pick(&rows, owner.as_deref()) {
            days.entry(day.clone()).or_insert_with(|| json!({"day": day}))[key] = json!((value * 10.0).round() / 10.0);
        }
    }
    // The newest day with Watch energy is usually cut off by the phone's daily sync.
    profile["active_through"] = if last_active_day.is_empty() { Value::Null } else { json!(time::add_days(&last_active_day, -1)) };
    let days: Vec<Value> = days.into_values().filter(|d| d["day"].as_str().is_some_and(|day| day >= from_day.as_str())).collect();
    let count = days.len();
    let reply = call(json!({"cmd": "health", "profile": profile, "days": days}))?;
    Ok(json!({"profile": profile, "owner": owner, "days_sent": count, "days_written": reply["days_written"], "goals": reply["goals"]}))
}

pub fn summary(r: &Value) -> String {
    let p = &r["profile"];
    let g = &r["goals"];
    let weight = p["weight_kg"].as_f64().map(|w| format!("weight {w} kg on {}", p["weight_day"].as_str().unwrap_or("?"))).unwrap_or_else(|| "no weight from Health".into());
    let n = |v: &Value| v.as_f64().map(|x| format!("{}", x.round() as i64)).unwrap_or_else(|| "?".into());
    format!("health: {} days sent, {} changed · {weight} · goals {} kcal, {} g protein ({}, {})\n  {}",
            r["days_sent"], r["days_written"], n(&g["targets"]["kcal"]), n(&g["targets"]["protein"]),
            g["mode"].as_str().unwrap_or(""), g["plan"].as_str().unwrap_or(""), g["basis"]["note"].as_str().unwrap_or(""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_source_per_day_watch_first() {
        let row = |day: &str, source: &str, v: f64| (day.to_string(), source.to_string(), v);
        let rows = vec![
            row("2026-11-06", "Sam’s Apple Watch", 361.0),
            row("2026-11-06", "GymKit", 120.0),
            row("2026-11-06", "Sam’s iPhone", 900.0),
            row("2026-11-05", "Sam’s iPhone", 50.0),
            row("2026-11-04", "Alex’s iPhone", 7000.0),
            row("2026-11-03", "Alex's iPhone", 7000.0),
        ];
        // Sam has the Watch and the most days, so Sam is the owner; Alex's phone is skipped.
        assert_eq!(infer_owner(&rows).as_deref(), Some("Sam"));
        let picked = pick(&rows, Some("Sam"));
        assert_eq!(picked["2026-11-06"], 361.0);
        assert_eq!(picked["2026-11-05"], 50.0);
        assert!(!picked.contains_key("2026-11-04") && !picked.contains_key("2026-11-03"));
        assert_eq!(owner_of("Alex's iPhone"), Some("Alex"));
        assert_eq!(owner_of("GymKit"), None);
        // With no owner known, nobody's devices are skipped.
        assert_eq!(pick(&rows, None)["2026-11-04"], 7000.0);
        assert_eq!(source_rank("Sam’s Apple Watch", None), Some(0));
        assert!((kg(256.0, "lb").unwrap() - 116.12).abs() < 0.01);
        assert!((cm(6.0833, "ft").unwrap() - 185.42).abs() < 0.01);
        assert_eq!(kcal(4184.0, "kJ"), Some(1000.0));
    }
}
