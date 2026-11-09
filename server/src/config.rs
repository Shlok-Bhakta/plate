//! Configuration: a small `key = value` file plus FOOD_* environment variables, which win over it.
//! The file is the first that exists of $FOOD_CONFIG, $XDG_CONFIG_HOME/plate/config.toml,
//! ~/.config/plate/config.toml and /etc/plate/config.toml. Everything has a default, so no file
//! is needed at all. `food init` writes one; `food config` shows the effective values.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Every key: (name, environment variable, what it is).
pub const KEYS: &[(&str, &str, &str)] = &[
    ("data_dir", "FOOD_DATA_DIR", "where the database and key file live"),
    ("database", "FOOD_DB", "the database file (default <data_dir>/food.db)"),
    ("listen", "FOOD_LISTEN", "the app's HTTP address (default 127.0.0.1:18792)"),
    ("socket", "FOOD_SOCKET", "the CLI's Unix socket"),
    ("socket_uids", "FOOD_SOCKET_UIDS", "other local users (uids or names) the socket answers"),
    ("timezone", "FOOD_TIMEZONE", "IANA zone for days and meals (default the system zone)"),
    ("encryption", "FOOD_ENCRYPTION", "keyfile, systemd-credential, none, or auto (default)"),
    ("key_file", "FOOD_KEY_FILE", "the SQLCipher key file (default <data_dir>/food.key)"),
    ("credential", "FOOD_CREDENTIAL", "the systemd credential holding the key (default food-key)"),
    ("cache_dir", "FOOD_CACHE_DIR", "downloads for `food seed-usda` (default ~/.cache/plate)"),
    ("off_contact", "FOOD_OFF_CONTACT", "a contact (email or URL) for the Open Food Facts User-Agent"),
    ("health_command", "FOOD_HEALTH_COMMAND", "the `health` CLI that `food health refresh` runs"),
    ("health_owner", "FOOD_HEALTH_OWNER", "whose devices count in `food health refresh` (a first name)"),
];

pub const DEFAULT_LISTEN: &str = "127.0.0.1:18792";

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Encryption {
    /// The systemd credential if present, else the key file if present.
    Auto,
    KeyFile,
    Credential,
    None,
}

impl Encryption {
    fn parse(text: &str) -> Result<Encryption, String> {
        Ok(match text.to_ascii_lowercase().replace('_', "-").as_str() {
            "auto" | "" => Encryption::Auto,
            "keyfile" | "key-file" | "file" => Encryption::KeyFile,
            "systemd-credential" | "credential" | "systemd" => Encryption::Credential,
            "none" | "off" | "plain" | "plaintext" => Encryption::None,
            other => return Err(format!("encryption must be keyfile, systemd-credential, none or auto, not {other:?}")),
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Encryption::Auto => "auto",
            Encryption::KeyFile => "keyfile",
            Encryption::Credential => "systemd-credential",
            Encryption::None => "none",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    /// The file that was read, if any.
    pub file: Option<PathBuf>,
    pub data_dir: PathBuf,
    pub database: PathBuf,
    pub listen: String,
    pub socket: PathBuf,
    /// Besides the service's own uid and root, which are always answered.
    pub socket_uids: Vec<u32>,
    pub timezone: Option<String>,
    pub encryption: Encryption,
    pub key_file: PathBuf,
    pub credential: String,
    pub cache_dir: PathBuf,
    pub off_contact: Option<String>,
    pub health_command: Option<String>,
    pub health_owner: Option<String>,
}

/// `key = value` lines. `#` starts a comment (outside quotes); values may be quoted.
pub fn parse(text: &str, origin: &str) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    for (n, raw) in text.lines().enumerate() {
        let line = strip_comment(raw).trim().to_string();
        if line.is_empty() || (line.starts_with('[') && line.ends_with(']')) {
            continue;
        }
        let (key, value) = line.split_once('=').ok_or_else(|| format!("{origin} line {}: expected key = value", n + 1))?;
        let key = key.trim().to_string();
        if !KEYS.iter().any(|(k, _, _)| *k == key) {
            let known: Vec<&str> = KEYS.iter().map(|(k, _, _)| *k).collect();
            return Err(format!("{origin} line {}: unknown key {key:?}; known keys: {}", n + 1, known.join(", ")));
        }
        let value = value.trim();
        let value = match value.as_bytes() {
            [b'"', .., b'"'] | [b'\'', .., b'\''] if value.len() >= 2 => value[1..value.len() - 1].to_string(),
            _ => value.to_string(),
        };
        out.push((key, value));
    }
    Ok(out)
}

fn strip_comment(line: &str) -> &str {
    let mut quote = None;
    for (i, c) in line.char_indices() {
        match (c, quote) {
            ('"' | '\'', None) => quote = Some(c),
            (q, Some(open)) if q == open => quote = None,
            ('#', None) => return &line[..i],
            _ => {}
        }
    }
    line
}

type Env<'a> = &'a dyn Fn(&str) -> Option<String>;

fn home(env: Env) -> PathBuf {
    env("HOME").filter(|h| !h.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

fn xdg(env: Env, var: &str, fallback: &str) -> PathBuf {
    env(var).filter(|d| d.starts_with('/')).map(PathBuf::from).unwrap_or_else(|| home(env).join(fallback))
}

/// Where `food init` writes the config, and the first place looked for one.
pub fn user_config_path(env: Env) -> PathBuf {
    match env("FOOD_CONFIG").filter(|p| !p.is_empty()) {
        Some(path) => PathBuf::from(path),
        None => xdg(env, "XDG_CONFIG_HOME", ".config").join("plate/config.toml"),
    }
}

/// The places a config file is looked for, in order.
pub fn candidates(env: Env) -> Vec<PathBuf> {
    if env("FOOD_CONFIG").is_some_and(|p| !p.is_empty()) {
        return vec![user_config_path(env)];
    }
    let mut list = vec![user_config_path(env), home(env).join(".config/plate/config.toml"), PathBuf::from("/etc/plate/config.toml")];
    list.dedup();
    list
}

fn expand(value: &str, env: Env, key: &str) -> Result<PathBuf, String> {
    let path = match value.strip_prefix("~/") {
        Some(rest) => home(env).join(rest),
        None if value == "~" => home(env),
        None => PathBuf::from(value),
    };
    if !path.is_absolute() {
        return Err(format!("{key} must be an absolute path (or start with ~/), not {value:?}"));
    }
    Ok(path)
}

fn uid_of(text: &str) -> Result<u32, String> {
    if let Ok(uid) = text.parse::<u32>() {
        return Ok(uid);
    }
    let name = std::ffi::CString::new(text).map_err(|_| format!("bad user name {text:?}"))?;
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    if entry.is_null() {
        return Err(format!("socket_uids: no user {text:?}"));
    }
    Ok(unsafe { (*entry).pw_uid })
}

fn default_socket(env: Env, data_dir: &Path) -> PathBuf {
    if cfg!(target_os = "linux") {
        let uid = unsafe { libc::getuid() };
        let runtime = env("XDG_RUNTIME_DIR")
            .filter(|d| d.starts_with('/'))
            .map(PathBuf::from)
            .or_else(|| Some(PathBuf::from(format!("/run/user/{uid}"))).filter(|p| p.is_dir()));
        if let Some(dir) = runtime {
            return dir.join("plate/food.sock");
        }
    }
    data_dir.join("food.sock")
}

impl Config {
    /// The settings from a file (path and text) and the environment, which wins.
    pub fn resolve(file: Option<(PathBuf, String)>, env: Env) -> Result<Config, String> {
        let pairs = match &file {
            Some((path, text)) => parse(text, &path.display().to_string())?,
            None => Vec::new(),
        };
        let setting = |key: &str| -> Option<String> {
            let var = KEYS.iter().find(|(k, _, _)| *k == key).map(|(_, v, _)| *v).unwrap_or("");
            env(var).or_else(|| pairs.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v.clone())).filter(|v| !v.trim().is_empty())
        };
        let path_setting = |key: &str| setting(key).map(|v| expand(v.trim(), env, key)).transpose();
        let database = path_setting("database")?;
        let data_dir = match path_setting("data_dir")? {
            Some(dir) => dir,
            // An older setup gave only the database path.
            None => match database.as_ref().and_then(|db| db.parent()).filter(|p| !p.as_os_str().is_empty()) {
                Some(parent) => parent.to_path_buf(),
                None => xdg(env, "XDG_DATA_HOME", ".local/share").join("plate"),
            },
        };
        let mut socket_uids = Vec::new();
        for list in [setting("socket_uids"), env("FOOD_READER_UID")].into_iter().flatten() {
            for item in list.split([',', ' ']).map(str::trim).filter(|s| !s.is_empty()) {
                socket_uids.push(uid_of(item)?);
            }
        }
        let text = |key: &str| setting(key).map(|v| v.trim().to_string());
        Ok(Config {
            file: file.map(|(path, _)| path),
            database: database.unwrap_or_else(|| data_dir.join("food.db")),
            key_file: path_setting("key_file")?.unwrap_or_else(|| data_dir.join("food.key")),
            socket: path_setting("socket")?.unwrap_or_else(|| default_socket(env, &data_dir)),
            cache_dir: path_setting("cache_dir")?.unwrap_or_else(|| xdg(env, "XDG_CACHE_HOME", ".cache").join("plate")),
            listen: text("listen").unwrap_or_else(|| DEFAULT_LISTEN.to_string()),
            socket_uids,
            timezone: text("timezone"),
            encryption: Encryption::parse(&text("encryption").unwrap_or_default())?,
            credential: text("credential").unwrap_or_else(|| "food-key".to_string()),
            off_contact: text("off_contact"),
            health_command: text("health_command"),
            health_owner: text("health_owner"),
            data_dir,
        })
    }

    /// Reads the first config file that exists, then applies the environment.
    pub fn from_env(env: Env) -> Result<Config, String> {
        for path in candidates(env) {
            match std::fs::read_to_string(&path) {
                Ok(text) => return Config::resolve(Some((path, text)), env),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                // Unreadable, as /etc/plate/config.toml may be from a sandbox: skip it.
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {}
                Err(e) => return Err(format!("can't read {}: {e}", path.display())),
            }
        }
        if let Some(path) = env("FOOD_CONFIG").filter(|p| !p.is_empty()) {
            return Err(format!("FOOD_CONFIG is {path}, which doesn't exist"));
        }
        Config::resolve(None, env)
    }

    /// The User-Agent for Open Food Facts and USDA downloads.
    pub fn user_agent(&self) -> String {
        match &self.off_contact {
            Some(contact) => format!("Plate/1.0 (self-hosted; {contact})"),
            None => "Plate/1.0 (Plate self-hosted)".to_string(),
        }
    }
}

fn real_env(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

static CONFIG: OnceLock<Config> = OnceLock::new();

/// Loads the configuration once. Errors (a bad file, an unknown key) are returned.
pub fn load() -> Result<&'static Config, String> {
    if let Some(config) = CONFIG.get() {
        return Ok(config);
    }
    let config = Config::from_env(&real_env)?;
    Ok(CONFIG.get_or_init(|| config))
}

/// The loaded configuration. `main` loads it first; tests get the defaults, without any file.
pub fn get() -> &'static Config {
    CONFIG.get_or_init(|| {
        if cfg!(test) {
            return Config::resolve(None, &|_| None).expect("defaults");
        }
        Config::from_env(&real_env).unwrap_or_else(|error| {
            eprintln!("food: {error}; using the defaults");
            Config::resolve(None, &real_env).or_else(|_| Config::resolve(None, &|_| None)).expect("defaults")
        })
    })
}

// MARK: food init

pub struct InitOptions {
    pub data_dir: Option<String>,
    pub listen: Option<String>,
    pub timezone: Option<String>,
    pub encryption: Option<String>,
    pub force: bool,
}

fn private_dir(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::DirBuilderExt;
    if path.is_dir() {
        return Ok(());
    }
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path).map_err(|e| format!("can't create {}: {e}", path.display()))
}

/// Writes `text` to a new file only the owner can read.
pub fn write_private(path: &Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("can't create {}: {e}", path.display()))?;
    file.write_all(text.as_bytes()).map_err(|e| format!("can't write {}: {e}", path.display()))
}

/// The config file `food init` writes.
fn template(data_dir: &Path, listen: &str, timezone: Option<&str>, encryption: Encryption) -> String {
    let zone = match timezone {
        Some(z) => format!("timezone = {z}\n"),
        None => "# timezone = America/Chicago       # default: the system time zone\n".to_string(),
    };
    let key = match encryption {
        Encryption::None => "# key_file = ...                    # not used: the database is plain SQLite\n".to_string(),
        _ => format!("key_file = {}\n", data_dir.join("food.key").display()),
    };
    format!(
        "# Plate server settings. `food config` shows the effective values. Each key can also be
# set with an environment variable, which wins: FOOD_DATA_DIR, FOOD_LISTEN, FOOD_TIMEZONE, ...

data_dir = {data}
listen = {listen}                # keep it on 127.0.0.1; see the README to reach it from a phone
encryption = {encryption}
{key}{zone}
# socket = /run/user/1000/plate/food.sock   # default: $XDG_RUNTIME_DIR/plate, else data_dir
# socket_uids = 1001, alice                 # other local users the CLI socket answers
# off_contact = you@example.com             # sent to Open Food Facts in the User-Agent
# cache_dir = ~/.cache/plate                # USDA downloads for `food seed-usda`
# health_command = health                   # for `food health refresh`
",
        data = data_dir.display(),
        encryption = encryption.name(),
    )
}

pub fn init(options: &InitOptions, env: Env) -> Result<String, String> {
    let path = user_config_path(env);
    let mut report = Vec::new();
    if let Some(zone) = &options.timezone {
        crate::tz::load(Some(zone))?;
    }
    let keep = path.exists() && !options.force;
    if keep {
        report.push(format!("kept the existing config {} (--force replaces it)", path.display()));
    } else {
        let encryption = match &options.encryption {
            Some(e) => match Encryption::parse(e)? {
                Encryption::Auto => Encryption::KeyFile,
                e => e,
            },
            None => Encryption::KeyFile,
        };
        let data_dir = match &options.data_dir {
            Some(dir) => expand(dir, env, "--data-dir")?,
            None => Config::resolve(None, env)?.data_dir,
        };
        let listen = options.listen.clone().unwrap_or_else(|| DEFAULT_LISTEN.to_string());
        if let Some(parent) = path.parent() {
            private_dir(parent)?;
        }
        if path.exists() {
            std::fs::remove_file(&path).map_err(|e| format!("can't replace {}: {e}", path.display()))?;
        }
        write_private(&path, &template(&data_dir, &listen, options.timezone.as_deref(), encryption))?;
        report.push(format!("wrote {}", path.display()));
    }
    let text = std::fs::read_to_string(&path).map_err(|e| format!("can't read {}: {e}", path.display()))?;
    let config = Config::resolve(Some((path.clone(), text)), env)?;
    private_dir(&config.data_dir)?;
    match config.encryption {
        Encryption::KeyFile | Encryption::Auto if !config.key_file.exists() => {
            if config.database.exists() {
                return Err(format!(
                    "{} exists but its key {} doesn't; restore the key, or move the database away first",
                    config.database.display(),
                    config.key_file.display()
                ));
            }
            if let Some(parent) = config.key_file.parent() {
                private_dir(parent)?;
            }
            write_private(&config.key_file, &(crate::db::random_hex(32)? + "\n"))?;
            report.push(format!("created the database key {} (mode 600). Back it up: without it the database can't be read.", config.key_file.display()));
        }
        Encryption::KeyFile | Encryption::Auto => report.push(format!("kept the database key {}", config.key_file.display())),
        Encryption::Credential => report.push(format!("the key comes from the systemd credential {:?}", config.credential)),
        Encryption::None => report.push("encryption = none: the database is plain SQLite".to_string()),
    }
    report.push(format!("data in {}", config.data_dir.display()));
    Ok(format!(
        "{}

Next
  1. Start the server:      food serve
     (or keep it running with deploy/plate.service or deploy/plate.plist; see the README)
  2. Make an app token:     food token new
  3. Load the USDA foods:   food seed-usda     (a one-time download into {cache})
  4. Reach it from the phone over HTTPS, never plain HTTP on the internet. With Tailscale:
       tailscale serve --bg --https=8445 http://{listen}
     then give the app https://<this machine>.<tailnet>.ts.net:8445 and the token.
  `food config` shows every setting; `food --help` lists the commands.
",
        report.iter().map(|line| format!("  {line}")).collect::<Vec<_>>().join("\n"),
        cache = config.cache_dir.display(),
        listen = config.listen,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |name: &str| map.get(name).cloned()
    }

    #[test]
    fn files_parse_with_comments_and_quotes() {
        let text = "# Plate\n[server]\ndata_dir = \"/srv/plate\"   # where\nlisten=0.0.0.0:9000\noff_contact = 'me#1@example.com'\n\n";
        let pairs = parse(text, "test").unwrap();
        assert_eq!(pairs, vec![
            ("data_dir".to_string(), "/srv/plate".to_string()),
            ("listen".to_string(), "0.0.0.0:9000".to_string()),
            ("off_contact".to_string(), "me#1@example.com".to_string()),
        ]);
        let error = parse("data_dir = /x\nlisten_port = 1\n", "c.toml").unwrap_err();
        assert!(error.contains("c.toml line 2") && error.contains("listen_port"), "{error}");
        assert!(parse("just words\n", "c").is_err());
    }

    #[test]
    fn defaults_follow_home_and_xdg() {
        let c = Config::resolve(None, &env(&[("HOME", "/home/ann"), ("XDG_RUNTIME_DIR", "/run/user/1001")])).unwrap();
        assert_eq!(c.data_dir, PathBuf::from("/home/ann/.local/share/plate"));
        assert_eq!(c.database, PathBuf::from("/home/ann/.local/share/plate/food.db"));
        assert_eq!(c.key_file, PathBuf::from("/home/ann/.local/share/plate/food.key"));
        assert_eq!(c.cache_dir, PathBuf::from("/home/ann/.cache/plate"));
        assert_eq!(c.listen, "127.0.0.1:18792");
        assert_eq!(c.encryption, Encryption::Auto);
        assert_eq!(c.credential, "food-key");
        assert!(c.socket_uids.is_empty() && c.timezone.is_none() && c.off_contact.is_none());
        if cfg!(target_os = "linux") {
            assert_eq!(c.socket, PathBuf::from("/run/user/1001/plate/food.sock"));
        }
        assert_eq!(c.user_agent(), "Plate/1.0 (Plate self-hosted)");
        let x = Config::resolve(None, &env(&[("HOME", "/home/ann"), ("XDG_DATA_HOME", "/data"), ("XDG_CACHE_HOME", "/cache")])).unwrap();
        assert_eq!((x.data_dir, x.cache_dir), (PathBuf::from("/data/plate"), PathBuf::from("/cache/plate")));
        assert_eq!(user_config_path(&env(&[("HOME", "/home/ann")])), PathBuf::from("/home/ann/.config/plate/config.toml"));
        assert_eq!(candidates(&env(&[("HOME", "/h")])).last().unwrap(), &PathBuf::from("/etc/plate/config.toml"));
    }

    #[test]
    fn the_environment_wins_over_the_file() {
        let file = "data_dir = ~/plate\nlisten = 127.0.0.1:9000\ntimezone = Asia/Tokyo\nencryption = none\nsocket_uids = 1002, 0\noff_contact = a@b.c\n";
        let c = Config::resolve(Some((PathBuf::from("/c"), file.into())),
                                &env(&[("HOME", "/home/ann"), ("FOOD_LISTEN", "127.0.0.1:9001"), ("FOOD_READER_UID", "1000")])).unwrap();
        assert_eq!(c.data_dir, PathBuf::from("/home/ann/plate"));
        assert_eq!(c.database, PathBuf::from("/home/ann/plate/food.db"));
        assert_eq!(c.listen, "127.0.0.1:9001");
        assert_eq!(c.timezone.as_deref(), Some("Asia/Tokyo"));
        assert_eq!(c.encryption, Encryption::None);
        assert_eq!(c.socket_uids, vec![1002, 0, 1000]);
        if !cfg!(target_os = "linux") {
            assert_eq!(c.socket, PathBuf::from("/home/ann/plate/food.sock"));
        }
        assert_eq!(c.user_agent(), "Plate/1.0 (self-hosted; a@b.c)");
        assert!(Config::resolve(Some((PathBuf::from("/c"), "data_dir = relative/dir".into())), &env(&[])).is_err());
        assert!(Config::resolve(Some((PathBuf::from("/c"), "encryption = rot13".into())), &env(&[])).is_err());
    }

    #[test]
    fn a_hardened_unit_keeps_working_from_its_environment_alone() {
        // The variables a dedicated-user systemd unit sets, and no config file.
        let c = Config::resolve(None, &env(&[
            ("HOME", "/nonexistent"),
            ("FOOD_DB", "/srv/secure/food/food.db"),
            ("FOOD_SOCKET", "/run/personal-food/food.sock"),
            ("FOOD_LISTEN", "127.0.0.1:18792"),
            ("FOOD_READER_UID", "1000"),
        ])).unwrap();
        assert_eq!(c.database, PathBuf::from("/srv/secure/food/food.db"));
        assert_eq!(c.data_dir, PathBuf::from("/srv/secure/food"));
        assert_eq!(c.socket, PathBuf::from("/run/personal-food/food.sock"));
        assert_eq!(c.socket_uids, vec![1000]);
        assert_eq!(c.encryption, Encryption::Auto);
    }

    #[test]
    fn init_writes_a_config_and_a_private_key() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("food-init-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let e = env(&[("HOME", home.to_str().unwrap())]);
        let options = InitOptions { data_dir: None, listen: Some("127.0.0.1:18799".into()), timezone: Some("UTC".into()), encryption: None, force: false };
        let report = init(&options, &e).unwrap();
        assert!(report.contains("food token new"), "{report}");
        let config = Config::from_env(&e).unwrap();
        assert_eq!(config.file.as_deref(), Some(home.join(".config/plate/config.toml").as_path()));
        assert_eq!((config.listen.as_str(), config.encryption, config.timezone.as_deref()), ("127.0.0.1:18799", Encryption::KeyFile, Some("UTC")));
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&config.key_file), 0o600);
        assert_eq!(mode(&config.data_dir), 0o700);
        assert_eq!(mode(config.file.as_ref().unwrap()), 0o600);
        let key = std::fs::read_to_string(&config.key_file).unwrap();
        assert_eq!(key.trim().len(), 64);
        // Running it again keeps the key and the file.
        assert!(init(&options, &e).unwrap().contains("kept the existing config"));
        assert_eq!(std::fs::read_to_string(&config.key_file).unwrap(), key);
        // A plain setup writes no key.
        let plain = home.join("plain");
        let e2 = env(&[("HOME", plain.to_str().unwrap())]);
        init(&InitOptions { data_dir: None, listen: None, timezone: None, encryption: Some("none".into()), force: false }, &e2).unwrap();
        let config = Config::from_env(&e2).unwrap();
        assert_eq!(config.encryption, Encryption::None);
        assert!(!config.key_file.exists());
        assert!(init(&InitOptions { data_dir: None, listen: None, timezone: Some("Mars/Base".into()), encryption: None, force: true }, &e2).is_err());
        let _ = std::fs::remove_dir_all(&home);
    }
}
