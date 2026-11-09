//! `food health import`: daily health rows from anything (a spreadsheet, a fitness app's export, a
//! script) as JSON or CSV, plus an optional profile. The service stores the days and recomputes the
//! goals, exactly as for `food health refresh` or POST /v1/health_days.

use serde_json::{json, Map, Value};

/// The day fields the service keeps.
pub const FIELDS: &[&str] = &["weight_kg", "active_kcal", "basal_kcal", "steps", "exercise_min"];

/// A CSV header's field, allowing a few common spellings. `weight_lb` converts to kg.
fn column(name: &str) -> Option<(&'static str, f64)> {
    let name = name.trim().trim_start_matches('\u{feff}').to_ascii_lowercase().replace([' ', '-'], "_");
    Some(match name.as_str() {
        "day" | "date" => ("day", 1.0),
        "weight_kg" | "weight" | "body_mass_kg" => ("weight_kg", 1.0),
        "weight_lb" | "weight_lbs" => ("weight_kg", 0.453_592_37),
        "active_kcal" | "active_energy" | "active_energy_kcal" | "active_calories" => ("active_kcal", 1.0),
        "basal_kcal" | "basal_energy" | "basal_energy_kcal" | "resting_energy" | "resting_kcal" => ("basal_kcal", 1.0),
        "steps" | "step_count" => ("steps", 1.0),
        "exercise_min" | "exercise_minutes" | "exercise" => ("exercise_min", 1.0),
        _ => return None,
    })
}

/// Parses an import. JSON is `[{day, ...}]` or `{"days": [...], "profile": {...}}`; CSV has a
/// header row with `day` and any of the fields. Returns {days, profile, ignored_columns}.
pub fn parse(text: &str, format: Option<&str>) -> Result<Value, String> {
    let json_like = text.trim_start().starts_with(['{', '[']);
    match format.map(str::to_ascii_lowercase).as_deref() {
        Some("json") => parse_json(text),
        Some("csv") => parse_csv(text),
        Some(other) => Err(format!("--format must be json or csv, not {other:?}")),
        None if json_like => parse_json(text),
        None => parse_csv(text),
    }
}

fn parse_json(text: &str) -> Result<Value, String> {
    let value: Value = serde_json::from_str(text).map_err(|e| format!("not JSON: {e}"))?;
    let (days, profile) = match value {
        Value::Array(days) => (days, Value::Null),
        Value::Object(mut o) => (
            match o.remove("days") {
                Some(Value::Array(days)) => days,
                None | Some(Value::Null) => Vec::new(),
                Some(_) => return Err("\"days\" must be a list".to_string()),
            },
            o.remove("profile").unwrap_or(Value::Null),
        ),
        _ => return Err("send a list of days, or {\"days\": [...], \"profile\": {...}}".to_string()),
    };
    let mut out = Vec::new();
    for (i, day) in days.iter().enumerate() {
        let object = day.as_object().ok_or_else(|| format!("day {} is not an object", i + 1))?;
        let date = object.get("day").or(object.get("date")).and_then(Value::as_str).ok_or_else(|| format!("day {} has no \"day\"", i + 1))?;
        let mut row = Map::new();
        row.insert("day".into(), json!(date.get(..10).unwrap_or(date)));
        for field in FIELDS {
            match object.get(*field) {
                None | Some(Value::Null) => {}
                Some(v) if v.is_number() => { row.insert(field.to_string(), v.clone()); }
                Some(v) => return Err(format!("day {} ({date}): {field} must be a number, not {v}", i + 1)),
            }
        }
        out.push(Value::Object(row));
    }
    if !profile.is_null() && !profile.is_object() {
        return Err("\"profile\" must be an object".to_string());
    }
    Ok(json!({"days": out, "profile": profile, "ignored_columns": []}))
}

fn parse_csv(text: &str) -> Result<Value, String> {
    let mut rows = crate::usda::csv(text).into_iter().filter(|r| !(r.len() == 1 && r[0].trim().is_empty()));
    let header = rows.next().ok_or("the CSV is empty")?;
    let columns: Vec<Option<(&str, f64)>> = header.iter().map(|h| column(h)).collect();
    if !columns.iter().any(|c| matches!(c, Some(("day", _)))) {
        return Err(format!("the CSV needs a day (or date) column; its header is {}", header.join(",")));
    }
    let ignored: Vec<String> = header.iter().zip(&columns).filter(|(_, c)| c.is_none()).map(|(h, _)| h.trim().to_string()).collect();
    let mut days = Vec::new();
    for (n, row) in rows.enumerate() {
        let mut day = Map::new();
        for (value, column) in row.iter().zip(&columns) {
            let (Some((field, factor)), value) = (column, value.trim()) else { continue };
            if value.is_empty() {
                continue;
            }
            if *field == "day" {
                day.insert("day".into(), json!(value.get(..10).unwrap_or(value)));
            } else {
                let x: f64 = value.replace(',', "").parse().map_err(|_| format!("CSV line {}: {field} {value:?} is not a number", n + 2))?;
                day.insert(field.to_string(), json!(crate::nutrients::round(x * factor)));
            }
        }
        if !day.contains_key("day") {
            return Err(format!("CSV line {} has no day", n + 2));
        }
        days.push(Value::Object(day));
    }
    Ok(json!({"days": days, "profile": null, "ignored_columns": ignored}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_and_csv_imports() {
        let j = parse(r#"{"profile": {"birth_date": "1990-04-01", "sex": "female", "height_cm": 168},
                         "days": [{"day": "2026-11-07", "weight_kg": 61.2, "active_kcal": 420, "steps": 9000, "note": "x"},
                                  {"date": "2026-11-08T07:00:00Z", "exercise_min": 30}]}"#, None).unwrap();
        assert_eq!(j["days"][0], json!({"day": "2026-11-07", "weight_kg": 61.2, "active_kcal": 420, "steps": 9000}));
        assert_eq!(j["days"][1], json!({"day": "2026-11-08", "exercise_min": 30}));
        assert_eq!(j["profile"]["sex"], "female");
        assert_eq!(parse(r#"[{"day": "2026-11-07", "steps": 1}]"#, None).unwrap()["days"].as_array().unwrap().len(), 1);
        assert!(parse(r#"[{"day": "2026-11-07", "steps": "many"}]"#, None).unwrap_err().contains("steps"));
        assert!(parse(r#"[{"steps": 1}]"#, Some("json")).is_err());

        let c = parse("\u{feff}Date,Weight (lb),Active Energy,basal_kcal,Steps,Exercise Minutes,Mood\n\
                       2026-11-07,150,410.5,1400,\"9,120\",25,ok\n2026-11-08,,300,,,,\n", None);
        // "Weight (lb)" isn't a known spelling, so it's ignored and named.
        let c = c.unwrap();
        assert_eq!(c["ignored_columns"], json!(["Weight (lb)", "Mood"]));
        assert_eq!(c["days"][0], json!({"day": "2026-11-07", "active_kcal": 410.5, "basal_kcal": 1400.0, "steps": 9120.0, "exercise_min": 25.0}));
        assert_eq!(c["days"][1], json!({"day": "2026-11-08", "active_kcal": 300.0}));
        let lb = parse("day,weight_lb\n2026-11-07,150\n", Some("csv")).unwrap();
        assert_eq!(lb["days"][0]["weight_kg"], json!(68.039));
        assert!(parse("weight_kg\n70\n", None).unwrap_err().contains("day"));
        assert!(parse("day,steps\n2026-11-07,lots\n", None).unwrap_err().contains("line 2"));
        assert!(parse("x", Some("xml")).is_err());
    }
}
