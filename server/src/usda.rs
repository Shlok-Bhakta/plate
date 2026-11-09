//! `food seed-usda`, run as any user the socket answers: downloads the FoodData Central
//! Foundation, SR Legacy and FNDDS survey CSV zips into the cache dir (`cache_dir`, default
//! ~/.cache/plate), maps them to our nutrient keys per 100 g with USDA portions, and streams them
//! to the service in batches. Safe to rerun; downloads already in the cache are reused.

use crate::socket::call;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

const PAGE: &str = "https://fdc.nal.usda.gov/download-datasets/";
const BASE: &str = "https://fdc.nal.usda.gov/fdc-datasets/";
/// Known good releases, used when the download page can't be read. Newer ones are tried first.
const PINNED: &[&str] = &[
    "FoodData_Central_foundation_food_csv_2026-04-30.zip",
    "FoodData_Central_sr_legacy_food_csv_2018-04.zip",
    "FoodData_Central_survey_food_csv_2024-10-31.zip",
];
const KINDS: &[(&str, &str, &str)] = &[
    ("foundation", "FoodData_Central_foundation_food_csv_", "foundation_food"),
    ("sr_legacy", "FoodData_Central_sr_legacy_food_csv_", "sr_legacy_food"),
    ("survey", "FoodData_Central_survey_food_csv_", "survey_fndds_food"),
];

/// Our key, then FDC nutrient ids in order of preference.
const MAP: &[(&str, &[i64])] = &[
    ("kcal", &[1008, 2048, 2047]), ("protein", &[1003]), ("carbs", &[1005, 1050]), ("fat", &[1004, 1085]),
    ("fiber", &[1079]), ("sugar", &[2000, 1063]), ("added_sugar", &[1235]), ("sat_fat", &[1258]), ("trans_fat", &[1257]),
    ("mono_fat", &[1292]), ("poly_fat", &[1293]), ("cholesterol", &[1253]), ("sodium", &[1093]), ("potassium", &[1092]),
    ("calcium", &[1087]), ("iron", &[1089]), ("magnesium", &[1090]), ("phosphorus", &[1091]), ("zinc", &[1095]),
    ("copper", &[1098]), ("manganese", &[1101]), ("selenium", &[1103]), ("iodine", &[1100]), ("vit_a", &[1106]),
    ("vit_c", &[1162]), ("vit_d", &[1114]), ("vit_e", &[1109]), ("vit_k", &[1185]), ("thiamin", &[1165]),
    ("riboflavin", &[1166]), ("niacin", &[1167]), ("pantothenic", &[1170]), ("vit_b6", &[1175]), ("biotin", &[1176]),
    ("folate", &[1190, 1177]), ("vit_b12", &[1178]), ("choline", &[1180]), ("caffeine", &[1057]), ("alcohol", &[1018]),
    ("water", &[1051]),
];
const VIT_D_IU: i64 = 1110;
const ALA: &[i64] = &[1404, 1270];
const LONG_OMEGA3: &[i64] = &[1278, 1272, 1280]; // EPA, DHA, DPA

pub fn cache_dir() -> PathBuf {
    crate::config::get().cache_dir.clone()
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(Duration::from_secs(600)).user_agent(&crate::config::get().user_agent()).build()
}

/// Zip names for each kind from the download page, newest first.
fn discover() -> HashMap<&'static str, Vec<String>> {
    let page = agent().get(PAGE).call().ok().and_then(|r| r.into_string().ok()).unwrap_or_default();
    let mut found: HashMap<&'static str, Vec<String>> = HashMap::new();
    for chunk in page.split("fdc-datasets/").skip(1) {
        let Some(end) = chunk.find(".zip") else { continue };
        let name = chunk[..end + 4].replace("%20", " ");
        if name.contains('"') || name.contains(' ') {
            continue;
        }
        for (kind, prefix, _) in KINDS {
            if name.starts_with(prefix) && !found.get(kind).is_some_and(|l| l.contains(&name)) {
                found.entry(kind).or_default().push(name.clone());
            }
        }
    }
    for pinned in PINNED {
        for (kind, prefix, _) in KINDS {
            if pinned.starts_with(prefix) && !found.get(kind).is_some_and(|l| l.iter().any(|n| n == pinned)) {
                found.entry(kind).or_default().push(pinned.to_string());
            }
        }
    }
    for list in found.values_mut() {
        list.sort_by(|a, b| b.cmp(a));
    }
    found
}

fn download(name: &str) -> Result<PathBuf, String> {
    let dir = cache_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("can't create {}: {e}", dir.display()))?;
    let path = dir.join(name);
    if path.exists() {
        return Ok(path);
    }
    eprintln!("downloading {name}");
    let response = agent().get(&format!("{BASE}{name}")).call().map_err(|e| format!("{name}: {e}"))?;
    let part = dir.join(format!("{name}.part"));
    let mut file = std::fs::File::create(&part).map_err(|e| e.to_string())?;
    std::io::copy(&mut response.into_reader(), &mut file).map_err(|e| format!("{name}: {e}"))?;
    std::fs::rename(&part, &path).map_err(|e| e.to_string())?;
    Ok(path)
}

struct Zip {
    archive: zip::ZipArchive<std::fs::File>,
}

impl Zip {
    fn open(path: &Path) -> Result<Zip, String> {
        let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
        Ok(Zip { archive: zip::ZipArchive::new(file).map_err(|e| format!("{}: {e}", path.display()))? })
    }

    fn has(&self, base: &str) -> bool {
        self.archive.file_names().any(|n| n.rsplit('/').next() == Some(base))
    }

    fn read(&mut self, base: &str) -> Result<Option<String>, String> {
        let Some(name) = self.archive.file_names().find(|n| n.rsplit('/').next() == Some(base)).map(str::to_string) else {
            return Ok(None);
        };
        let mut text = String::new();
        self.archive.by_name(&name).map_err(|e| e.to_string())?.read_to_string(&mut text).map_err(|e| format!("{base}: {e}"))?;
        Ok(Some(text))
    }
}

/// RFC 4180 records: quoted fields, doubled quotes, commas and newlines inside quotes.
pub fn csv(text: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, quoted) {
            ('"', true) if chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            ('"', true) => quoted = false,
            ('"', false) if field.is_empty() => quoted = true,
            (',', false) => row.push(std::mem::take(&mut field)),
            ('\r', false) => {}
            ('\n', false) => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            (c, _) => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

/// Rows as maps from header name to value.
fn table(text: Option<String>) -> Vec<HashMap<String, String>> {
    let Some(text) = text else { return Vec::new() };
    let mut rows = csv(&text).into_iter();
    let Some(header) = rows.next() else { return Vec::new() };
    rows.map(|r| header.iter().cloned().zip(r).collect()).collect()
}

fn trim_amount(text: &str) -> String {
    match text.parse::<f64>() {
        Ok(x) => crate::store::trim_number(x),
        Err(_) => text.to_string(),
    }
}

/// A USDA portion's label: FNDDS has a description ("1 cup"); SR Legacy and Foundation have an
/// amount, a unit and a modifier ("1 cup, chopped").
pub fn portion_label(row: &HashMap<String, String>, units: &HashMap<String, String>) -> Option<String> {
    let field = |k: &str| row.get(k).map(|s| s.trim()).unwrap_or("");
    let description = field("portion_description");
    if !description.is_empty() {
        return Some(description.to_string());
    }
    let unit = units.get(field("measure_unit_id")).map(String::as_str).filter(|u| *u != "undetermined").unwrap_or("");
    let modifier = field("modifier");
    // FNDDS modifiers are numeric codes, not words.
    let modifier = if modifier.chars().all(|c| c.is_ascii_digit()) { "" } else { modifier };
    let words = [unit, modifier].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join(" ");
    if words.is_empty() {
        return None;
    }
    let amount = trim_amount(field("amount"));
    Some(if amount.is_empty() { words } else { format!("{amount} {words}") })
}

/// Picks our nutrient values (per 100 g) out of one food's FDC nutrient amounts.
pub fn map_nutrients(amounts: &HashMap<i64, f64>) -> Map<String, Value> {
    let mut out = Map::new();
    for (key, ids) in MAP {
        if let Some(x) = ids.iter().find_map(|id| amounts.get(id)) {
            out.insert(key.to_string(), json!(*x));
        }
    }
    if !out.contains_key("vit_d") {
        if let Some(iu) = amounts.get(&VIT_D_IU) {
            out.insert("vit_d".into(), json!(iu / 40.0));
        }
    }
    let ala = ALA.iter().find_map(|id| amounts.get(id));
    let long: Vec<f64> = LONG_OMEGA3.iter().filter_map(|id| amounts.get(id).copied()).collect();
    if ala.is_some() || !long.is_empty() {
        out.insert("omega3".into(), json!(ala.copied().unwrap_or(0.0) + long.iter().sum::<f64>()));
    }
    out
}

fn load(kind: &str, data_type: &str, zip: &mut Zip) -> Result<Vec<Value>, String> {
    // Nutrient ids: FNDDS files use the old nutrient numbers (208 = energy), the rest FDC ids.
    let mut by_number: HashMap<String, i64> = HashMap::new();
    for row in table(zip.read("nutrient.csv")?) {
        if let (Some(id), Some(nbr)) = (row.get("id").and_then(|s| s.parse().ok()), row.get("nutrient_nbr")) {
            by_number.insert(trim_amount(nbr), id);
        }
    }
    let mut categories: HashMap<String, String> = HashMap::new();
    for row in table(zip.read("food_category.csv")?) {
        if let (Some(id), Some(d)) = (row.get("id"), row.get("description")) { categories.insert(id.clone(), d.clone()); }
    }
    for row in table(zip.read("wweia_food_category.csv")?) {
        if let (Some(id), Some(d)) = (row.get("wweia_food_category"), row.get("wweia_food_category_description")) { categories.insert(id.clone(), d.clone()); }
    }
    let units: HashMap<String, String> = table(zip.read("measure_unit.csv")?)
        .into_iter().filter_map(|r| Some((r.get("id")?.clone(), r.get("name")?.clone()))).collect();
    let mut foods: Vec<(i64, String, Option<String>)> = Vec::new();
    for row in table(zip.read("food.csv")?) {
        if row.get("data_type").map(String::as_str) != Some(data_type) { continue; }
        let Some(id) = row.get("fdc_id").and_then(|s| s.parse().ok()) else { continue };
        let name = row.get("description").cloned().unwrap_or_default();
        let category = row.get("food_category_id").and_then(|c| categories.get(c)).cloned();
        foods.push((id, name, category));
    }
    let wanted: std::collections::HashSet<i64> = foods.iter().map(|f| f.0).collect();
    let mut amounts: HashMap<i64, HashMap<i64, f64>> = HashMap::new();
    let text = zip.read("food_nutrient.csv")?.ok_or("no food_nutrient.csv")?;
    let mut rows = csv(&text).into_iter();
    let header = rows.next().unwrap_or_default();
    let col = |name: &str| header.iter().position(|h| h == name);
    let (fdc, nid, amt) = (col("fdc_id").ok_or("no fdc_id")?, col("nutrient_id").ok_or("no nutrient_id")?, col("amount").ok_or("no amount")?);
    for row in rows {
        let (Some(f), Some(n), Some(a)) = (row.get(fdc), row.get(nid), row.get(amt)) else { continue };
        let (Ok(f), Ok(a)) = (f.parse::<i64>(), a.parse::<f64>()) else { continue };
        if !wanted.contains(&f) || !a.is_finite() || a < 0.0 { continue; }
        let n = match n.parse::<i64>() {
            Ok(id) if id >= 1000 => id,
            _ => match by_number.get(&trim_amount(n)) { Some(id) => *id, None => continue },
        };
        amounts.entry(f).or_default().insert(n, a);
    }
    drop(text);
    let mut portions: HashMap<i64, Vec<(f64, String, f64)>> = HashMap::new();
    for row in table(zip.read("food_portion.csv")?) {
        let Some(f) = row.get("fdc_id").and_then(|s| s.parse::<i64>().ok()).filter(|f| wanted.contains(f)) else { continue };
        let Some(grams) = row.get("gram_weight").and_then(|s| s.parse::<f64>().ok()).filter(|g| *g > 0.0) else { continue };
        let Some(label) = portion_label(&row, &units) else { continue };
        let seq = row.get("seq_num").and_then(|s| s.parse::<f64>().ok()).unwrap_or(f64::MAX);
        portions.entry(f).or_default().push((seq, label, grams));
    }
    let mut items = Vec::new();
    for (id, name, category) in foods {
        let nutrients = map_nutrients(amounts.get(&id).unwrap_or(&HashMap::new()));
        if !nutrients.contains_key("kcal") { continue; }
        let mut list = portions.remove(&id).unwrap_or_default();
        list.sort_by(|a, b| a.0.total_cmp(&b.0));
        let mut seen = std::collections::HashSet::new();
        let list: Vec<Value> = list.into_iter().filter(|p| seen.insert(p.1.clone()))
            .map(|(_, label, grams)| json!({"label": label, "grams": crate::nutrients::round(grams)})).collect();
        items.push(json!({"fdc_id": id, "dataset": kind, "name": name, "category": category, "nutrients": nutrients, "portions": list}));
    }
    Ok(items)
}

pub fn seed() -> Result<(), String> {
    // Fail early, before a long download, if the service isn't there.
    call(json!({"cmd": "ping"}))?;
    eprintln!("USDA FoodData Central (public domain); cache {}", cache_dir().display());
    let found = discover();
    let mut sources = Vec::new();
    let mut total = 0;
    for (kind, _, data_type) in KINDS {
        let mut done = false;
        for name in found.get(kind).cloned().unwrap_or_default() {
            let path = match download(&name) {
                Ok(p) => p,
                Err(e) => { eprintln!("skipping {name}: {e}"); continue; }
            };
            let mut zip = match Zip::open(&path) {
                Ok(z) => z,
                Err(e) => { eprintln!("skipping {name}: {e}"); let _ = std::fs::remove_file(&path); continue; }
            };
            if !(zip.has("food.csv") && zip.has("food_nutrient.csv")) {
                eprintln!("skipping {name}: it has no food.csv or food_nutrient.csv (an incomplete release); trying an older one");
                continue;
            }
            let items = load(kind, data_type, &mut zip)?;
            for batch in items.chunks(1500) {
                call(json!({"cmd": "catalog-import", "items": batch}))?;
            }
            eprintln!("{kind}: {} foods from {name}", items.len());
            total += items.len();
            sources.push(json!({"dataset": kind, "file": name, "foods": items.len()}));
            done = true;
            break;
        }
        if !done {
            return Err(format!("couldn't get a usable {kind} release"));
        }
    }
    let summary = call(json!({"cmd": "catalog-finish", "sources": sources}))?;
    let counts: Vec<String> = summary["counts"].as_array().cloned().unwrap_or_default().iter()
        .map(|c| format!("{} {}", c["dataset"].as_str().unwrap_or(""), c["foods"])).collect();
    println!("imported {total} USDA foods; catalog now has {}", counts.join(", "));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_handles_quotes_and_newlines() {
        let rows = csv("\"a\",\"b, c\",\"say \"\"hi\"\"\"\r\n\"1\",\"line\nbreak\",\"\"\n");
        assert_eq!(rows, vec![vec!["a", "b, c", "say \"hi\""], vec!["1", "line\nbreak", ""]]);
        assert_eq!(csv("x,y"), vec![vec!["x", "y"]]);
    }

    #[test]
    fn nutrients_and_portions_map() {
        let amounts: HashMap<i64, f64> = [(2047, 89.0), (1003, 1.1), (1110, 400.0), (1270, 0.2), (1272, 0.1)].into_iter().collect();
        let n = map_nutrients(&amounts);
        assert_eq!(n["kcal"], json!(89.0));
        assert_eq!(n["vit_d"], json!(10.0));
        assert!((n["omega3"].as_f64().unwrap() - 0.3).abs() < 1e-9);
        let units: HashMap<String, String> = [("1000".to_string(), "cup".to_string()), ("9999".to_string(), "undetermined".to_string())].into_iter().collect();
        let row = |pairs: &[(&str, &str)]| pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<HashMap<_, _>>();
        assert_eq!(portion_label(&row(&[("amount", "1"), ("measure_unit_id", "9999"), ("modifier", "cup, chopped")]), &units).unwrap(), "1 cup, chopped");
        assert_eq!(portion_label(&row(&[("amount", "2.0"), ("measure_unit_id", "1000"), ("modifier", "")]), &units).unwrap(), "2 cup");
        assert_eq!(portion_label(&row(&[("portion_description", "1 slice"), ("modifier", "10205")]), &units).unwrap(), "1 slice");
        assert_eq!(portion_label(&row(&[("amount", ""), ("measure_unit_id", "9999"), ("modifier", "90000")]), &units), None);
    }
}
