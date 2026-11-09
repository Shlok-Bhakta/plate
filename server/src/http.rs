//! The app's HTTP API, on 127.0.0.1:18792 by default (the `listen` setting). It speaks plain HTTP,
//! so reach it from a phone through something that adds TLS: `tailscale serve`, or a reverse
//! proxy such as Caddy. A small
//! HTTP/1.1 server of its own, so it controls the sockets: one thread per connection (a long-poll
//! doesn't hold up anything else) up to a limit, past which a connection is answered 503; every
//! read and write times out; the request line, headers and body must arrive by a deadline; and a
//! body over 2 MB is a 413. One request per connection (`Connection: close`).

use crate::db::{self, State};
use crate::{nutrients, service, store};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const MAX_BODY: usize = 2 * 1024 * 1024;
const MAX_HEAD: u64 = 64 * 1024;
/// Days one POST /v1/health_days may carry.
const MAX_HEALTH_DAYS: usize = 1000;
/// Writing a reply; reads are bounded by the request deadline instead.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);
/// From accepting a connection to having its whole request, body included.
const REQUEST_DEADLINE: Duration = Duration::from_secs(15);

/// A counted limit on concurrent work. `enter` gives a pass while there's room; dropping the pass
/// gives the room back.
pub struct Gate {
    busy: AtomicUsize,
    max: usize,
}

impl Gate {
    pub const fn new(max: usize) -> Gate {
        Gate { busy: AtomicUsize::new(0), max }
    }

    pub fn enter(&'static self) -> Option<Pass> {
        self.busy.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| (n < self.max).then_some(n + 1)).ok().map(|_| Pass(self))
    }
}

pub struct Pass(&'static Gate);

impl Drop for Pass {
    fn drop(&mut self) {
        self.0.busy.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Connections being served at once.
static CONNECTIONS: Gate = Gate::new(64);
/// Connections being turned away at once (each reads its request, so the 503 isn't lost to a reset).
static REFUSALS: Gate = Gate::new(16);
/// Long-polls waiting at once; past this a sync answers straight away.
static LONG_POLLS: Gate = Gate::new(32);

#[derive(Clone, Copy)]
struct Limits {
    connections: &'static Gate,
    refusals: &'static Gate,
    deadline: Duration,
}

pub fn serve(state: Arc<State>) -> Result<(), String> {
    let listen = crate::config::get().listen.clone();
    let listener = TcpListener::bind(&listen).map_err(|e| format!("can't listen on {listen}: {e}"))?;
    let local = listener.local_addr().map(|a| a.ip().is_loopback()).unwrap_or(false);
    eprintln!("listening on {listen}");
    if !local {
        eprintln!("warning: {listen} is reachable from other machines over plain HTTP; the token and your data travel \
                   unencrypted. Prefer 127.0.0.1 behind Tailscale or a TLS reverse proxy.");
    }
    run(&state, &listener, Limits { connections: &CONNECTIONS, refusals: &REFUSALS, deadline: REQUEST_DEADLINE });
    Ok(())
}

fn run(state: &Arc<State>, listener: &TcpListener, limits: Limits) {
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(error) => {
                // Out of file descriptors, say: back off instead of spinning.
                eprintln!("accept failed: {error}");
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
        };
        let (pass, busy) = match limits.connections.enter() {
            Some(pass) => (pass, false),
            None => match limits.refusals.enter() {
                Some(pass) => (pass, true),
                None => continue, // dropped: closes the connection
            },
        };
        let state = state.clone();
        let spawned = std::thread::Builder::new().name("http".into()).spawn(move || {
            let _pass = pass;
            connection(&state, stream, limits.deadline, busy);
        });
        if let Err(error) = spawned {
            // The connection went with the closure and is closed; the client retries.
            eprintln!("can't start a connection thread: {error}");
        }
    }
}

/// A read side that gives up at a deadline: each read waits only for the time that's left.
struct Deadline {
    stream: TcpStream,
    deadline: Instant,
}

impl Read for Deadline {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let left = self.deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(ErrorKind::TimedOut.into());
        }
        self.stream.set_read_timeout(Some(left))?;
        self.stream.read(buf)
    }
}

pub struct Request {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    reader: BufReader<Deadline>,
    writer: TcpStream,
}

impl Request {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }

    /// Reads the request line and headers.
    fn read(stream: TcpStream, deadline: Instant) -> Result<Request, (u16, String)> {
        let writer = stream.try_clone().map_err(|e| server_error(e.to_string()))?;
        let mut reader = BufReader::new(Deadline { stream, deadline });
        let mut head = (&mut reader).take(MAX_HEAD);
        let mut line = String::new();
        let mut read_line = |line: &mut String| -> Result<(), (u16, String)> {
            line.clear();
            match head.read_line(line) {
                Ok(0) => Err((400, "the request ended early".into())),
                Ok(_) if !line.ends_with('\n') => Err((431, "the request head is over 64 KB".into())),
                Ok(_) => Ok(()),
                Err(e) => Err(io_error(e)),
            }
        };
        read_line(&mut line)?;
        let mut parts = line.split_whitespace();
        let (Some(method), Some(target), Some(version)) = (parts.next(), parts.next(), parts.next()) else {
            return Err(bad("bad request line"));
        };
        if !version.starts_with("HTTP/1.") {
            return Err((505, "HTTP/1.x only".into()));
        }
        let (method, target) = (method.to_string(), target.to_string());
        let mut headers = Vec::new();
        loop {
            read_line(&mut line)?;
            let text = line.trim_end_matches(['\r', '\n']);
            if text.is_empty() {
                break;
            }
            let (name, value) = text.split_once(':').ok_or_else(|| bad("bad header"))?;
            headers.push((name.trim().to_string(), value.trim().to_string()));
        }
        Ok(Request { method, target, headers, reader, writer })
    }

    /// The body, by Content-Length or chunked, at most `max` bytes.
    fn body(&mut self, max: usize) -> Result<Vec<u8>, (u16, String)> {
        let chunked = self.header("Transfer-Encoding").is_some_and(|t| t.to_ascii_lowercase().contains("chunked"));
        let length = match self.header("Content-Length") {
            Some(n) if !chunked => Some(n.parse::<usize>().map_err(|_| bad("bad Content-Length"))?),
            _ => None,
        };
        if length.is_some_and(|n| n > max) {
            return Err((413, "body over 2 MB".into()));
        }
        if self.header("Expect").is_some_and(|e| e.eq_ignore_ascii_case("100-continue")) {
            let _ = self.writer.write_all(b"HTTP/1.1 100 Continue\r\n\r\n");
        }
        if chunked {
            return read_chunked(&mut self.reader, max);
        }
        let length = length.unwrap_or(0);
        let body = read_body(&mut (&mut self.reader).take(length as u64), max)?;
        if body.len() < length {
            return Err(bad("the body ended early"));
        }
        Ok(body)
    }
}

/// Reads to the end, at most `max` bytes. A read that runs past the deadline is a 408.
fn read_body(reader: &mut dyn Read, max: usize) -> Result<Vec<u8>, (u16, String)> {
    let mut body = Vec::new();
    reader.take(max as u64 + 1).read_to_end(&mut body).map_err(io_error)?;
    if body.len() > max {
        return Err((413, "body over 2 MB".into()));
    }
    Ok(body)
}

fn read_chunked(reader: &mut impl BufRead, max: usize) -> Result<Vec<u8>, (u16, String)> {
    let mut body = Vec::new();
    let mut line = String::new();
    loop {
        line.clear();
        reader.take(1024).read_line(&mut line).map_err(io_error)?;
        let size = line.split(';').next().map(str::trim).and_then(|n| usize::from_str_radix(n, 16).ok()).ok_or_else(|| bad("bad chunk"))?;
        if size == 0 {
            // Trailers, then the blank line.
            loop {
                line.clear();
                if reader.take(MAX_HEAD).read_line(&mut line).map_err(io_error)? == 0 || line.trim().is_empty() {
                    return Ok(body);
                }
            }
        }
        if body.len() + size > max {
            return Err((413, "body over 2 MB".into()));
        }
        let start = body.len();
        body.resize(start + size, 0);
        reader.read_exact(&mut body[start..]).map_err(io_error)?;
        let mut crlf = [0u8; 2];
        reader.read_exact(&mut crlf).map_err(io_error)?;
    }
}

fn io_error(error: std::io::Error) -> (u16, String) {
    match error.kind() {
        ErrorKind::TimedOut | ErrorKind::WouldBlock => (408, "the request took too long to arrive".into()),
        ErrorKind::UnexpectedEof => bad("the request ended early"),
        _ => bad(format!("can't read the request: {error}")),
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        408 => "Request Timeout",
        413 => "Content Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        _ => "Status",
    }
}

/// Serves one connection: one request, one reply, then close.
fn connection(state: &State, stream: TcpStream, deadline: Duration, busy: bool) {
    let started = Instant::now();
    let _ = stream.set_write_timeout(Some(WRITE_TIMEOUT));
    let _ = stream.set_nodelay(true);
    let mut writer = match stream.try_clone() {
        Ok(writer) => writer,
        Err(_) => return,
    };
    let (status, body, shown) = match Request::read(stream, started + deadline) {
        Err((status, error)) => (status, json!({"error": error}), String::new()),
        Ok(_) if busy => (503, json!({"error": "the server is busy; try again"}), String::new()),
        Ok(mut request) => {
            let target = std::mem::take(&mut request.target);
            let (path, query) = target.split_once('?').unwrap_or((&target, ""));
            let (status, body) = match handle(state, &mut request, path, query) {
                Ok(body) => (200, body),
                Err((status, error)) => (status, json!({"error": error})),
            };
            // Paths only: search terms and barcodes stay out of the journal.
            let shown = if path.starts_with("/v1/barcode/") { "/v1/barcode/…" } else { path };
            (status, body, format!("{} {shown}", request.method))
        }
    };
    if shown.is_empty() {
        eprintln!("-> {status} ({})", body["error"].as_str().unwrap_or(""));
    } else {
        eprintln!("{shown} -> {status} in {} ms", started.elapsed().as_millis());
    }
    let text = body.to_string();
    let head = format!("HTTP/1.1 {status} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                       reason(status), text.len());
    if writer.write_all(head.as_bytes()).and_then(|_| writer.write_all(text.as_bytes())).is_err() {
        return;
    }
    // Close gracefully: send FIN, then wait for the peer to close before dropping the socket.
    // Dropping it straight away can reset the connection and lose the end of a large reply; behind
    // `tailscale serve`, replies over about 128 KB stalled until the client timed out. The peer
    // closes as soon as it has the whole reply (Connection: close), so this rarely waits long.
    let _ = writer.shutdown(Shutdown::Write);
    let _ = writer.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = (&writer).take(4 * MAX_BODY as u64).read_to_end(&mut Vec::new());
}

type Reply = Result<Value, (u16, String)>;

fn bad(error: impl Into<String>) -> (u16, String) {
    (400, error.into())
}

fn server_error(error: String) -> (u16, String) {
    (500, error)
}

pub fn param(query: &str, name: &str) -> Option<String> {
    query.split('&').filter_map(|pair| pair.split_once('=').or(Some((pair, "")))).find(|(k, _)| *k == name).map(|(_, v)| decode(v))
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = bytes.get(i + 1..i + 3).and_then(|h| std::str::from_utf8(h).ok()).and_then(|h| u8::from_str_radix(h, 16).ok());
        match (bytes[i], hex) {
            (b'+', _) => out.push(b' '),
            (b'%', Some(b)) => {
                out.push(b);
                i += 2;
            }
            (b, _) => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn authorized(state: &State, request: &Request) -> bool {
    // Tokens are stored hashed, so comparing hashes needs no constant-time trick.
    request.headers.iter().any(|(name, value)| {
        name.eq_ignore_ascii_case("Authorization") && value.strip_prefix("Bearer ").is_some_and(|t| db::token_valid(&state.lock(), t.trim()))
    })
}

fn handle(state: &State, request: &mut Request, path: &str, query: &str) -> Reply {
    let method = request.method.clone();
    if (method.as_str(), path) == ("GET", "/v1/ping") {
        return Ok(json!({"ok": true, "version": db::version(&state.lock())}));
    }
    if !path.starts_with("/v1/") {
        return Err((404, "not found".into()));
    }
    if !authorized(state, request) {
        return Err((401, "bad or missing token".into()));
    }
    match (method.as_str(), path) {
        ("GET", "/v1/meta") => Ok(nutrients::meta()),
        ("GET", "/v1/sync") => {
            let since = param(query, "since").and_then(|s| s.parse::<i64>().ok()).unwrap_or(0).max(0);
            let wait = param(query, "wait").and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0).clamp(0.0, 25.0);
            let current = db::version(&state.lock());
            // A client ahead of the server (a restored database) gets everything again.
            if since > current {
                let mut snapshot = store::sync(&state.lock(), 0).map_err(server_error)?;
                snapshot["reset"] = json!(true);
                return Ok(snapshot);
            }
            if wait > 0.0 && current <= since {
                // With every long-poll slot taken, answer now (no changes); the client polls again.
                if let Some(_pass) = LONG_POLLS.enter() {
                    state.wait_past(since, Duration::from_secs_f64(wait));
                }
            }
            store::sync(&state.lock(), since).map_err(server_error)
        }
        ("POST", "/v1/mutations") => {
            let body = read_json(request)?;
            let list = body["mutations"].as_array().ok_or_else(|| bad("send {\"mutations\": [...]}"))?;
            mutations(state, list).map_err(server_error)
        }
        ("GET", "/v1/search") => {
            let q = param(query, "q").unwrap_or_default();
            if q.trim().is_empty() {
                return Ok(json!({"results": []}));
            }
            let limit = param(query, "limit").and_then(|s| s.parse().ok()).unwrap_or(25);
            let with_off = param(query, "off").as_deref() != Some("0");
            service::search(state, &q, limit, with_off).map_err(server_error)
        }
        ("POST", "/v1/health_days") => {
            let body = read_json(request)?;
            if !body["days"].is_array() && !body["profile"].is_object() {
                return Err(bad("send {\"days\": [{\"day\": \"YYYY-MM-DD\", ...}], \"profile\": {...}}"));
            }
            if body["days"].as_array().is_some_and(|d| d.len() > MAX_HEALTH_DAYS) {
                return Err(bad(format!("at most {MAX_HEALTH_DAYS} days per request")));
            }
            service::health(state, &body).map_err(bad)
        }
        ("GET", "/v1/suggest") => {
            let (meal, day) = (param(query, "meal"), param(query, "day"));
            service::suggest(&state.lock(), meal.as_deref(), day.as_deref()).map_err(server_error)
        }
        ("GET", p) if p.starts_with("/v1/barcode/") => {
            let code = &p["/v1/barcode/".len()..];
            match service::barcode(state, code) {
                Ok(Some(food)) => Ok(json!({"food": food})),
                Ok(None) => Err((404, format!("no product with barcode {code}"))),
                Err(e) if e.starts_with("a barcode") => Err(bad(e)),
                Err(e) => Err((502, e)),
            }
        }
        _ => Err((404, "not found".into())),
    }
}

fn read_json(request: &mut Request) -> Result<Value, (u16, String)> {
    let body = request.body(MAX_BODY)?;
    serde_json::from_slice(&body).map_err(|e| bad(format!("body is not JSON: {e}")))
}

/// Applies a batch in one transaction. A bad mutation is reported and skipped, so one broken row
/// can't wedge the phone's outbox.
pub fn mutations(state: &State, list: &[Value]) -> Result<Value, String> {
    state.write(|db| {
        let mut applied = 0;
        let mut ids = serde_json::Map::new();
        let mut errors = Vec::new();
        for (i, m) in list.iter().enumerate() {
            let (table, op) = (m["table"].as_str().unwrap_or(""), m["op"].as_str().unwrap_or(""));
            match store::apply_from(db, table, op, &m["row"], store::Origin::App) {
                Ok(outcome) => {
                    applied += usize::from(outcome.applied);
                    if let Some(sent) = m["row"]["id"].as_str().filter(|sent| *sent != outcome.id) {
                        ids.insert(sent.to_string(), json!(outcome.id));
                    }
                }
                Err(error) => errors.push(json!({"index": i, "error": error})),
            }
        }
        Ok(json!({"version": db::version(db), "applied": applied, "ids": ids, "errors": errors}))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: i64 = 1_790_000_000_000;

    #[test]
    fn query_params_decode() {
        assert_eq!(param("q=chicken+breast&limit=5", "q").unwrap(), "chicken breast");
        assert_eq!(param("q=caf%C3%A9%20au%20lait", "q").unwrap(), "café au lait");
        assert_eq!(param("q=100%", "q").unwrap(), "100%");
        assert_eq!(param("since=4", "wait"), None);
    }

    #[test]
    fn mutation_batches_skip_bad_rows_and_report_dedupes() {
        let state = State::new(db::memory());
        let out = mutations(&state, &[
            json!({"table": "foods", "op": "upsert", "row": {"id": "a", "name": "Oats", "source_ref": "fdc:1", "updated_at": T + 1}}),
            json!({"table": "foods", "op": "upsert", "row": {"id": "b", "name": "Oats", "source_ref": "fdc:1", "updated_at": T + 2}}),
            json!({"table": "health_days", "op": "upsert", "row": {"id": "2026-11-08"}}),
            json!({"table": "entries", "op": "upsert", "row": {"id": "e", "food_id": "b", "day": "2026-11-08", "updated_at": T + 3}}),
            json!({"table": "entries", "op": "upsert", "row": {"id": "late", "day": "2026-11-08", "updated_at": i64::MAX}}),
            json!({"table": "entries", "op": "upsert", "row": "not an object"}),
        ]).unwrap();
        assert_eq!(out["applied"], 3);
        assert_eq!(out["ids"]["b"], "a");
        assert_eq!(out["errors"][0]["index"], 2);
        assert_eq!(out["errors"][1]["index"], 4);
        assert!(out["errors"][1]["error"].as_str().unwrap().contains("updated_at"));
        assert_eq!(out["errors"][2]["index"], 5);
        assert_eq!(store::live(&state.lock(), "entries", "e").unwrap().unwrap()["food_id"], "a");
        // Retrying the merged food (its reply was lost) still maps it, and changes nothing.
        let version = db::version(&state.lock());
        let retry = mutations(&state, &[
            json!({"table": "foods", "op": "upsert", "row": {"id": "b", "name": "Oats", "source_ref": "fdc:1", "updated_at": T + 2}}),
        ]).unwrap();
        assert_eq!((retry["applied"].as_u64(), retry["ids"]["b"].as_str()), (Some(0), Some("a")));
        assert_eq!(db::version(&state.lock()), version);
    }

    #[test]
    fn gates_count_passes() {
        let gate: &'static Gate = Box::leak(Box::new(Gate::new(2)));
        let (a, b) = (gate.enter(), gate.enter());
        assert!(a.is_some() && b.is_some() && gate.enter().is_none());
        drop(a);
        assert!(gate.enter().is_some(), "a dropped pass frees its room");
    }

    #[test]
    fn bodies_have_a_size_limit() {
        assert_eq!(read_body(&mut &b"{}"[..], 100).unwrap(), b"{}");
        assert_eq!(read_body(&mut &[b' '; 101][..], 100).unwrap_err().0, 413);
        assert_eq!(read_chunked(&mut &b"5;x=y\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: 1\r\n\r\n"[..], 100).unwrap(), b"hello world");
        assert_eq!(read_chunked(&mut &b"65\r\n"[..], 100).unwrap_err().0, 413);
        assert_eq!(read_chunked(&mut &b"zz\r\n"[..], 100).unwrap_err().0, 400);
        assert_eq!(io_error(ErrorKind::WouldBlock.into()).0, 408);
    }

    /// Sends one raw HTTP request and returns the status code (0 when the server just closed).
    fn http(addr: std::net::SocketAddr, request: &str) -> u16 {
        let mut stream = TcpStream::connect(addr).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        let mut reply = String::new();
        let _ = stream.read_to_string(&mut reply);
        reply.split(' ').nth(1).and_then(|code| code.parse().ok()).unwrap_or(0)
    }

    #[test]
    fn a_full_server_answers_503_and_slow_clients_time_out() {
        let state = Arc::new(State::new(db::memory()));
        let (token, _) = db::rotate_token(&state.lock(), 0).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let leak = |max| -> &'static Gate { Box::leak(Box::new(Gate::new(max))) };
        let limits = Limits { connections: leak(1), refusals: leak(4), deadline: Duration::from_millis(500) };
        let served = state.clone();
        std::thread::spawn(move || run(&served, &listener, limits));
        let ping = "GET /v1/ping HTTP/1.1\r\nHost: x\r\n\r\n";
        assert_eq!(http(addr, ping), 200);
        assert_eq!(http(addr, "GET /nope HTTP/1.1\r\n\r\n"), 404);
        assert_eq!(http(addr, "GET /v1/meta HTTP/1.1\r\n\r\n"), 401);

        // A long-poll holds the only connection slot, so a ping meanwhile is turned away.
        let since = db::version(&state.lock());
        let poll = format!("GET /v1/sync?since={since}&wait=1.5 HTTP/1.1\r\nAuthorization: Bearer {token}\r\n\r\n");
        let polling = std::thread::spawn(move || http(addr, &poll));
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(http(addr, ping), 503);
        assert_eq!(polling.join().unwrap(), 200);
        assert_eq!(http(addr, ping), 200, "the slot is free again");

        // Mutations by Content-Length and chunked.
        let auth = format!("Authorization: Bearer {token}\r\n");
        let body = r#"{"mutations": [{"table": "entries", "op": "upsert", "row": {"id": "e", "day": "2026-11-08", "updated_at": 1790000000000}}]}"#;
        let post = format!("POST /v1/mutations HTTP/1.1\r\n{auth}Content-Length: {}\r\n\r\n{body}", body.len());
        assert_eq!(http(addr, &post), 200);
        let chunked = format!("POST /v1/mutations HTTP/1.1\r\n{auth}Transfer-Encoding: chunked\r\n\r\n{:x}\r\n{body}\r\n0\r\n\r\n", body.len());
        assert_eq!(http(addr, &chunked), 200);
        assert!(store::live(&state.lock(), "entries", "e").unwrap().is_some());

        // Health days pushed by the app, with the same token.
        let today = crate::time::today();
        let push = format!(r#"{{"days": [{{"day": "{today}", "weight_kg": 70.5, "steps": 8000}}], "profile": {{"sex": "female"}}}}"#);
        let post = |path: &str, body: &str, auth: &str| format!("POST {path} HTTP/1.1\r\n{auth}Content-Length: {}\r\n\r\n{body}", body.len());
        assert_eq!(http(addr, &post("/v1/health_days", &push, "")), 401);
        assert_eq!(http(addr, &post("/v1/health_days", &push, &auth)), 200);
        assert_eq!(http(addr, &post("/v1/health_days", "[1]", &auth)), 400);
        let row = store::live(&state.lock(), "health_days", &today).unwrap().unwrap();
        assert_eq!((row["weight_kg"].as_f64(), row["steps"].as_f64()), (Some(70.5), Some(8000.0)));

        // A body that stops arriving is a 408 at the deadline, and a body over the limit a 413.
        let started = Instant::now();
        assert_eq!(http(addr, &format!("POST /v1/mutations HTTP/1.1\r\n{auth}Content-Length: 5000\r\n\r\n{{\"mutations\"")), 408);
        assert!(started.elapsed() < Duration::from_secs(3));
        assert_eq!(http(addr, &format!("POST /v1/mutations HTTP/1.1\r\n{auth}Content-Length: {}\r\n\r\n", MAX_BODY + 1)), 413);

        // So is a client that never finishes its headers.
        let started = Instant::now();
        assert_eq!(http(addr, "GET /v1/ping HTTP/1.1\r\n"), 408);
        assert!(started.elapsed() < Duration::from_secs(3));
        assert_eq!(http(addr, ping), 200);
    }

    #[test]
    fn long_poll_wakes_on_a_write() {
        let state = Arc::new(State::new(db::memory()));
        let waiter = state.clone();
        let started = std::time::Instant::now();
        let handle = std::thread::spawn(move || waiter.wait_past(0, Duration::from_secs(10)));
        std::thread::sleep(Duration::from_millis(100));
        mutations(&state, &[json!({"table": "entries", "op": "upsert", "row": {"id": "e", "day": "2026-11-08", "updated_at": T + 1}})]).unwrap();
        assert!(handle.join().unwrap() > 0);
        assert!(started.elapsed() < Duration::from_secs(2));
        let started = std::time::Instant::now();
        state.wait_past(100, Duration::from_millis(200));
        assert!(started.elapsed() >= Duration::from_millis(200));
    }
}
