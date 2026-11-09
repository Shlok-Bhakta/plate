//! Local access for the CLI (and the agents that use it). The database and its key stay inside the
//! service, which answers one JSON request per connection on a Unix socket. The kernel says who is
//! calling (SO_PEERCRED, or getpeereid on macOS and the BSDs); only the service's own user, root
//! and the configured `socket_uids` are served. The socket can write: logging goes through it.

use crate::db::{self, State};
use crate::http::{self, Gate};
use crate::{agent, backup, catalog, goals, service, time};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

const MAX_LINE: u64 = 64 << 20;

pub fn path() -> PathBuf {
    crate::config::get().socket.clone()
}

fn allowed(uid: u32, extra: &[u32]) -> bool {
    uid == 0 || uid == unsafe { libc::getuid() } || extra.contains(&uid)
}

pub fn spawn(state: Arc<State>) -> Result<(), String> {
    let path = path();
    if UnixStream::connect(&path).is_ok() {
        return Err(format!("another food service is already answering on {}", path.display()));
    }
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty() && !d.exists()) {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(|e| format!("can't create {}: {e}", dir.display()))?;
    }
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).map_err(|e| format!("can't listen on {}: {e}", path.display()))?;
    // Anyone who can reach it may connect; the peer check decides who is answered.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).map_err(|e| e.to_string())?;
    let extra = crate::config::get().socket_uids.clone();
    std::thread::Builder::new()
        .name("socket".into())
        .spawn(move || {
            for stream in listener.incoming().flatten() {
                accept(&state, stream, &CLIENTS, &extra);
            }
        })
        .map_err(|e| format!("can't start the socket thread: {e}"))?;
    Ok(())
}

/// Connections served at once; past this a caller is told to try again.
static CLIENTS: Gate = Gate::new(16);

fn accept(state: &Arc<State>, stream: UnixStream, gate: &'static Gate, extra: &[u32]) {
    let Some(pass) = gate.enter() else {
        refuse(stream, "the food service is busy; try again");
        return;
    };
    // A second handle on the connection, to answer on if its thread can't start.
    let spare = stream.try_clone();
    let state = state.clone();
    let extra = extra.to_vec();
    let spawned = std::thread::Builder::new().name("socket-client".into()).spawn(move || {
        let _pass = pass;
        serve_client(&state, stream, &extra);
    });
    if let Err(error) = spawned {
        eprintln!("can't start a socket thread: {error}");
        if let Ok(stream) = spare {
            refuse(stream, "the food service can't start a worker; try again");
        }
    }
}

fn refuse(mut stream: UnixStream, error: &str) {
    let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
    let _ = stream.write_all((json!({"ok": false, "error": error}).to_string() + "\n").as_bytes());
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    use std::os::fd::AsRawFd;
    let mut cred = libc::ucred { pid: 0, uid: u32::MAX, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED,
                         &mut cred as *mut libc::ucred as *mut libc::c_void, &mut len)
    };
    (result == 0).then_some(cred.uid)
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    use std::os::fd::AsRawFd;
    let (mut uid, mut gid) = (u32::MAX, u32::MAX);
    let result = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    (result == 0).then_some(uid)
}

fn serve_client(state: &Arc<State>, mut stream: UnixStream, extra: &[u32]) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(120)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(120)));
    let reply = match peer_uid(&stream) {
        Some(uid) if allowed(uid, extra) => {
            let mut line = String::new();
            match BufReader::new((&stream).take(MAX_LINE)).read_line(&mut line) {
                Ok(_) => handle(state, &line),
                Err(e) => json!({"ok": false, "error": e.to_string()}),
            }
        }
        _ => json!({"ok": false, "error": "not allowed: this user isn't in the service's socket_uids"}),
    };
    let _ = stream.write_all((reply.to_string() + "\n").as_bytes());
}

fn text<'a>(request: &'a Value, key: &str) -> Result<&'a str, String> {
    request[key].as_str().ok_or_else(|| format!("{} needs {key}", request["cmd"]))
}

pub fn handle(state: &Arc<State>, line: &str) -> Value {
    let Ok(request) = serde_json::from_str::<Value>(line) else {
        return json!({"ok": false, "error": "send one JSON object per line"});
    };
    let r = &request;
    let result: Result<Value, String> = match r["cmd"].as_str().unwrap_or("") {
        "ping" => Ok(json!({"version": db::version(&state.lock())})),
        "query" => (|| {
            let sql = text(r, "sql")?;
            let (rows, truncated) = db::run_query(&db::open_read_only()?, sql)?;
            Ok(json!({"rows": rows, "truncated": truncated}))
        })(),
        "rotate-token" => (|| {
            let grace = r["grace_hours"].as_i64().unwrap_or(48);
            let (token, expires) = state.write(|db| db::rotate_token(db, grace))?;
            Ok(json!({"token": token, "old_tokens_expire": expires}))
        })(),
        "log" => service::log(state, r["items"].as_array().map(Vec::as_slice).unwrap_or(&[])),
        "edit" => text(r, "id").and_then(|id| service::edit(state, id, &r["changes"])).map(|e| json!({"entry": e})),
        "rm" => {
            let ids: Vec<String> = r["ids"].as_array().map(|l| l.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
            let table = if r["table"] == "foods" { "foods" } else { "entries" };
            service::remove(state, table, &ids)
        }
        "today" => time::resolve_day(r["date"].as_str().unwrap_or("today")).and_then(|day| service::day_summary(&state.lock(), &day)),
        "entries" => (|| {
            let from = time::resolve_day(r["from"].as_str().unwrap_or("today"))?;
            let to = time::resolve_day(r["to"].as_str().unwrap_or("today"))?;
            service::entries(&state.lock(), &from, &to)
        })(),
        "search" => service::search(state, text(r, "q").unwrap_or(""), r["limit"].as_u64().unwrap_or(15) as usize, r["off"] != false),
        "barcode" => text(r, "code").and_then(|code| service::barcode(state, code)).map(|food| json!({"food": food})),
        "suggest" => r["day"].as_str().map(time::resolve_day).transpose()
            .and_then(|day| service::suggest(&state.lock(), r["meal"].as_str(), day.as_deref())),
        "foods" => service::list_foods(&state.lock(), r["favorites"] == true),
        "food-add" => service::add_food(state, &r["food"]).map(|f| json!({"food": f})),
        "fav" => text(r, "id").and_then(|id| service::favorite(state, id, r["on"] != false)).map(|f| json!({"food": f})),
        "goals" => goals::current(&state.lock()).map(|g| json!({"goals": g})),
        "goals-update" => service::update_goals(state, &r["changes"]).map(|g| json!({"goals": g})),
        "report" => service::report(&state.lock(), r["days"].as_i64().unwrap_or(7)),
        "health" => service::health(state, r),
        "profile" => service::set_profile(state, &r["set"]),
        "export" => backup::export(&state.lock()),
        "restore" => backup::restore(state, r),
        "config" => Ok(json!({"timezone": time::zone_name(), "database": db::path(), "version": db::version(&state.lock())})),
        "sync" => crate::store::sync(&state.lock(), r["since"].as_i64().unwrap_or(0)),
        "mutations" => http::mutations(state, r["mutations"].as_array().map(Vec::as_slice).unwrap_or(&[])),
        "catalog-import" => state
            .write(|db| catalog::import(db, r["items"].as_array().map(Vec::as_slice).unwrap_or(&[])))
            .map(|n| json!({"imported": n})),
        "catalog-finish" => state.write(|db| catalog::finish(db, &r["sources"])),
        "agent-config" if r["set"].is_object() => agent::update_config(state, &r["set"]).map_err(|e| e.1),
        "agent-config" => agent::config(&state.lock()),
        "agent-models" => agent::models(state, r["q"].as_str().unwrap_or("")).map_err(|e| e.1),
        "agent-test" => agent::test(state).map_err(|e| e.1),
        "agent-job" => agent::create(state, &r["job"]).map_err(|e| e.1),
        "agent-job-get" => text(r, "id").and_then(|id| agent::get(state, id, r["wait"].as_f64().unwrap_or(0.0)).map_err(|e| e.1)),
        "agent-confirm" => text(r, "id").and_then(|id| agent::confirm(state, id, r).map_err(|e| e.1)),
        "agent-delete" => text(r, "id").and_then(|id| agent::delete(state, id).map_err(|e| e.1)),
        other => Err(format!("unknown cmd {other:?}")),
    };
    match result {
        Ok(mut value) => {
            if let Some(object) = value.as_object_mut() {
                object.insert("ok".into(), json!(true));
                value
            } else {
                json!({"ok": true, "value": value})
            }
        }
        Err(error) => json!({"ok": false, "error": error}),
    }
}

/// The client side, used by every CLI command.
pub fn call(request: Value) -> Result<Value, String> {
    let path = path();
    let mut stream = UnixStream::connect(&path).map_err(|e| {
        format!("can't reach the food service at {}: {e}\n  is `food serve` running? (`food config` shows the socket it uses)", path.display())
    })?;
    stream.write_all((request.to_string() + "\n").as_bytes()).map_err(|e| e.to_string())?;
    let mut reply = String::new();
    stream.read_to_string(&mut reply).map_err(|e| e.to_string())?;
    let reply: Value = serde_json::from_str(&reply).map_err(|_| format!("bad reply: {reply}"))?;
    if reply.get("ok") == Some(&Value::Bool(true)) {
        Ok(reply)
    } else {
        Err(reply.get("error").and_then(Value::as_str).unwrap_or("failed").to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_root_the_service_and_listed_users_are_served() {
        let me = unsafe { libc::getuid() };
        assert!(allowed(0, &[]) && allowed(me, &[]));
        assert!(allowed(1000, &[1000]));
        if me != 1234 {
            assert!(!allowed(1234, &[1000]));
        }
        // The real check, over a socket pair: this process is its own peer.
        let (a, _b) = UnixStream::pair().unwrap();
        assert_eq!(peer_uid(&a), Some(me));
    }

    #[test]
    fn a_full_socket_refuses_with_an_error() {
        let state = Arc::new(State::new(db::memory()));
        let gate: &'static Gate = Box::leak(Box::new(Gate::new(1)));
        let held = gate.enter();
        let (ours, theirs) = UnixStream::pair().unwrap();
        accept(&state, theirs, gate, &[]);
        let mut reply = String::new();
        BufReader::new(&ours).read_line(&mut reply).unwrap();
        let reply: Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(reply["ok"], false);
        assert!(reply["error"].as_str().unwrap().contains("busy"));
        drop(held);
        // With room again, the connection is served (and its pass given back after).
        let (mut ours, theirs) = UnixStream::pair().unwrap();
        accept(&state, theirs, gate, &[]);
        ours.write_all(b"{\"cmd\":\"ping\"}\n").unwrap();
        let mut reply = String::new();
        ours.read_to_string(&mut reply).unwrap();
        assert!(reply.contains("\"ok\":true"), "{reply}");
        std::thread::sleep(Duration::from_millis(50));
        assert!(gate.enter().is_some());
    }

    #[test]
    fn requests_are_checked() {
        let state = Arc::new(State::new(db::memory()));
        assert_eq!(handle(&state, "not json")["ok"], false);
        assert_eq!(handle(&state, r#"{"cmd":"drop"}"#)["ok"], false);
        assert_eq!(handle(&state, r#"{"cmd":"ping"}"#)["ok"], true);
        assert_eq!(handle(&state, r#"{"cmd":"log","items":[{"name":"x"}]}"#)["ok"], false);
    }
}
