//! `food export` and `food import`: a portable JSON copy of everything that syncs (foods, entries,
//! goals, health days, tombstones included), the food aliases and the profile. It's a backup that
//! doesn't depend on the database key, so an encrypted (even TPM-sealed) database can still be
//! saved and restored, or moved to another machine. The USDA catalog isn't included: it's public
//! and `food seed-usda` brings it back.

use crate::db::{self, State};
use crate::{goals, store, time};
use rusqlite::Connection;
use serde_json::{json, Map, Value};

pub const FORMAT: &str = "plate-export";

pub fn export(db: &Connection) -> Result<Value, String> {
    let mut tables = Map::new();
    for table in db::SYNCED {
        let mut statement = db.prepare(&format!("SELECT data, updated_at, deleted FROM {table} ORDER BY version")).map_err(|e| e.to_string())?;
        let rows = statement
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)))
            .map_err(|e| e.to_string())?;
        let mut list = Vec::new();
        for row in rows {
            let (data, updated_at, deleted) = row.map_err(|e| e.to_string())?;
            let mut value: Value = serde_json::from_str(&data).map_err(|e| e.to_string())?;
            value["updated_at"] = json!(updated_at);
            value["deleted"] = json!(deleted != 0);
            list.push(value);
        }
        tables.insert(table.to_string(), Value::Array(list));
    }
    let mut statement = db.prepare("SELECT alias, id FROM food_aliases ORDER BY alias").map_err(|e| e.to_string())?;
    let aliases: Vec<Value> = statement
        .query_map([], |r| Ok(json!([r.get::<_, String>(0)?, r.get::<_, String>(1)?])))
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .collect();
    let profile = db::meta_get(db, "profile").and_then(|p| serde_json::from_str::<Value>(&p).ok()).unwrap_or(json!({}));
    Ok(json!({
        "format": FORMAT, "format_version": 1, "exported_at": time::now_utc(), "timezone": time::zone_name(),
        "server_version": db::version(db), "profile": profile, "aliases": aliases, "tables": tables,
    }))
}

/// Restores part or all of an export: rows land as they were unless the database already has a
/// newer copy (by updated_at), so restoring twice, or into a live database, never loses a newer
/// edit. Every restored row gets a new version, so the app picks it up.
pub fn restore(state: &State, request: &Value) -> Result<Value, String> {
    state.write(|db| {
        let mut counts = Map::new();
        let mut skipped = 0;
        for table in db::SYNCED {
            let Some(rows) = request["tables"][*table].as_array() else { continue };
            let mut written = 0;
            for row in rows {
                let Some(id) = row["id"].as_str().filter(|id| !id.is_empty() && id.len() <= 128) else {
                    return Err(format!("a {table} row has no id"));
                };
                let Some(updated_at) = row["updated_at"].as_i64() else {
                    return Err(format!("{table} row {id} has no updated_at"));
                };
                if row.to_string().len() > store::MAX_ROW_BYTES || !row.is_object() {
                    return Err(format!("{table} row {id} is not an object under 256 KB"));
                }
                if store::get(db, table, id)?.is_some_and(|existing| existing.updated_at >= updated_at) {
                    skipped += 1;
                    continue;
                }
                let mut row = row.clone();
                if let Some(o) = row.as_object_mut() {
                    o.remove("version");
                }
                store::put(db, table, &row)?;
                written += 1;
            }
            counts.insert(table.to_string(), json!(written));
        }
        for pair in request["aliases"].as_array().cloned().unwrap_or_default() {
            if let (Some(alias), Some(id)) = (pair[0].as_str(), pair[1].as_str()) {
                db.execute("INSERT OR IGNORE INTO food_aliases (alias, id) VALUES (?1, ?2)", [alias, id]).map_err(|e| e.to_string())?;
            }
        }
        if let Some(profile) = request["profile"].as_object().filter(|p| !p.is_empty()) {
            // Only into an empty profile: a live one is newer than any backup.
            let current = db::meta_get(db, "profile").and_then(|p| serde_json::from_str::<Value>(&p).ok());
            if current.as_ref().and_then(Value::as_object).is_none_or(|o| o.is_empty()) {
                db::meta_set(db, "profile", &Value::Object(profile.clone()).to_string())?;
            }
        }
        goals::recompute(db)?;
        Ok(json!({"restored": counts, "skipped_older": skipped, "version": db::version(db)}))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn export_and_restore_round_trip() {
        let source = State::new(db::memory());
        {
            let db = source.lock();
            store::apply(&db, "foods", "upsert", &json!({"id": "f1", "name": "Oats", "source_ref": "fdc:1", "updated_at": 1_790_000_000_000_i64,
                                                          "serving": {"amount": 1, "unit": "cup", "grams": 80}, "nutrients": {"kcal": 300}})).unwrap();
            store::apply(&db, "foods", "upsert", &json!({"id": "f2", "name": "Oats again", "source_ref": "fdc:1", "updated_at": 1_790_000_000_001_i64})).unwrap();
            store::apply(&db, "entries", "upsert", &json!({"id": "e1", "food_id": "f1", "day": "2026-11-08", "name": "Oats",
                                                            "nutrients": {"kcal": 300}, "updated_at": 1_790_000_000_002_i64})).unwrap();
            store::apply(&db, "entries", "upsert", &json!({"id": "e2", "day": "2026-11-08", "name": "Gone", "updated_at": 1_790_000_000_003_i64})).unwrap();
            store::apply(&db, "entries", "delete", &json!({"id": "e2", "updated_at": 1_790_000_000_004_i64})).unwrap();
            db::meta_set(&db, "profile", r#"{"sex": "male", "height_cm": 180}"#).unwrap();
        }
        let dump = export(&source.lock()).unwrap();
        assert_eq!(dump["format"], FORMAT);
        assert_eq!(dump["aliases"], json!([["f2", "f1"]]));
        // Through JSON text, as `food export` writes it.
        let dump: Value = serde_json::from_str(&dump.to_string()).unwrap();

        let target = State::new(db::memory());
        let out = restore(&target, &dump).unwrap();
        assert_eq!(out["restored"]["entries"], 2);
        let db = target.lock();
        assert_eq!(store::live(&db, "entries", "e1").unwrap().unwrap()["nutrients"]["kcal"], json!(300.0));
        assert!(store::get(&db, "entries", "e2").unwrap().unwrap().deleted);
        assert_eq!(store::live(&db, "foods", "f1").unwrap().unwrap()["serving"]["grams"], json!(80));
        assert_eq!(db::meta_get(&db, "profile").unwrap(), r#"{"height_cm":180,"sex":"male"}"#);
        // A later write to the alias still lands on the original food.
        store::apply(&db, "entries", "upsert", &json!({"id": "e3", "food_id": "f2", "day": "2026-11-08", "updated_at": 1_790_000_000_005_i64})).unwrap();
        assert_eq!(store::live(&db, "entries", "e3").unwrap().unwrap()["food_id"], "f1");
        drop(db);
        // Restoring again changes nothing, and never overwrites a newer row.
        let v = db::version(&target.lock());
        let again = restore(&target, &dump).unwrap();
        assert_eq!(again["restored"]["entries"], 0);
        assert!(again["skipped_older"].as_u64().unwrap() >= 4);
        assert_eq!(db::version(&target.lock()), v);
    }
}
