//! The `food` command line, for people, scripts and agents. Readable text by default, JSON with
//! --json. Its documentation is its help (help.rs).

use crate::socket::call;
use crate::{config, healthimport, healthpull, help, nutrients, time, usda};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::Read;

const SWITCHES: &[&str] = &["json", "json-out", "favorites", "off", "no-off", "help", "force", "yes", "key-stdin", "default", "set", "reset"];

/// A short usage error that points at the command's help.
fn usage(command: &str, message: impl std::fmt::Display) -> String {
    format!("{message}\n  see `food {command} --help`")
}

/// The flags each command takes, besides --json. `true`: the nutrient flags too.
fn allowed_flags(command: &str) -> Option<(&'static [&'static str], bool)> {
    Some(match command {
        "today" => (&["date"], false),
        "log" => (&["catalog", "food", "servings", "grams", "meal", "date", "note", "brand", "json-out", "n"], true),
        "entries" => (&["date", "from", "to"], false),
        "edit" => (&["servings", "grams", "meal", "date", "name", "note", "n"], true),
        "search" => (&["limit", "no-off"], false),
        "suggest" => (&["meal"], false),
        "food" => (&["favorites", "off"], false),
        "report" => (&["days"], false),
        "health" => (&["format", "birth-date", "sex", "height-cm"], false),
        "init" => (&["data-dir", "listen", "timezone", "encryption", "force"], false),
        "agent" => (&["base-url", "model", "key-stdin", "auto-log", "max-jobs", "photo", "text", "meal", "date", "yes", "default", "set",
                      "reset"], false),
        "rm" | "barcode" | "recipe" | "goals" | "health-refresh" | "query" | "rotate-token" | "token" | "seed-usda" | "config"
        | "export" | "import" => (&[], false),
        _ => return None,
    })
}

struct Args {
    command: String,
    positional: Vec<String>,
    flags: HashMap<String, Vec<String>>,
}

impl Args {
    fn parse(command: &str, raw: &[String]) -> Result<Args, String> {
        let mut positional = Vec::new();
        let mut flags: HashMap<String, Vec<String>> = HashMap::new();
        let mut i = 0;
        while i < raw.len() {
            let arg = &raw[i];
            if let Some(name) = arg.strip_prefix("--") {
                let (name, inline) = match name.split_once('=') {
                    Some((n, v)) => (n.to_string(), Some(v.to_string())),
                    None => (name.to_string(), None),
                };
                if SWITCHES.contains(&name.as_str()) {
                    flags.entry(name).or_default().push(String::new());
                } else {
                    let value = match inline {
                        Some(v) => v,
                        None => {
                            i += 1;
                            raw.get(i).cloned().ok_or_else(|| usage(command, format!("--{name} needs a value")))?
                        }
                    };
                    flags.entry(name).or_default().push(value);
                }
            } else {
                positional.push(arg.clone());
            }
            i += 1;
        }
        let args = Args { command: command.to_string(), positional, flags };
        if let Some((allowed, nutrient_flags)) = allowed_flags(command) {
            for name in args.flags.keys() {
                let known = matches!(name.as_str(), "json" | "help") || allowed.contains(&name.as_str()) || (nutrient_flags && nutrients::find(name).is_some());
                if !known {
                    return Err(usage(command, format!("food {command} has no --{name}")));
                }
            }
        }
        Ok(args)
    }

    fn usage(&self, message: impl std::fmt::Display) -> String {
        usage(&self.command, message)
    }

    fn has(&self, name: &str) -> bool {
        self.flags.contains_key(name)
    }

    fn get(&self, name: &str) -> Option<&str> {
        self.flags.get(name).and_then(|v| v.last()).map(String::as_str)
    }

    fn number(&self, name: &str) -> Result<Option<f64>, String> {
        self.get(name).map(|v| v.parse::<f64>().map_err(|_| self.usage(format!("--{name} needs a number, not {v:?}")))).transpose()
    }

    fn pos(&self, i: usize) -> Option<&str> {
        self.positional.get(i).map(String::as_str)
    }
}

fn stdin_json() -> Result<Value, String> {
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| format!("stdin is not JSON: {e}"))
}

fn print_json(value: &Value) {
    let mut value = value.clone();
    if let Some(o) = value.as_object_mut() {
        o.remove("ok");
    }
    println!("{}", serde_json::to_string_pretty(&value).unwrap_or_default());
}

/// True when the command line asks for help, which never needs the service.
pub fn wants_help(raw: &[String]) -> bool {
    help::requested(raw).is_some()
}

pub fn run(raw: &[String]) -> Result<(), String> {
    if let Some(text) = help::requested(raw) {
        print!("{}", text?);
        return Ok(());
    }
    let command = &raw[0];
    if allowed_flags(command).is_none() {
        return Err(format!("unknown command {command:?}; run `food --help` for the list"));
    }
    let args = Args::parse(command, &raw[1..])?;
    let json_out = args.has("json");
    match command.as_str() {
        "today" => {
            // Days are resolved by the service, in its time zone.
            let reply = call(json!({"cmd": "today", "date": args.get("date").unwrap_or("today")}))?;
            if json_out { print_json(&reply) } else { print!("{}", format_day(&reply)) }
        }
        "log" => log(&args)?,
        "entries" => {
            let (from, to) = match (args.get("from"), args.get("to"), args.get("date")) {
                (Some(f), t, _) => (f, t.unwrap_or("today")),
                (None, _, d) => (d.unwrap_or("today"), d.unwrap_or("today")),
            };
            let reply = call(json!({"cmd": "entries", "from": from, "to": to}))?;
            let (from, to) = (reply["from"].as_str().unwrap_or(from), reply["to"].as_str().unwrap_or(to));
            if json_out {
                print_json(&reply);
            } else {
                let list = reply["entries"].as_array().cloned().unwrap_or_default();
                if list.is_empty() {
                    println!("no entries from {from} to {to}");
                }
                for e in list {
                    println!("{} {:<9} {}", e["day"].as_str().unwrap_or(""), e["meal"].as_str().unwrap_or(""), entry_line(&e));
                }
            }
        }
        "edit" => {
            let id = args.pos(0).ok_or_else(|| args.usage("food edit needs an entry id"))?;
            let mut changes = json!({});
            for key in ["servings", "grams"] {
                if let Some(x) = args.number(key)? { changes[key] = json!(x); }
            }
            for key in ["meal", "date", "name", "note"] {
                if let Some(v) = args.get(key) { changes[key] = json!(v); }
            }
            let extra = nutrient_flags(&args)?;
            if !extra.is_empty() { changes["nutrients"] = Value::Object(extra); }
            let reply = call(json!({"cmd": "edit", "id": id, "changes": changes}))?;
            if json_out { print_json(&reply) } else { println!("edited: {}", entry_line(&reply["entry"])) }
        }
        "rm" => {
            if args.positional.is_empty() {
                return Err(args.usage("food rm needs one or more entry ids"));
            }
            let reply = call(json!({"cmd": "rm", "table": "entries", "ids": args.positional}))?;
            if json_out { print_json(&reply) } else {
                for r in reply["removed"].as_array().cloned().unwrap_or_default() {
                    println!("removed {} {}", short(&r["id"]), r["name"].as_str().unwrap_or(""));
                }
            }
        }
        "search" => {
            let q = args.positional.join(" ");
            if q.trim().is_empty() { return Err(args.usage("food search needs a query")); }
            let limit = args.number("limit")?.unwrap_or(15.0) as u64;
            let reply = call(json!({"cmd": "search", "q": q, "limit": limit, "off": !args.has("no-off")}))?;
            if json_out { print_json(&reply) } else {
                let results = reply["results"].as_array().cloned().unwrap_or_default();
                if results.is_empty() { println!("nothing found for {q:?}"); }
                for f in results { println!("{}", food_line(&f)); }
            }
        }
        "barcode" => {
            let code = args.pos(0).ok_or_else(|| args.usage("food barcode needs the barcode digits"))?;
            let reply = call(json!({"cmd": "barcode", "code": code}))?;
            if reply["food"].is_null() {
                if json_out { print_json(&json!({"food": null})) } else { println!("no product with barcode {code}") }
                std::process::exit(2);
            }
            if json_out { print_json(&reply) } else { println!("{}", food_detail(&reply["food"])) }
        }
        "suggest" => {
            let reply = call(json!({"cmd": "suggest", "meal": args.get("meal")}))?;
            if json_out { print_json(&reply) } else { print!("{}", format_suggest(&reply)) }
        }
        "food" => food_command(&args, json_out)?,
        "recipe" => {
            if args.pos(0) != Some("add") { return Err(args.usage("use food recipe add --json < recipe.json")); }
            let mut recipe = stdin_json()?;
            recipe["kind"] = json!("recipe");
            let reply = call(json!({"cmd": "food-add", "food": recipe}))?;
            if json_out { print_json(&reply) } else { println!("saved recipe: {}", food_detail(&reply["food"])) }
        }
        "goals" => goals_command(&args, json_out)?,
        "report" => {
            let days = args.number("days")?.unwrap_or(7.0) as i64;
            let reply = call(json!({"cmd": "report", "days": days}))?;
            if json_out { print_json(&reply) } else { print!("{}", format_report(&reply)) }
        }
        "health-refresh" => {
            let reply = healthpull::refresh()?;
            if json_out { print_json(&reply) } else { println!("{}", healthpull::summary(&reply)) }
        }
        "health" => health_command(&args, json_out)?,
        "query" => {
            let sql = args.positional.join(" ");
            if sql.trim().is_empty() { return Err(args.usage("food query needs a SELECT")); }
        let reply = call(json!({"cmd": "query", "sql": sql}))?;
            println!("{}", serde_json::to_string_pretty(&reply["rows"]).unwrap_or_default());
            if reply["truncated"] == true {
                eprintln!("truncated: only the first {} rows (or 16 MB) came back; add a LIMIT or aggregate", reply["rows"].as_array().map_or(0, Vec::len));
            }
        }
        "rotate-token" | "token" => {
            // `food token new [grace-hours]`, or the older `food rotate-token [grace-hours]`.
            let rest = if command == "token" {
                match args.pos(0) {
                    Some("new" | "rotate") => &args.positional[1..],
                    _ => return Err(args.usage("use food token new [grace-hours]")),
                }
            } else {
                &args.positional[..]
            };
            let grace = rest.first().map(|h| h.parse::<i64>().map_err(|_| args.usage("grace-hours must be a whole number"))).transpose()?.unwrap_or(48);
            let reply = call(json!({"cmd": "rotate-token", "grace_hours": grace}))?;
            eprintln!("old tokens stop working at {} UTC", reply["old_tokens_expire"].as_str().unwrap_or("?"));
            println!("{}", reply["token"].as_str().unwrap_or(""));
        }
        "seed-usda" => usda::seed()?,
        "init" => {
            let options = config::InitOptions {
                data_dir: args.get("data-dir").map(str::to_string),
                listen: args.get("listen").map(str::to_string),
                timezone: args.get("timezone").map(str::to_string),
                encryption: args.get("encryption").map(str::to_string),
                force: args.has("force"),
            };
            print!("{}", config::init(&options, &|name| std::env::var(name).ok())?);
        }
        "config" => config_command(json_out)?,
        "agent" => agent_command(&args, json_out)?,
        "export" => {
            let mut reply = call(json!({"cmd": "export"}))?;
            if let Some(o) = reply.as_object_mut() { o.remove("ok"); }
            let text = serde_json::to_string(&reply).map_err(|e| e.to_string())? + "\n";
            let counts: Vec<String> = crate::db::SYNCED.iter()
                .map(|t| format!("{} {t}", reply["tables"][*t].as_array().map_or(0, Vec::len))).collect();
            match args.pos(0).filter(|p| *p != "-") {
                Some(path) => {
                    // The export is the user's whole log, unencrypted: only they may read it.
                    config::write_private(std::path::Path::new(path), &text)?;
                    eprintln!("exported {} to {path}", counts.join(", "));
                }
                None => {
                    print!("{text}");
                    eprintln!("exported {}", counts.join(", "));
                }
            }
        }
        "import" => {
            let text = read_input(args.pos(0))?;
            let dump: Value = serde_json::from_str(&text).map_err(|e| format!("not a Plate export: {e}"))?;
            if dump["format"] != crate::backup::FORMAT {
                return Err("not a Plate export (made by `food export`)".to_string());
            }
            let mut restored: HashMap<String, u64> = HashMap::new();
            let mut skipped = 0;
            let mut first = true;
            for table in crate::db::SYNCED {
                for chunk in dump["tables"][*table].as_array().cloned().unwrap_or_default().chunks(2000) {
                    let mut request = json!({"cmd": "restore", "tables": {*table: chunk}});
                    if first {
                        request["profile"] = dump["profile"].clone();
                        request["aliases"] = dump["aliases"].clone();
                        first = false;
                    }
                    let reply = call(request)?;
                    *restored.entry(table.to_string()).or_default() += reply["restored"][*table].as_u64().unwrap_or(0);
                    skipped += reply["skipped_older"].as_u64().unwrap_or(0);
                }
            }
            let counts: Vec<String> = crate::db::SYNCED.iter().map(|t| format!("{} {t}", restored.get(*t).copied().unwrap_or(0))).collect();
            println!("restored {}; {skipped} rows skipped because this database has the same or newer copies", counts.join(", "));
        }
        other => return Err(format!("unknown command {other:?}; run `food --help` for the list")),
    }
    Ok(())
}

/// A file's text, or stdin for no path or "-".
fn read_input(path: Option<&str>) -> Result<String, String> {
    match path.filter(|p| *p != "-") {
        Some(path) => std::fs::read_to_string(path).map_err(|e| format!("can't read {path}: {e}")),
        None => {
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text).map_err(|e| e.to_string())?;
            Ok(text)
        }
    }
}

fn health_command(args: &Args, json_out: bool) -> Result<(), String> {
    match args.pos(0) {
        Some("refresh") => {
            let reply = healthpull::refresh()?;
            if json_out { print_json(&reply) } else { println!("{}", healthpull::summary(&reply)) }
        }
        Some("import") => {
            let text = read_input(args.pos(1))?;
            let format = args.get("format").or_else(|| {
                args.pos(1).and_then(|p| p.rsplit('.').next()).filter(|ext| matches!(*ext, "json" | "csv"))
            });
            let parsed = healthimport::parse(&text, format)?;
            let mut profile = parsed["profile"].as_object().cloned().unwrap_or_default();
            if let Some(dob) = args.get("birth-date") { profile.insert("dob".into(), json!(dob)); }
            if let Some(sex) = args.get("sex") { profile.insert("sex".into(), json!(sex)); }
            if let Some(h) = args.number("height-cm")? { profile.insert("height_cm".into(), json!(h)); }
            let days = parsed["days"].as_array().cloned().unwrap_or_default();
            let (mut written, mut skipped, mut goals, mut ignored) = (0, 0, Value::Null, Vec::new());
            let batches: Vec<&[Value]> = if days.is_empty() { vec![&[]] } else { days.chunks(500).collect() };
            for (i, batch) in batches.into_iter().enumerate() {
                let mut request = json!({"cmd": "health", "days": batch});
                if i == 0 { request["profile"] = Value::Object(profile.clone()); }
                let reply = call(request)?;
                written += reply["days_written"].as_u64().unwrap_or(0);
                skipped += reply["days_skipped"].as_u64().unwrap_or(0);
                ignored.extend(reply["profile_ignored"].as_array().cloned().unwrap_or_default());
                goals = reply["goals"].clone();
            }
            let reply = json!({"days_read": days.len(), "days_written": written, "days_skipped": skipped,
                               "ignored_columns": parsed["ignored_columns"], "profile_ignored": ignored, "goals": goals});
            if json_out { print_json(&reply); return Ok(()); }
            println!("read {} days: {written} new or changed, {skipped} skipped (no valid day, or over 400 days old)", days.len());
            let unused: Vec<&str> = parsed["ignored_columns"].as_array().map(|l| l.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
            if !unused.is_empty() { println!("ignored columns: {}", unused.join(", ")); }
            if !ignored.is_empty() {
                let names: Vec<&str> = ignored.iter().filter_map(Value::as_str).collect();
                println!("ignored profile values (out of range or malformed): {}", names.join(", "));
            }
            print!("{}", format_goals(&goals));
        }
        _ => return Err(args.usage("use food health import [FILE] or food health refresh")),
    }
    Ok(())
}

/// `food goals profile key=value ...`: weight, height, age or birth date, sex, activity.
fn profile_changes(args: &Args) -> Result<Value, String> {
    let mut set = json!({});
    for pair in &args.positional[1..] {
        let (key, value) = pair.split_once('=').ok_or_else(|| args.usage(format!("goals profile wants key=value, not {pair:?}")))?;
        let value = value.trim();
        if matches!(value, "" | "none") {
            let key = match key { "weight" => "weight_kg", "height" => "height_cm", "birth_date" | "birthday" => "dob", "activity" => "activity_factor", k => k };
            set[key] = Value::Null;
            if key == "age" { set["age_on"] = Value::Null; }
            continue;
        }
        let number = |text: &str| text.parse::<f64>().map_err(|_| args.usage(format!("{key} needs a number, not {value:?}")));
        let with_unit = |units: &[(&str, f64)]| -> Result<f64, String> {
            for (suffix, factor) in units {
                if let Some(n) = value.strip_suffix(suffix) {
                    return Ok(number(n.trim())? * factor);
                }
            }
            number(value)
        };
        match key {
            "weight" | "weight_kg" => {
                set["weight_kg"] = json!(with_unit(&[("kg", 1.0), ("lbs", 0.453_592_37), ("lb", 0.453_592_37)])?);
            }
            "height" | "height_cm" => set["height_cm"] = json!(with_unit(&[("cm", 1.0), ("in", 2.54), ("m", 100.0)])?),
            "age" => set["age"] = json!(number(value)?),
            "birth_date" | "birthday" | "dob" => set["dob"] = json!(value),
            "sex" => set["sex"] = json!(value),
            "activity" | "activity_factor" => {
                set["activity_factor"] = json!(match value {
                    "sedentary" => 1.2,
                    "light" => 1.375,
                    "moderate" => 1.55,
                    "active" => 1.725,
                    "very_active" | "very-active" => 1.9,
                    v => number(v)?,
                });
            }
            other => return Err(args.usage(format!("unknown profile key {other:?}; use weight, height, age, birth_date, sex or activity"))),
        }
    }
    Ok(set)
}

fn format_profile(p: &Value) -> String {
    let field = |key: &str, label: &str, unit: &str| p[key].as_f64().map(|x| format!("{label} {}{unit}", amount(x)))
        .or_else(|| p[key].as_str().map(|s| format!("{label} {s}")));
    let parts: Vec<String> = [field("weight_kg", "weight", " kg"), field("height_cm", "height", " cm"), field("dob", "born", ""),
                              field("age", "age", ""), field("sex", "sex", ""),
                              p["activity_factor"].as_f64().map(|f| format!("activity x{}", crate::store::trim_number(f)))]
        .into_iter().flatten().collect();
    format!("profile: {}\n", if parts.is_empty() { "empty".to_string() } else { parts.join(" · ") })
}

fn config_command(json_out: bool) -> Result<(), String> {
    let c = config::get();
    let zone = crate::tz::load(c.timezone.as_deref());
    let key = match crate::db::source() {
        Ok(source) => source.describe(),
        // Only the service has its credential; from the CLI's side that's expected.
        Err(_) if c.encryption == config::Encryption::Credential => {
            format!("SQLCipher, key from the service's systemd credential {:?}", c.credential)
        }
        Err(error) => format!("not ready: {error}"),
    };
    let service = call(json!({"cmd": "config"}));
    let me = unsafe { libc::getuid() };
    let mut uids = vec![format!("{me} (you)"), "0 (root)".to_string()];
    for uid in c.socket_uids.iter().filter(|u| **u != me && **u != 0).map(u32::to_string) {
        if !uids.contains(&uid) {
            uids.push(uid);
        }
    }
    let value = json!({
        "config_file": c.file, "data_dir": c.data_dir, "database": c.database, "listen": c.listen, "socket": c.socket,
        "socket_uids": c.socket_uids, "timezone": c.timezone, "timezone_resolved": zone.as_ref().map(|z| z.name.clone()).ok(),
        "encryption": c.encryption.name(), "key": key, "key_file": c.key_file, "credential": c.credential, "cache_dir": c.cache_dir,
        "user_agent": c.user_agent(), "health_command": c.health_command, "health_owner": c.health_owner,
        "service": service.as_ref().ok().map(|s| json!({"timezone": s["timezone"], "database": s["database"], "version": s["version"]})),
    });
    if json_out {
        print_json(&value);
        return Ok(());
    }
    let show = |p: &std::path::Path| p.display().to_string();
    let lines = [
        ("config file", c.file.as_deref().map(show).unwrap_or_else(|| format!("none (defaults and FOOD_* variables); `food init` writes {}",
            config::user_config_path(&|n| std::env::var(n).ok()).display()))),
        ("data_dir", show(&c.data_dir)),
        ("database", show(&c.database)),
        ("encryption", format!("{} → {key}", c.encryption.name())),
        ("listen", c.listen.clone()),
        ("socket", show(&c.socket)),
        ("socket_uids", uids.join(", ")),
        ("timezone", match (&c.timezone, &zone) {
            (Some(name), Ok(_)) => name.clone(),
            (None, Ok(z)) => format!("{} (the system zone)", z.name),
            (_, Err(e)) => format!("error: {e}"),
        }),
        ("cache_dir", show(&c.cache_dir)),
        ("user agent", c.user_agent()),
        ("health_command", c.health_command.clone().unwrap_or_else(|| "health (for `food health refresh` only)".into())),
        ("health_owner", c.health_owner.clone().unwrap_or_else(|| "inferred from device names".into())),
        ("service", match &service {
            Ok(s) => format!("running: version {}, time zone {}, database {}", s["version"], s["timezone"].as_str().unwrap_or("?"), s["database"].as_str().unwrap_or("?")),
            Err(e) => format!("not reachable: {}", e.lines().next().unwrap_or("")),
        }),
    ];
    for (label, value) in lines {
        println!("{label:<15} {value}");
    }
    Ok(())
}

/// `--kcal 200 --protein 10` and `--n vit_c=30` as a nutrient map.
fn nutrient_flags(args: &Args) -> Result<Map<String, Value>, String> {
    let mut out = Map::new();
    for n in nutrients::ALL {
        if let Some(x) = args.number(n.key)? {
            out.insert(n.key.into(), json!(x));
        }
    }
    for pair in args.flags.get("n").cloned().unwrap_or_default() {
        let (key, value) = pair.split_once('=').ok_or_else(|| args.usage(format!("--n wants key=value, not {pair:?}")))?;
        nutrients::find(key).ok_or_else(|| args.usage(format!("unknown nutrient {key:?} (see `food help nutrients`)")))?;
        out.insert(key.into(), json!(value.parse::<f64>().map_err(|_| args.usage(format!("{key} needs a number")))?));
    }
    Ok(out)
}

fn log(args: &Args) -> Result<(), String> {
    // `--json` with no name, --food or --catalog means the items come as JSON on stdin; then the
    // reply is still the short summary unless --json-out asks for every entry and the whole day.
    let batch = args.has("json") && args.positional.is_empty() && !args.has("food") && !args.has("catalog");
    let items = if batch {
        match stdin_json()? {
            Value::Array(list) => list,
            single @ Value::Object(_) => vec![single],
            _ => return Err("send a JSON array of items".to_string()),
        }
    } else {
        let mut item = json!({});
        if let Some(c) = args.get("catalog") {
            item["catalog"] = json!(c);
        } else if let Some(f) = args.get("food") {
            item["food"] = json!(f);
        } else {
            let name = args.positional.join(" ");
            if name.trim().is_empty() {
                return Err(args.usage("give a name, --catalog, --food, or --json with items on stdin"));
            }
            item["name"] = json!(name);
            item["nutrients"] = Value::Object(nutrient_flags(args)?);
        }
        for key in ["servings", "grams"] {
            if let Some(x) = args.number(key)? { item[key] = json!(x); }
        }
        for key in ["meal", "date", "note", "brand"] {
            if let Some(v) = args.get(key) { item[key] = json!(v); }
        }
        vec![item]
    };
    let reply = call(json!({"cmd": "log", "items": items}))?;
    if args.has("json-out") || (args.has("json") && !batch) {
        print_json(&reply);
        return Ok(());
    }
    print!("{}", format_logged(&reply, &items));
    Ok(())
}

/// One line per logged entry, with the catalog query beside the name it matched so a wrong match
/// stands out, then the day's totals and what's left.
fn format_logged(reply: &Value, items: &[Value]) -> String {
    let mut out = String::new();
    for (i, logged) in reply["logged"].as_array().cloned().unwrap_or_default().iter().enumerate() {
        let e = &logged["entry"];
        let mut source = logged["matched"]["source_ref"].as_str().map(str::to_string).unwrap_or_default();
        if let Some(query) = items.get(i).and_then(|item| item["catalog"].as_str()).filter(|q| q.trim().trim_start_matches("fdc:").parse::<i64>().is_err()) {
            source.push_str(&format!(", for {query:?}"));
        }
        let source = if source.is_empty() { String::new() } else { format!(" ({source})") };
        out.push_str(&format!("logged {}{source} to {}\n", entry_line(e), e["meal"].as_str().unwrap_or("")));
    }
    out.push_str(&remaining_line(&reply["today"]));
    out.push('\n');
    out
}

fn food_command(args: &Args, json_out: bool) -> Result<(), String> {
    match args.pos(0) {
        Some("add") => {
            let reply = call(json!({"cmd": "food-add", "food": stdin_json()?}))?;
            if json_out { print_json(&reply) } else { println!("saved: {}", food_detail(&reply["food"])) }
        }
        Some("list") => {
            let reply = call(json!({"cmd": "foods", "favorites": args.has("favorites")}))?;
            if json_out { print_json(&reply) } else {
                for f in reply["foods"].as_array().cloned().unwrap_or_default() {
                    println!("{}  (logged {}x)", food_line(&f), f["times_logged"]);
                }
            }
        }
        Some("fav") => {
            let id = args.pos(1).ok_or_else(|| args.usage("food food fav needs a food id"))?;
            let reply = call(json!({"cmd": "fav", "id": id, "on": !args.has("off")}))?;
            if json_out { print_json(&reply) } else {
                println!("{} {}", if args.has("off") { "unfavorited" } else { "favorited" }, reply["food"]["name"].as_str().unwrap_or(""));
            }
        }
        Some("rm") => {
            let ids: Vec<String> = args.positional[1..].to_vec();
            if ids.is_empty() { return Err(args.usage("food food rm needs one or more food ids")); }
            let reply = call(json!({"cmd": "rm", "table": "foods", "ids": ids}))?;
            if json_out { print_json(&reply) } else {
                for r in reply["removed"].as_array().cloned().unwrap_or_default() {
                    println!("removed food {} {}", short(&r["id"]), r["name"].as_str().unwrap_or(""));
                }
            }
        }
        Some(other) => return Err(args.usage(format!("unknown food subcommand {other:?}; use add, list, fav or rm"))),
        None => return Err(args.usage("use food food add, list, fav or rm")),
    }
    Ok(())
}

fn goals_command(args: &Args, json_out: bool) -> Result<(), String> {
    let changes = match args.pos(0) {
        None => {
            let reply = call(json!({"cmd": "goals"}))?;
            if json_out { print_json(&reply) } else { print!("{}", format_goals(&reply["goals"])) }
            return Ok(());
        }
        Some("profile") => {
            // With no pairs, this just shows the profile.
            let reply = call(json!({"cmd": "profile", "set": profile_changes(args)?}))?;
            if json_out { print_json(&reply) } else { print!("{}{}", format_profile(&reply["profile"]), format_goals(&reply["goals"])) }
            return Ok(());
        }
        Some("auto") => json!({"mode": "auto"}),
        Some("manual") => json!({"mode": "manual"}),
        Some("plan") => match args.pos(1) {
            Some(p @ ("cut" | "maintain" | "bulk")) => json!({"plan": p}),
            _ => return Err(args.usage("use food goals plan cut|maintain|bulk")),
        },
        Some("set") => {
            let mut changes = json!({"overrides": {}});
            if args.positional.len() < 2 {
                return Err(args.usage("food goals set needs key=value pairs"));
            }
            for pair in &args.positional[1..] {
                let (key, value) = pair.split_once('=').ok_or_else(|| args.usage(format!("goals set wants key=value, not {pair:?}")))?;
                match key {
                    "plan" | "mode" => { changes[key] = json!(value); }
                    "water_ml" | "water" => {
                        changes["water_ml"] = json!(value.parse::<f64>().map_err(|_| "water_ml needs a number")?);
                    }
                    _ => {
                        nutrients::find(key).ok_or_else(|| args.usage(format!("unknown nutrient {key:?} (see `food help nutrients`)")))?;
                        changes["overrides"][key] = if matches!(value, "" | "auto" | "none") {
                            Value::Null
                        } else {
                            json!(value.parse::<f64>().map_err(|_| format!("{key} needs a number or auto"))?)
                        };
                    }
                }
            }
            changes
        }
        Some(other) => return Err(args.usage(format!("unknown goals command {other:?}"))),
    };
    let reply = call(json!({"cmd": "goals-update", "changes": changes}))?;
    if json_out { print_json(&reply) } else { print!("{}", format_goals(&reply["goals"])) }
    Ok(())
}

// MARK: AI logging

fn agent_command(args: &Args, json_out: bool) -> Result<(), String> {
    match args.pos(0) {
        None | Some("config") => {
            let mut set = json!({});
            if let Some(url) = args.get("base-url") { set["base_url"] = json!(url); }
            if let Some(model) = args.get("model") { set["model"] = json!(model); }
            if args.has("key-stdin") {
                let mut line = String::new();
                std::io::stdin().read_line(&mut line).map_err(|e| e.to_string())?;
                set["api_key"] = json!(line.trim());
            }
            if let Some(on) = args.get("auto-log") {
                set["auto_log"] = json!(match on {
                    "on" | "true" | "yes" => true,
                    "off" | "false" | "no" => false,
                    other => return Err(args.usage(format!("--auto-log takes on or off, not {other:?}"))),
                });
            }
            if let Some(n) = args.get("max-jobs") {
                set["max_jobs_per_day"] = json!(n.parse::<i64>().map_err(|_| args.usage("--max-jobs needs a whole number"))?);
            }
            let request = if set.as_object().is_some_and(|o| o.is_empty()) { json!({"cmd": "agent-config"}) } else { json!({"cmd": "agent-config", "set": set}) };
            let mut reply = call(request)?;
            if json_out {
                print_json(&reply);
            } else {
                if let Some(o) = reply.as_object_mut() { o.remove("default_system_prompt"); }
                print!("{}", format_agent_config(&reply));
            }
        }
        Some("models") => {
            let q = args.positional[1..].join(" ");
            let reply = call(json!({"cmd": "agent-models", "q": q}))?;
            if json_out { print_json(&reply); return Ok(()); }
            let list = reply["models"].as_array().cloned().unwrap_or_default();
            if list.is_empty() { println!("no models{}", if q.is_empty() { String::new() } else { format!(" match {q:?}") }); }
            let price = |v: &Value| v.as_f64().map(|p| format!("${}", crate::store::trim_number(p))).unwrap_or_else(|| "?".into());
            for m in &list {
                let context = m["context_length"].as_f64().map(|c| format!(" · {}k context", num(c / 1000.0))).unwrap_or_default();
                let prices = if m["prompt_price"].is_null() && m["completion_price"].is_null() { String::new() } else {
                    format!(" · {} in / {} out per 1M tokens", price(&m["prompt_price"]), price(&m["completion_price"]))
                };
                let name = if m["name"] == m["id"] { String::new() } else { format!("  {}", m["name"].as_str().unwrap_or("")) };
                println!("{}{name}{context}{prices}", m["id"].as_str().unwrap_or(""));
            }
        }
        Some("test") => {
            let reply = call(json!({"cmd": "agent-test"}))?;
            if json_out { print_json(&reply) } else {
                println!("ok: {} answered in {} ms", reply["model"].as_str().unwrap_or("?"), reply["latency_ms"]);
            }
        }
        Some("prompt") => {
            if args.has("set") {
                let mut text = String::new();
                std::io::stdin().read_to_string(&mut text).map_err(|e| e.to_string())?;
                if text.trim().is_empty() { return Err(args.usage("--set reads the prompt from stdin, and it was empty (use --reset)")); }
                call(json!({"cmd": "agent-config", "set": {"system_prompt": text}}))?;
                println!("set a custom system prompt ({} characters); `food agent prompt --reset` goes back to the built-in one", text.chars().count());
            } else if args.has("reset") {
                call(json!({"cmd": "agent-config", "set": {"system_prompt": null}}))?;
                println!("using the built-in system prompt");
            } else {
                let reply = call(json!({"cmd": "agent-config"}))?;
                let custom = reply["system_prompt"].as_str().filter(|_| !args.has("default"));
                let text = custom.or(reply["default_system_prompt"].as_str()).unwrap_or("");
                print!("{text}{}", if text.ends_with('\n') { "" } else { "\n" });
            }
        }
        Some("log") => agent_log(args, json_out)?,
        Some(other) => return Err(args.usage(format!("unknown agent subcommand {other:?}; use config, models, test, prompt or log"))),
    }
    Ok(())
}

fn format_agent_config(c: &Value) -> String {
    let usage = |u: &Value| {
        let cost = u["cost"].as_f64().map(|c| format!(" · ${c:.4}")).unwrap_or_default();
        format!("{} jobs · {} + {} tokens{cost}", u["jobs"], num(get(u, "prompt_tokens")), num(get(u, "completion_tokens")))
    };
    let key = if c["has_key"] == true { format!("set ({})", c["key_hint"].as_str().unwrap_or("…")) } else {
        "not set (food agent config --key-stdin)".to_string()
    };
    let prompt = match c["system_prompt"].as_str() {
        Some(p) => format!("custom, {} characters (food agent prompt)", p.chars().count()),
        None => "built in, from the CLI help (food agent prompt)".to_string(),
    };
    let model = c["model"].as_str().filter(|m| !m.is_empty()).unwrap_or("not set (food agent models, then --model ID)");
    [("base_url", c["base_url"].as_str().unwrap_or("").to_string()), ("model", model.to_string()), ("api key", key),
     ("auto_log", if c["auto_log"] == true { "on".into() } else { "off".into() }), ("max jobs/day", c["max_jobs_per_day"].to_string()),
     ("system prompt", prompt), ("today", usage(&c["usage"]["today"])), ("this month", usage(&c["usage"]["month"]))]
        .iter().map(|(label, value)| format!("{label:<14} {value}\n")).collect()
}

fn agent_log(args: &Args, json_out: bool) -> Result<(), String> {
    let mut job = json!({});
    if let Some(path) = args.get("photo") {
        let bytes = std::fs::read(path).map_err(|e| format!("can't read {path}: {e}"))?;
        if !bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
            return Err(format!("{path} isn't a JPEG; convert it first (for example `sips -s format jpeg` or ImageMagick's `magick`)"));
        }
        if bytes.len() > crate::agent::MAX_IMAGE {
            return Err(format!("{path} is {:.1} MB; the limit is 1.5 MB, so shrink it to about 1024 px on the long edge first",
                               bytes.len() as f64 / 1_048_576.0));
        }
        job["image"] = json!(crate::llm::base64_encode(&bytes));
    }
    let text = args.get("text").map(str::to_string).unwrap_or_else(|| args.positional[1..].join(" "));
    if !text.trim().is_empty() { job["text"] = json!(text); }
    if job.as_object().is_some_and(|o| o.is_empty()) {
        return Err(args.usage("food agent log needs --photo PATH, --text T, or both"));
    }
    for key in ["meal", "date"] {
        if let Some(v) = args.get(key) { job[key] = json!(v); }
    }
    let id = call(json!({"cmd": "agent-job", "job": job}))?["job"].as_str().unwrap_or("").to_string();
    let mut step = String::new();
    let job = loop {
        let reply = call(json!({"cmd": "agent-job-get", "id": id, "wait": 25}))?;
        if !json_out && reply["step"].as_str().is_some_and(|s| s != step) {
            step = reply["step"].as_str().unwrap_or("").to_string();
            eprintln!("  {step}");
        }
        if reply["status"] != "running" { break reply; }
    };
    match job["status"].as_str() {
        Some("failed") => return Err(format!("AI logging failed: {}", job["error"].as_str().unwrap_or("no reason given"))),
        Some("logged") => {
            if json_out { print_json(&job); return Ok(()); }
            println!("{}", job["draft"]["summary"].as_str().unwrap_or(""));
            for e in job["entries"].as_array().cloned().unwrap_or_default() {
                println!("logged {} to {}", entry_line(&e), e["meal"].as_str().unwrap_or(""));
            }
            println!("(auto-log is on)");
            return Ok(());
        }
        _ => {}
    }
    if json_out && !args.has("yes") { print_json(&job); return Ok(()); }
    if !json_out {
        println!("{}", job["draft"]["summary"].as_str().unwrap_or(""));
        for (i, e) in job["draft"]["preview"].as_array().cloned().unwrap_or_default().iter().enumerate() {
            let source = job["draft"]["items"][i]["catalog"].as_str().or(job["draft"]["items"][i]["food"].as_str())
                .map(|s| format!(" (for {s:?})")).unwrap_or_default();
            println!("  {}{source} to {} {}", entry_text(e), e["meal"].as_str().unwrap_or(""), e["day"].as_str().unwrap_or(""));
        }
        if let Some(error) = job["error"].as_str() { println!("note: {error}"); }
    }
    let yes = args.has("yes") || (unsafe { libc::isatty(0) } == 1 && {
        eprint!("Log this? [y/N] ");
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer).map_err(|e| e.to_string())?;
        matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes")
    });
    if !yes {
        println!("not logged{}", if unsafe { libc::isatty(0) } == 1 { "" } else { " (add --yes to log the draft)" });
        return Ok(());
    }
    let reply = call(json!({"cmd": "agent-confirm", "id": id}))?;
    if json_out { print_json(&reply); return Ok(()); }
    for e in reply["entries"].as_array().cloned().unwrap_or_default() {
        println!("logged {} to {}", entry_line(&e), e["meal"].as_str().unwrap_or(""));
    }
    println!("{}", remaining_line(&reply["today"]));
    Ok(())
}

// MARK: Formatting

fn short(id: &Value) -> String {
    id.as_str().map(|s| s.chars().take(8).collect()).unwrap_or_else(|| "--------".into())
}

pub(crate) fn num(x: f64) -> String {
    let rounded = x.round() as i64;
    let digits = rounded.abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 { out.push(','); }
        out.push(c);
    }
    if rounded < 0 { format!("-{out}") } else { out }
}

/// Small values keep a decimal: 1.3 g, 0.4 mg.
pub(crate) fn amount(x: f64) -> String {
    if x.abs() >= 10.0 { num(x) } else { crate::store::trim_number((x * 10.0).round() / 10.0) }
}

fn get(map: &Value, key: &str) -> f64 {
    map[key].as_f64().unwrap_or(0.0)
}

fn entry_line(e: &Value) -> String {
    format!("{}  {}", short(&e["id"]), entry_text(e))
}

/// An entry without its id: name, brand, size, kcal and protein.
pub(crate) fn entry_text(e: &Value) -> String {
    let n = &e["nutrients"];
    // Whole or quarter servings read as servings; anything logged by weight reads as grams.
    let servings = e["servings"].as_f64().unwrap_or(1.0);
    let label = e["serving_label"].as_str().filter(|l| !l.is_empty());
    let mut size = Vec::new();
    match (e["grams"].as_f64(), label) {
        (Some(g), Some(label)) if (servings * 4.0).fract().abs() < 1e-6 => {
            size.push(format!("{}{label}", if servings == 1.0 { String::new() } else { format!("{}x ", crate::store::trim_number(servings)) }));
            if !label.contains(" g)") || servings != 1.0 { size.push(format!("= {} g", num(g))); }
        }
        (Some(g), _) => size.push(format!("{} g", num(g))),
        (None, Some(label)) if servings == 1.0 => size.push(label.to_string()),
        (None, Some(label)) => size.push(format!("{}x {label}", crate::store::trim_number(servings))),
        (None, None) if servings != 1.0 => size.push(format!("{}x", crate::store::trim_number(servings))),
        _ => {}
    }
    let size = if size.is_empty() { String::new() } else { format!(" · {}", size.join(" ")) };
    let brand = e["brand"].as_str().filter(|b| !b.is_empty()).map(|b| format!(" ({b})")).unwrap_or_default();
    format!("{}{brand}{size} · {} kcal · {} g protein", e["name"].as_str().unwrap_or("?"), num(get(n, "kcal")), amount(get(n, "protein")))
}

pub(crate) fn food_line(f: &Value) -> String {
    let source = f["source"].as_str().unwrap_or("");
    let tag = if f["id"].is_string() { format!("[mine {}]", short(&f["id"])) } else { format!("[{source}]") };
    let serving = &f["serving"];
    let unit = serving["unit"].as_str().unwrap_or("serving");
    let mut size = format!("{} {unit}", crate::store::trim_number(serving["amount"].as_f64().unwrap_or(1.0)));
    if let Some(g) = serving["grams"].as_f64().filter(|_| unit != "g") { size.push_str(&format!(" ({} g)", num(g))); }
    let n = &f["nutrients"];
    let brand = f["brand"].as_str().filter(|b| !b.is_empty()).map(|b| format!(" · {b}")).unwrap_or_default();
    let star = if f["favorite"] == true { " ★" } else { "" };
    format!("{tag} {}{brand}{star} · {size}: {} kcal, P {} C {} F {} · {}", f["name"].as_str().unwrap_or("?"),
            num(get(n, "kcal")), amount(get(n, "protein")), amount(get(n, "carbs")), amount(get(n, "fat")),
            f["source_ref"].as_str().unwrap_or(""))
}

pub(crate) fn food_detail(f: &Value) -> String {
    let mut out = food_line(f);
    let portions: Vec<String> = f["portions"].as_array().cloned().unwrap_or_default().iter()
        .map(|p| format!("{} = {} g", p["label"].as_str().unwrap_or(""), amount(p["grams"].as_f64().unwrap_or(0.0)))).collect();
    if !portions.is_empty() { out.push_str(&format!("\n  portions: {}", portions.join(", "))); }
    if let Some(id) = f["id"].as_str() { out.push_str(&format!("\n  id {id}")); }
    if let Some(code) = f["barcode"].as_str() { out.push_str(&format!(" · barcode {code}")); }
    if f["partial"] == true {
        let n = f["missing_food_ids"].as_array().map_or(0, Vec::len);
        out.push_str(&format!("\n  partial: {n} deleted ingredient(s) left out of the nutrients"));
    }
    out
}

pub(crate) fn weekday(day: &str) -> &'static str {
    let d = time::parse_day(day).unwrap_or(0);
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(d + 4).rem_euclid(7) as usize]
}

pub(crate) fn remaining_line(s: &Value) -> String {
    let (t, total) = (&s["targets"], &s["totals"]);
    let kcal_left = get(t, "kcal") - get(total, "kcal");
    let protein_left = get(t, "protein") - get(total, "protein");
    format!("{}: {} / {} kcal ({} {}) · protein {} / {} g ({} {})", s["date"].as_str().unwrap_or(""),
            num(get(total, "kcal")), num(get(t, "kcal")), num(kcal_left.abs()), if kcal_left >= 0.0 { "left" } else { "over" },
            num(get(total, "protein")), num(get(t, "protein")), num(protein_left.abs()), if protein_left >= 0.0 { "to go" } else { "over" })
}

pub(crate) fn format_day(s: &Value) -> String {
    let day = s["date"].as_str().unwrap_or("");
    let (t, total) = (&s["targets"], &s["totals"]);
    let mut out = format!("{} {day} · {} ({})\n", weekday(day), s["goals"]["plan"].as_str().unwrap_or(""), s["goals"]["mode"].as_str().unwrap_or(""));
    out.push_str(&remaining_line(s));
    out.push('\n');
    let macro_part = |key: &str, label: &str| format!("{label} {} / {} g", num(get(total, key)), num(get(t, key)));
    out.push_str(&format!("{} · {} · {}\n", macro_part("carbs", "carbs"), macro_part("fat", "fat"), macro_part("fiber", "fiber")));
    for meal in ["breakfast", "lunch", "dinner", "snack"] {
        let m = &s["meals"][meal];
        let list = m["entries"].as_array().cloned().unwrap_or_default();
        if list.is_empty() { continue; }
        out.push_str(&format!("\n{} · {} kcal · {} g protein\n", capitalize(meal), num(get(&m["totals"], "kcal")), amount(get(&m["totals"], "protein"))));
        for e in list { out.push_str(&format!("  {}\n", entry_line(&e))); }
    }
    if s["entry_count"] == 0 {
        out.push_str("\nnothing logged yet\n");
    } else {
        let gaps: Vec<String> = s["gaps"].as_array().cloned().unwrap_or_default().iter().take(8)
            .map(|g| format!("{} {}%", g["name"].as_str().unwrap_or(""), num(get(g, "pct")))).collect();
        if !gaps.is_empty() { out.push_str(&format!("\nlow so far: {}\n", gaps.join(" · "))); }
        let unknown: Vec<&str> = s["no_data"].as_array().map(|l| l.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
        if !unknown.is_empty() { out.push_str(&format!("no data yet: {}\n", unknown.join(", "))); }
        let over: Vec<String> = s["over_limits"].as_array().cloned().unwrap_or_default().iter()
            .map(|g| format!("{} {} / {} {}", g["name"].as_str().unwrap_or(""), num(get(g, "total")), num(get(g, "target")), g["unit"].as_str().unwrap_or(""))).collect();
        if !over.is_empty() { out.push_str(&format!("over limits: {}\n", over.join(" · "))); }
    }
    out
}

/// `food suggest`: frequent and recent foods for the meal, then yesterday's same meal.
pub(crate) fn format_suggest(reply: &Value) -> String {
    let mut out = format!("for {}:\n", reply["meal"].as_str().unwrap_or(""));
    for (label, key) in [("frequent", "frequent"), ("recent", "recents")] {
        for f in reply[key].as_array().cloned().unwrap_or_default().iter().take(8) {
            out.push_str(&format!("  {label:<8} {}\n", food_line(f)));
        }
    }
    for e in reply["yesterday"].as_array().cloned().unwrap_or_default() {
        out.push_str(&format!("  yesterday {}\n", entry_line(&e)));
    }
    if out.lines().count() == 1 {
        out.push_str("  nothing yet: no foods logged in the last 90 days\n");
    }
    out
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

pub(crate) fn format_goals(g: &Value) -> String {
    let t = &g["targets"];
    let mut out = format!("mode {} · plan {}\n", g["mode"].as_str().unwrap_or(""), g["plan"].as_str().unwrap_or(""));
    out.push_str(&format!("targets: {} kcal · protein {} g · carbs {} g · fat {} g · fiber {} g · water {} ml\n",
        num(get(t, "kcal")), num(get(t, "protein")), num(get(t, "carbs")), num(get(t, "fat")), num(get(t, "fiber")), num(get(t, "water"))));
    let limits: Vec<String> = g["limits"].as_array().cloned().unwrap_or_default().iter().filter_map(|k| {
        let key = k.as_str()?;
        let n = nutrients::find(key)?;
        Some(format!("{} ≤ {} {}", n.name, amount(t[key].as_f64()?), n.unit))
    }).collect();
    out.push_str(&format!("limits: {}\n", limits.join(" · ")));
    let overrides: Vec<String> = g["overrides"].as_object().map(|o| o.iter().map(|(k, v)| format!("{k}={v}")).collect()).unwrap_or_default();
    out.push_str(&format!("overrides: {}\n", if overrides.is_empty() { "none".to_string() } else { overrides.join(" ") }));
    let b = &g["basis"];
    if b["bmr"].is_number() {
        let activity = match (b["active_kcal_avg14"].as_f64(), b["activity_factor"].as_f64()) {
            (Some(active), _) => format!("+ active {}", num(active)),
            (None, Some(f)) => format!("x {}", crate::store::trim_number(f)),
            (None, None) => "+ active ?".to_string(),
        };
        out.push_str(&format!("basis: {} kg ({}), {} cm, {} y, {} · BMR {} {} = TDEE {}\n",
            amount(get(b, "weight_kg")), b["weight_day"].as_str().unwrap_or("?"), amount(get(b, "height_cm")), b["age"], b["sex"].as_str().unwrap_or("?"),
            num(get(b, "bmr")), activity, num(get(b, "tdee"))));
    }
    if let Some(note) = b["note"].as_str() { out.push_str(&format!("  {note}\n")); }
    let micros: Vec<String> = nutrients::ALL.iter().filter(|n| matches!(n.group, "mineral" | "vitamin") && !g["limits"].as_array().is_some_and(|l| l.contains(&json!(n.key))))
        .filter_map(|n| Some(format!("{} {}{}", n.key, amount(t[n.key].as_f64()?), n.unit))).collect();
    out.push_str(&format!("micros: {}\n", micros.join(" · ")));
    out
}

fn format_report(r: &Value) -> String {
    let t = &r["targets"];
    let a = &r["averages"];
    let basis = if r["includes_today"] == true { "only today so far, which is partial" } else { "today is left out until it's over" };
    let mut out = format!("{} to {} · {} logged days ({basis})\n", r["from"].as_str().unwrap_or(""), r["to"].as_str().unwrap_or(""), r["logged_days"]);
    // Averages are over the days with data for each nutrient; say so when that isn't every day.
    let logged = r["logged_days"].as_u64().unwrap_or(0);
    let days = |key: &str| match r["coverage"][key].as_u64() {
        Some(n) if n < logged => format!(" ({n} of {logged} days)"),
        _ => String::new(),
    };
    let avg = |key: &str, unit: &str, target: bool, show: fn(f64) -> String| {
        let target = if target { format!(" (target {})", num(get(t, key))) } else { String::new() };
        match a[key].as_f64() {
            Some(x) => format!("{} {unit}{target}{}", show(x), days(key)),
            None => format!("— {unit}{target}"),
        }
    };
    out.push_str(&format!("average: {} · protein {} · carbs {} · fat {} · fiber {}\n", avg("kcal", "kcal", true, num),
        avg("protein", "g", true, num), avg("carbs", "g", false, num), avg("fat", "g", false, num), avg("fiber", "g", false, amount)));
    let ad = &r["adherence"];
    out.push_str(&format!("adherence: kcal within 10% on {}/{} days · protein hit on {}/{} days\n", ad["kcal_within_10pct"], ad["of_days"], ad["protein_hit"], ad["of_days"]));
    let weakest: Vec<String> = r["weakest"].as_array().cloned().unwrap_or_default().iter().map(|w| {
        format!("{} {} {} avg, {}% ({} of {logged} days)", w["key"].as_str().unwrap_or(""), amount(get(w, "avg")), w["unit"].as_str().unwrap_or(""),
                num(get(w, "pct")), w["days"].as_u64().unwrap_or(logged))
    }).collect();
    if !weakest.is_empty() { out.push_str(&format!("weakest: {}\n", weakest.join(" · "))); }
    let over: Vec<String> = r["over_limits"].as_array().cloned().unwrap_or_default().iter().map(|w| {
        format!("{} {} / {}{}", w["key"].as_str().unwrap_or(""), amount(get(w, "avg")), amount(get(w, "target")), days(w["key"].as_str().unwrap_or("")))
    }).collect();
    if !over.is_empty() { out.push_str(&format!("over limits on average: {}\n", over.join(" · "))); }
    for key in ["kcal", "protein"] {
        let tr = &r["trends"][key];
        if tr.is_object() { out.push_str(&format!("{key} trend: {} → {}\n", num(get(tr, "first_half")), num(get(tr, "second_half")))); }
    }
    if let (Some(first), Some(last)) = (r["weight"]["first"].as_object(), r["weight"]["last"].as_object()) {
        out.push_str(&format!("weight: {} kg ({}) → {} kg ({})\n", amount(first["kg"].as_f64().unwrap_or(0.0)), first["day"].as_str().unwrap_or(""),
            amount(last["kg"].as_f64().unwrap_or(0.0)), last["day"].as_str().unwrap_or("")));
    }
    if let Some(active) = r["active_kcal_avg"].as_f64() { out.push_str(&format!("active energy: {} kcal/day\n", num(active))); }
    out.push('\n');
    for d in r["per_day"].as_array().cloned().unwrap_or_default() {
        let day = d["day"].as_str().unwrap_or("");
        let partial = if d["partial"] == true { " (so far)" } else { "" };
        if d["entries"] == 0 { out.push_str(&format!("  {} {day}  —\n", weekday(day))); continue; }
        out.push_str(&format!("  {} {day}  {} kcal · {} g protein{partial}\n", weekday(day), num(d["kcal"].as_f64().unwrap_or(0.0)), num(d["protein"].as_f64().unwrap_or(0.0))));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_parse() {
        let raw: Vec<String> = ["Burrito", "bowl", "--kcal", "750", "--n", "vit_c=30", "--json", "--meal=lunch"].iter().map(|s| s.to_string()).collect();
        let args = Args::parse("log", &raw).unwrap();
        assert_eq!(args.positional, vec!["Burrito", "bowl"]);
        assert!(args.has("json"));
        assert_eq!(args.get("meal"), Some("lunch"));
        let n = nutrient_flags(&args).unwrap();
        assert_eq!(n["kcal"], json!(750.0));
        assert_eq!(n["vit_c"], json!(30.0));
        assert!(Args::parse("log", &["--kcal".to_string()]).is_err());
        assert_eq!(num(12345.4), "12,345");
        assert_eq!(num(-1000.0), "-1,000");
        assert_eq!(amount(1.26), "1.3");
        assert_eq!(weekday("2026-11-08"), "Sun");
    }

    #[test]
    fn batch_log_prints_a_summary() {
        let reply = json!({
            "logged": [
                {"entry": {"id": "0123456789ab", "name": "Rice, white, cooked, no added fat", "grams": 200, "servings": 1.6,
                           "serving_label": "cup", "meal": "dinner", "nutrients": {"kcal": 260, "protein": 5.4}},
                 "matched": {"source_ref": "fdc:2708408"}},
                {"entry": {"id": "abcdef012345", "name": "Salsa verde", "grams": 30, "meal": "dinner", "nutrients": {"kcal": 15}},
                 "matched": {"source_ref": "agent:salsa-verde"}},
            ],
            "today": {"date": "2026-11-08", "targets": {"kcal": 2000, "protein": 150}, "totals": {"kcal": 275, "protein": 5.4}},
        });
        let items = vec![json!({"catalog": "rice white cooked", "grams": 200}), json!({"name": "Salsa verde"})];
        let text = format_logged(&reply, &items);
        assert_eq!(text.lines().count(), 3);
        assert!(text.starts_with("logged 01234567  Rice, white, cooked, no added fat · 200 g · 260 kcal · 5.4 g protein (fdc:2708408, for \"rice white cooked\") to dinner\n"), "{text}");
        assert!(text.contains("logged abcdef01  Salsa verde · 30 g · 15 kcal · 0 g protein (agent:salsa-verde) to dinner"), "{text}");
        assert!(text.ends_with("2026-11-08: 275 / 2,000 kcal (1,725 left) · protein 5 / 150 g (145 to go)\n"), "{text}");
        assert!(Args::parse("log", &["--json".to_string(), "--json-out".to_string()]).unwrap().has("json-out"));
    }

    fn strings(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn help_is_a_flag_and_bad_usage_points_at_help() {
        // --help never wants a value, and help requests return before any socket call.
        assert!(Args::parse("recipe", &strings(&["--help"])).unwrap().has("help"));
        for line in [&["recipe", "--help"][..], &["recipe", "add", "-h"], &["food", "fav", "--help"], &["goals", "set", "-h"],
                     &["log", "--json", "--help"], &["help", "log"], &["help", "nutrients"], &[]] {
            assert!(run(&strings(line)).is_ok(), "{line:?}");
        }
        let error = Args::parse("log", &strings(&["Toast", "--kcal", "80", "--catlog", "x"])).err().unwrap();
        assert!(error.contains("--catlog") && error.contains("food log --help"), "{error}");
        assert!(Args::parse("edit", &strings(&["abcd", "--vit_c", "30", "--n", "iron=2"])).is_ok());
        assert!(Args::parse("today", &strings(&["--kcal", "5"])).is_err());
        assert!(Args::parse("search", &strings(&["rice", "--no-off", "--limit", "5", "--json"])).is_ok());
        let error = Args::parse("log", &strings(&["--grams"])).err().unwrap();
        assert!(error.contains("food log --help"), "{error}");
        let error = run(&strings(&["lgo"])).unwrap_err();
        assert!(error.contains("food --help"), "{error}");
        let error = run(&strings(&["goals", "plan", "shred"])).unwrap_err();
        assert!(error.contains("food goals --help"), "{error}");
    }
}
