//! The schema, the encryption key, tokens, the version counter and the read-only query path. The
//! file is SQLCipher, keyed from a key file or a systemd credential, or plain SQLite when the
//! config says `encryption = none`.

use crate::config::{Config, Encryption};
use rusqlite::{params, Connection, OpenFlags};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const SCHEMA: &str = "
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);

-- Synced tables share these columns. `version` comes from meta.version, bumped on every write;
-- `updated_at` is the writer's clock in ms and decides last-writer-wins; `data` is the row's JSON.
CREATE TABLE IF NOT EXISTS foods (
    id         TEXT PRIMARY KEY,
    version    INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted    INTEGER NOT NULL DEFAULT 0,
    data       TEXT NOT NULL,
    kind       TEXT,
    name       TEXT,
    source_ref TEXT,
    barcode    TEXT,                     -- leading zeros stripped, so UPC-A and EAN-13 match
    favorite   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS foods_version ON foods (version);
CREATE INDEX IF NOT EXISTS foods_source_ref ON foods (source_ref);
CREATE INDEX IF NOT EXISTS foods_barcode ON foods (barcode);

CREATE TABLE IF NOT EXISTS entries (
    id         TEXT PRIMARY KEY,
    version    INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted    INTEGER NOT NULL DEFAULT 0,
    data       TEXT NOT NULL,
    day        TEXT,                     -- the local day, in the configured time zone
    meal       TEXT,
    food_id    TEXT,
    logged_at  INTEGER
);
CREATE INDEX IF NOT EXISTS entries_version ON entries (version);
CREATE INDEX IF NOT EXISTS entries_day ON entries (day);
CREATE INDEX IF NOT EXISTS entries_food ON entries (food_id);

CREATE TABLE IF NOT EXISTS goals (
    id         TEXT PRIMARY KEY,
    version    INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted    INTEGER NOT NULL DEFAULT 0,
    data       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS health_days (
    id         TEXT PRIMARY KEY,
    version    INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted    INTEGER NOT NULL DEFAULT 0,
    data       TEXT NOT NULL,
    day        TEXT
);
CREATE INDEX IF NOT EXISTS health_days_version ON health_days (version);

-- A client food that duplicated an existing source_ref; writes to the alias go to the real food.
CREATE TABLE IF NOT EXISTS food_aliases (
    alias TEXT PRIMARY KEY,
    id    TEXT NOT NULL
);

-- USDA FoodData Central, per 100 g. Not synced.
CREATE TABLE IF NOT EXISTS catalog (
    fdc_id    INTEGER PRIMARY KEY,
    dataset   TEXT NOT NULL,             -- foundation, sr_legacy, survey
    name      TEXT NOT NULL,
    category  TEXT,
    nutrients TEXT NOT NULL,             -- JSON, per 100 g
    portions  TEXT NOT NULL              -- JSON [{label, grams}]
);
CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(
    name, category, content = 'catalog', content_rowid = 'fdc_id', tokenize = 'porter unicode61 remove_diacritics 2'
);

-- Open Food Facts lookups by barcode. A NULL food is a cached miss.
CREATE TABLE IF NOT EXISTS off_cache (
    barcode    TEXT PRIMARY KEY,
    fetched_at INTEGER NOT NULL,
    food       TEXT
);

-- App tokens, as SHA-256 hashes. A rotated-out token keeps working until expires_at.
CREATE TABLE IF NOT EXISTS tokens (
    hash       TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    expires_at TEXT
);
";

pub const SYNCED: &[&str] = &["foods", "entries", "goals", "health_days"];

pub fn path() -> PathBuf {
    crate::config::get().database.clone()
}

/// Where the database key comes from.
#[derive(Debug, PartialEq)]
pub enum KeySource {
    Credential(PathBuf),
    File(PathBuf),
    Plain,
}

impl KeySource {
    pub fn describe(&self) -> String {
        match self {
            KeySource::Credential(path) => format!("SQLCipher, key from the systemd credential {}", path.display()),
            KeySource::File(path) => format!("SQLCipher, key file {}", path.display()),
            KeySource::Plain => "plain SQLite (encryption = none)".to_string(),
        }
    }
}

/// Decides the key source from the config. `auto` takes the systemd credential when the service
/// has one, else the key file when it exists; FOOD_ALLOW_PLAINTEXT allows no key at all.
pub fn key_source(config: &Config, credentials_dir: Option<&Path>) -> Result<KeySource, String> {
    let credential = credentials_dir.map(|dir| dir.join(&config.credential));
    match config.encryption {
        Encryption::None => Ok(KeySource::Plain),
        Encryption::Credential => match credential {
            Some(path) if path.exists() => Ok(KeySource::Credential(path)),
            _ => Err(format!("encryption = systemd-credential, but there's no {:?} credential (LoadCredential= or \
                              LoadCredentialEncrypted= in the unit)", config.credential)),
        },
        Encryption::KeyFile if config.key_file.exists() => Ok(KeySource::File(config.key_file.clone())),
        Encryption::KeyFile => Err(format!("no key file at {}: run `food init`, or set key_file", config.key_file.display())),
        Encryption::Auto => {
            if let Some(path) = credential.filter(|p| p.exists()) {
                Ok(KeySource::Credential(path))
            } else if config.key_file.exists() {
                Ok(KeySource::File(config.key_file.clone()))
            } else if std::env::var_os("FOOD_ALLOW_PLAINTEXT").is_some() {
                Ok(KeySource::Plain)
            } else {
                Err(format!("no database key: run `food init` (which makes {}), or set encryption = none for plain SQLite",
                            config.key_file.display()))
            }
        }
    }
}

/// The key source for this process.
pub fn source() -> Result<KeySource, String> {
    let dir = std::env::var_os("CREDENTIALS_DIRECTORY").map(PathBuf::from);
    key_source(crate::config::get(), dir.as_deref())
}

/// Reads a key: 64 hex digits. A key file must be private to its owner.
pub fn read_key(source: &KeySource) -> Result<Option<String>, String> {
    let path = match source {
        KeySource::Plain => return Ok(None),
        KeySource::Credential(path) => path,
        KeySource::File(path) => {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(path).map_err(|e| format!("can't read the key file {}: {e}", path.display()))?.permissions().mode();
            if mode & 0o077 != 0 {
                return Err(format!("the key file {} can be read by other users (mode {:o}); run chmod 600 on it", path.display(), mode & 0o777));
            }
            path
        }
    };
    let text = std::fs::read_to_string(path).map_err(|e| format!("can't read the database key {}: {e}", path.display()))?;
    let key = text.trim().to_ascii_lowercase();
    if key.len() != 64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(format!("the database key in {} must be 64 hex digits", path.display()));
    }
    Ok(Some(key))
}

/// The 256-bit key as 64 hex digits, or None for a plain database.
pub fn key() -> Result<Option<String>, String> {
    read_key(&source()?)
}

pub fn open_with(path: &Path, key: Option<&str>, read_only: bool) -> Result<Connection, String> {
    let db = if read_only {
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
    } else {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent).map_err(|e| format!("can't create {}: {e}", parent.display()))?;
        }
        Connection::open(path)
    }
    .map_err(|e| format!("can't open {}: {e}", path.display()))?;
    if let Some(key) = key {
        // A raw key, so SQLCipher skips key derivation. It was checked to be hex.
        db.execute_batch(&format!("PRAGMA key = \"x'{key}'\";")).map_err(|e| e.to_string())?;
    }
    db.query_row("SELECT count(*) FROM sqlite_master", [], |row| row.get::<_, i64>(0))
        .map_err(|_| match key {
            Some(_) => format!("can't read {}: wrong key, a plain (unencrypted) database, or not a food database", path.display()),
            None => format!("can't read {}: it looks encrypted (or isn't a food database); set the key, or encryption", path.display()),
        })?;
    db.busy_timeout(Duration::from_secs(30)).map_err(|e| e.to_string())?;
    if !read_only {
        db.execute_batch(SCHEMA).map_err(|e| format!("schema: {e}"))?;
    }
    Ok(db)
}

pub fn open_read_only() -> Result<Connection, String> {
    open_with(&path(), key()?.as_deref(), true)
}

/// `food query` stops at this many rows, or at QUERY_MAX_BYTES of values, and says it was truncated.
pub const QUERY_MAX_ROWS: usize = 10_000;
const QUERY_MAX_BYTES: usize = 16 << 20;
/// A query still running after this is interrupted.
pub const QUERY_DEADLINE: Duration = Duration::from_secs(5);

/// Runs one read-only statement and returns its rows as JSON objects, and whether it was cut short.
pub fn run_query(db: &Connection, sql: &str) -> Result<(Vec<serde_json::Value>, bool), String> {
    run_query_within(db, sql, QUERY_DEADLINE)
}

pub fn run_query_within(db: &Connection, sql: &str, deadline: Duration) -> Result<(Vec<serde_json::Value>, bool), String> {
    // No single string or blob past the byte budget, so one value can't eat the memory either.
    db.set_limit(rusqlite::limits::Limit::SQLITE_LIMIT_LENGTH, QUERY_MAX_BYTES as i32);
    let mut statement = db.prepare(sql).map_err(|e| e.to_string())?;
    if !statement.readonly() {
        return Err("read-only: only SELECT works here".to_string());
    }
    let columns: Vec<String> = statement.column_names().iter().map(|c| c.to_string()).collect();
    // A watchdog interrupts the statement at the deadline; finishing first sends it home.
    let interrupt = db.get_interrupt_handle();
    let (finished, wait) = std::sync::mpsc::channel::<()>();
    let watchdog = std::thread::spawn(move || {
        if wait.recv_timeout(deadline) == Err(std::sync::mpsc::RecvTimeoutError::Timeout) {
            interrupt.interrupt();
        }
    });
    let result = (|| {
        let mut rows = statement.query([])?;
        let (mut out, mut bytes) = (Vec::new(), 0);
        while let Some(row) = rows.next()? {
            if out.len() == QUERY_MAX_ROWS || bytes > QUERY_MAX_BYTES {
                return Ok((out, true));
            }
            let mut object = serde_json::Map::new();
            for (i, column) in columns.iter().enumerate() {
                use rusqlite::types::ValueRef::*;
                let value = match row.get_ref(i)? {
                    Null | Blob(_) => serde_json::Value::Null,
                    Integer(n) => n.into(),
                    Real(n) => n.into(),
                    Text(t) => {
                        bytes += t.len();
                        String::from_utf8_lossy(t).into_owned().into()
                    }
                };
                bytes += column.len() + 16;
                object.insert(column.clone(), value);
            }
            out.push(serde_json::Value::Object(object));
        }
        Ok((out, false))
    })();
    drop(finished);
    let _ = watchdog.join();
    result.map_err(|e: rusqlite::Error| match e.sqlite_error_code() {
        Some(rusqlite::ErrorCode::OperationInterrupted) => {
            format!("the query ran past {} s and was stopped; add a LIMIT or narrow it", deadline.as_secs_f64())
        }
        _ => e.to_string(),
    })
}

pub fn meta_get(db: &Connection, key: &str) -> Option<String> {
    db.query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0)).ok()
}

pub fn meta_set(db: &Connection, key: &str, value: &str) -> Result<(), String> {
    db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)", params![key, value]).map(|_| ()).map_err(|e| e.to_string())
}

pub fn version(db: &Connection) -> i64 {
    meta_get(db, "version").and_then(|v| v.parse().ok()).unwrap_or(0)
}

/// Takes the next version number. Call inside the write's transaction.
pub fn next_version(db: &Connection) -> Result<i64, String> {
    let next = version(db) + 1;
    meta_set(db, "version", &next.to_string())?;
    Ok(next)
}

// MARK: The shared service state

/// One connection behind a mutex (one user, small writes), plus the version the long-poll waits on.
pub struct State {
    db: Mutex<Connection>,
    version: Mutex<i64>,
    changed: Condvar,
}

impl State {
    pub fn new(db: Connection) -> State {
        let version = version(&db);
        State { db: Mutex::new(db), version: Mutex::new(version), changed: Condvar::new() }
    }

    pub fn lock(&self) -> MutexGuard<'_, Connection> {
        self.db.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Runs `work` in a transaction and wakes long-polls if it wrote anything.
    pub fn write<T>(&self, work: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
        let mut db = self.lock();
        let tx = db.transaction().map_err(|e| e.to_string())?;
        let out = work(&tx)?;
        let now = version(&tx);
        tx.commit().map_err(|e| e.to_string())?;
        drop(db);
        let mut current = self.version.lock().unwrap_or_else(|p| p.into_inner());
        if now > *current {
            *current = now;
            self.changed.notify_all();
        }
        Ok(out)
    }

    /// Waits until the version passes `since`, or `timeout` runs out. Returns the current version.
    pub fn wait_past(&self, since: i64, timeout: Duration) -> i64 {
        let deadline = Instant::now() + timeout;
        let mut current = self.version.lock().unwrap_or_else(|p| p.into_inner());
        while *current <= since {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            current = self.changed.wait_timeout(current, left).unwrap_or_else(|p| p.into_inner()).0;
        }
        *current
    }
}

// MARK: Tokens

fn hash(token: &str) -> String {
    Sha256::digest(token.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

pub fn token_valid(db: &Connection, token: &str) -> bool {
    db.query_row("SELECT count(*) FROM tokens WHERE hash = ?1 AND (expires_at IS NULL OR expires_at > ?2)",
                 params![hash(token), crate::time::now_utc()], |row| row.get::<_, i64>(0))
        .is_ok_and(|n| n > 0)
}

/// Issues a new token. Current tokens stop working after `grace_hours`.
pub fn rotate_token(db: &Connection, grace_hours: i64) -> Result<(String, String), String> {
    let token = random_hex(32)?;
    let expires = crate::time::hours_from_now(grace_hours);
    db.execute("UPDATE tokens SET expires_at = ?1 WHERE expires_at IS NULL OR expires_at > ?1", [&expires]).map_err(|e| e.to_string())?;
    db.execute("INSERT OR IGNORE INTO tokens (hash, created_at) VALUES (?1, ?2)", params![hash(&token), crate::time::now_utc()])
        .map_err(|e| e.to_string())?;
    db.execute("DELETE FROM tokens WHERE expires_at IS NOT NULL AND expires_at < ?1", [crate::time::hours_from_now(-24 * 30)])
        .map_err(|e| e.to_string())?;
    Ok((token, expires))
}

pub fn random_hex(bytes: usize) -> Result<String, String> {
    let mut buffer = vec![0u8; bytes];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut buffer)).map_err(|e| e.to_string())?;
    Ok(buffer.iter().map(|b| format!("{b:02x}")).collect())
}

/// A random version-4 UUID, lowercase.
pub fn uuid() -> String {
    let hex = random_hex(16).unwrap_or_else(|_| format!("{:032x}", crate::time::now_ms() as u128 * 2654435761));
    let mut chars: Vec<char> = hex.chars().collect();
    chars[12] = '4';
    chars[16] = ['8', '9', 'a', 'b'][(chars[16].to_digit(16).unwrap_or(0) % 4) as usize];
    let s: String = chars.into_iter().collect();
    format!("{}-{}-{}-{}-{}", &s[0..8], &s[8..12], &s[12..16], &s[16..20], &s[20..32])
}

#[cfg(test)]
pub fn memory() -> Connection {
    open_with(Path::new(":memory:"), None, false).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    #[test]
    fn encrypted_database_needs_its_key() {
        let dir = std::env::temp_dir().join(format!("food-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("food.db");
        let db = open_with(&path, Some(KEY), false).unwrap();
        meta_set(&db, "k", "secret value").unwrap();
        drop(db);
        let raw = std::fs::read(&path).unwrap();
        assert!(!raw.starts_with(b"SQLite format 3"));
        assert!(!raw.windows(12).any(|w| w == b"secret value"));
        assert!(open_with(&path, None, true).is_err());
        let reopened = open_with(&path, Some(KEY), true).unwrap();
        assert_eq!(run_query(&reopened, "SELECT value FROM meta WHERE key = 'k'").unwrap().0[0]["value"], "secret value");
        assert!(run_query(&reopened, "DELETE FROM meta").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("food-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn config(dir: &Path, text: &str) -> Config {
        let text = format!("data_dir = {}\n{text}", dir.display());
        Config::resolve(Some((dir.join("config.toml"), text)), &|_| None).unwrap()
    }

    #[test]
    fn key_files_must_be_private_and_open_the_database() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("keyfile");
        let c = config(&dir, "encryption = keyfile");
        assert!(key_source(&c, None).unwrap_err().contains("food init"));
        crate::config::write_private(&c.key_file, &format!("{KEY}\n")).unwrap();
        let source = key_source(&c, None).unwrap();
        assert_eq!(source, KeySource::File(dir.join("food.key")));
        let key = read_key(&source).unwrap();
        assert_eq!(key.as_deref(), Some(KEY));
        let db = open_with(&c.database, key.as_deref(), false).unwrap();
        meta_set(&db, "k", "v").unwrap();
        drop(db);
        assert!(!std::fs::read(&c.database).unwrap().starts_with(b"SQLite format 3"));
        let error = open_with(&c.database, None, true).unwrap_err();
        assert!(error.contains("looks encrypted"), "{error}");
        std::fs::set_permissions(&c.key_file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_key(&source).unwrap_err().contains("chmod 600"));
        // auto picks the key file when it's there, and a systemd credential before it.
        let auto = config(&dir, "");
        assert_eq!(key_source(&auto, None).unwrap(), KeySource::File(dir.join("food.key")));
        let creds = dir.join("creds");
        std::fs::create_dir_all(&creds).unwrap();
        std::fs::write(creds.join("food-key"), KEY).unwrap();
        assert_eq!(key_source(&auto, Some(&creds)).unwrap(), KeySource::Credential(creds.join("food-key")));
        let named = config(&dir, "encryption = systemd-credential\ncredential = other-key");
        assert!(key_source(&named, Some(&creds)).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn plain_mode_writes_ordinary_sqlite() {
        let dir = temp("plain");
        let c = config(&dir, "encryption = none");
        assert_eq!(key_source(&c, None).unwrap(), KeySource::Plain);
        let db = open_with(&c.database, read_key(&KeySource::Plain).unwrap().as_deref(), false).unwrap();
        meta_set(&db, "k", "plain value").unwrap();
        drop(db);
        assert!(std::fs::read(&c.database).unwrap().starts_with(b"SQLite format 3"));
        // A key can't open a plain database: no silent mix-ups.
        assert!(open_with(&c.database, Some(KEY), true).unwrap_err().contains("wrong key"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn queries_are_capped_in_rows_and_time() {
        let db = memory();
        let endless = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c";
        let started = Instant::now();
        let (rows, truncated) = run_query(&db, endless).unwrap();
        assert_eq!((rows.len(), truncated), (QUERY_MAX_ROWS, true));
        assert_eq!(rows[QUERY_MAX_ROWS - 1]["x"], QUERY_MAX_ROWS as i64);
        assert!(started.elapsed() < Duration::from_secs(2));
        let (rows, truncated) = run_query(&db, "SELECT 1 AS one").unwrap();
        assert_eq!((rows.len(), truncated), (1, false));
        // An endless query with no rows to cut short is interrupted at the deadline.
        let started = Instant::now();
        let counting = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c";
        let error = run_query_within(&db, counting, Duration::from_millis(300)).unwrap_err();
        assert!(error.contains("stopped"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(3));
        // One giant value is refused, not built.
        assert!(run_query(&db, "SELECT length(randomblob(100000000)) AS big").is_err());
        // The connection still works after an interrupt.
        assert_eq!(run_query(&db, "SELECT 2 AS two").unwrap().0[0]["two"], 2);
    }

    #[test]
    fn tokens_rotate_with_grace() {
        let db = memory();
        let (first, _) = rotate_token(&db, 48).unwrap();
        let (second, _) = rotate_token(&db, 48).unwrap();
        assert!(token_valid(&db, &first) && token_valid(&db, &second) && !token_valid(&db, "nope"));
        let (third, _) = rotate_token(&db, 0).unwrap();
        assert!(!token_valid(&db, &first) && token_valid(&db, &third));
        assert_eq!(db.query_row("SELECT count(*) FROM tokens WHERE hash = ?1", [&third], |r| r.get::<_, i64>(0)).unwrap(), 0);
    }

    #[test]
    fn uuids_look_right() {
        let id = uuid();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert_ne!(uuid(), id);
    }

    #[test]
    fn fts5_is_available() {
        let db = memory();
        db.execute("INSERT INTO catalog (fdc_id, dataset, name, nutrients, portions) VALUES (1, 'sr_legacy', 'Bananas, raw', '{}', '[]')", []).unwrap();
        db.execute("INSERT INTO catalog_fts (catalog_fts) VALUES ('rebuild')", []).unwrap();
        let n: i64 = db.query_row("SELECT count(*) FROM catalog_fts WHERE catalog_fts MATCH 'banana'", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1);
    }
}
