//! Plate: a self-hosted food log in an encrypted SQLite database.
//!
//! `food serve` is the service: it syncs with the iPhone app over HTTP and answers the CLI on a
//! Unix socket. Every other subcommand is a client of that socket, so the database and its key
//! never leave the service. `seed-usda` and `health refresh` do their downloading and Health
//! reading as the caller, then hand the results to the service. Settings: config.rs.

mod backup;
mod catalog;
mod cli;
mod config;
mod db;
mod goals;
mod healthimport;
mod healthpull;
mod help;
mod http;
mod nutrients;
mod off;
mod service;
mod socket;
mod store;
mod time;
mod tz;
mod usda;

use std::process::ExitCode;
use std::sync::Arc;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("serve") if !cli::wants_help(&args) => serve(),
        _ => {
            // `food --help | head` should end quietly, not panic on the closed pipe. Only the
            // CLI: the service must survive a client that hangs up.
            unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
            if !cli::wants_help(&args) && args.first().map(String::as_str) != Some("init") {
                if let Err(error) = config::load() {
                    eprintln!("food: {error}");
                    return ExitCode::FAILURE;
                }
            }
            cli::run(&args)
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("food: {error}");
            ExitCode::FAILURE
        }
    }
}

fn serve() -> Result<(), String> {
    let config = config::load()?;
    // A configured zone that doesn't load is an error here, not a silent UTC.
    let zone = match &config.timezone {
        Some(name) => tz::load(Some(name))?,
        None => tz::system().unwrap_or_else(|error| {
            eprintln!("{error}; using UTC (set timezone in the config)");
            tz::Zone::utc()
        }),
    };
    let zone_name = zone.name.clone();
    time::set_zone(zone);
    let source = db::source()?;
    let db = db::open_with(&config.database, db::read_key(&source)?.as_deref(), false)?;
    if store::get(&db, "goals", "current")?.is_none() {
        store::put(&db, "goals", &goals::default_row())?;
    }
    let state = Arc::new(db::State::new(db));
    socket::spawn(state.clone())?;
    eprintln!("database {} ({})", config.database.display(), source.describe());
    eprintln!("socket {}, time zone {zone_name}", config.socket.display());
    if let Some(file) = &config.file {
        eprintln!("config {}", file.display());
    }
    http::serve(state)
}
