//! Clocks and calendar days. Days, meals and "today" are in the configured time zone (the
//! `timezone` setting, else the system zone); see tz.rs.

use crate::tz::Zone;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// UTC timestamp `hours` from now, `2026-11-08T07:00:00Z`, so tokens compare as strings.
pub fn hours_from_now(hours: i64) -> String {
    let seconds = now_ms() / 1000 + hours * 3600;
    let (days, rest) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    format!("{}T{:02}:{:02}:{:02}Z", format_day(days), rest / 3600, rest % 3600 / 60, rest % 60)
}

pub fn now_utc() -> String {
    hours_from_now(0)
}

static ZONE: OnceLock<Zone> = OnceLock::new();

/// Sets the zone for this process. Call once, at startup, before anything asks for a day.
pub fn set_zone(zone: Zone) {
    let _ = ZONE.set(zone);
}

/// The configured zone, loaded on first use. A zone that can't be loaded falls back to UTC with a
/// warning; `food serve` checks the setting first, so this only happens to the CLI.
fn global() -> &'static Zone {
    ZONE.get_or_init(|| {
        if cfg!(test) {
            // Tests run in America/Chicago unless they say otherwise (with_zone).
            return Zone::posix("America/Chicago", "CST6CDT,M3.2.0,M11.1.0").unwrap();
        }
        let setting = crate::config::get().timezone.clone();
        crate::tz::load(setting.as_deref()).unwrap_or_else(|error| {
            eprintln!("food: {error}; using UTC (set timezone in the config)");
            Zone::utc()
        })
    })
}

#[cfg(test)]
thread_local! {
    static OVERRIDE: std::cell::RefCell<Option<Zone>> = const { std::cell::RefCell::new(None) };
}

/// Runs `work` with another zone on this thread (tests).
#[cfg(test)]
pub fn with_zone<T>(zone: Zone, work: impl FnOnce() -> T) -> T {
    let previous = OVERRIDE.with(|o| o.replace(Some(zone)));
    let out = work();
    OVERRIDE.with(|o| *o.borrow_mut() = previous);
    out
}

fn offset_seconds(ms: i64) -> i64 {
    #[cfg(test)]
    if let Some(offset) = OVERRIDE.with(|o| o.borrow().as_ref().map(|z| z.offset(ms.div_euclid(1000)))) {
        return i64::from(offset);
    }
    i64::from(global().offset(ms.div_euclid(1000)))
}

/// The zone's name, such as America/Chicago.
pub fn zone_name() -> String {
    #[cfg(test)]
    if let Some(name) = OVERRIDE.with(|o| o.borrow().as_ref().map(|z| z.name.clone())) {
        return name;
    }
    global().name.clone()
}

/// The zone's UTC offset at `ms`, in seconds east of UTC.
pub fn utc_offset(ms: i64) -> i64 {
    offset_seconds(ms)
}

/// Days since 1970-01-01 of the local calendar day at `ms`.
pub fn local_days(ms: i64) -> i64 {
    (ms.div_euclid(1000) + offset_seconds(ms)).div_euclid(86_400)
}

/// Minutes since local midnight at `ms`.
pub fn local_minutes(ms: i64) -> i64 {
    (ms.div_euclid(1000) + offset_seconds(ms)).rem_euclid(86_400) / 60
}

pub fn today() -> String {
    format_day(local_days(now_ms()))
}

pub fn day_of(ms: i64) -> String {
    format_day(local_days(ms))
}

pub fn format_day(days: i64) -> String {
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

/// `2026-11-08` to days since the epoch.
pub fn parse_day(text: &str) -> Option<i64> {
    let parts: Vec<i64> = text.trim().split('-').map(|p| p.parse().ok()).collect::<Option<_>>()?;
    if parts.len() != 3 || !(1..=12).contains(&parts[1]) || !(1..=31).contains(&parts[2]) || text.trim().len() != 10 {
        return None;
    }
    Some(days_from_civil(parts[0], parts[1], parts[2]))
}

/// A day relative to another: `add_days("2026-11-08", -1)` is `2026-11-07`.
pub fn add_days(day: &str, n: i64) -> Option<String> {
    parse_day(day).map(|d| format_day(d + n))
}

/// Accepts `2026-11-08`, `today`, `yesterday`, or `-N` (N days ago).
pub fn resolve_day(text: &str) -> Result<String, String> {
    let today = today();
    match text {
        "today" => Ok(today),
        "yesterday" => Ok(add_days(&today, -1).unwrap()),
        t if t.starts_with('-') && t[1..].parse::<i64>().is_ok() => Ok(add_days(&today, -t[1..].parse::<i64>().unwrap()).unwrap()),
        t => parse_day(t).map(format_day).ok_or_else(|| format!("bad date {t:?}: use YYYY-MM-DD, today, yesterday or -N")),
    }
}

/// The default meal for a local time: before 10:30 breakfast, before 15:00 lunch, before 21:00 dinner.
pub fn meal_at(ms: i64) -> &'static str {
    match local_minutes(ms) {
        m if m < 10 * 60 + 30 => "breakfast",
        m if m < 15 * 60 => "lunch",
        m if m < 21 * 60 => "dinner",
        _ => "snack",
    }
}

/// Whole years from a `YYYY-MM-DD` birth date to `today`.
pub fn age(dob: &str, today: &str) -> Option<i64> {
    let (b, t) = (dob.get(..10)?, today.get(..10)?);
    parse_day(b)?;
    let (by, bmd) = (b[..4].parse::<i64>().ok()?, &b[5..]);
    let (ty, tmd) = (t[..4].parse::<i64>().ok()?, &t[5..]);
    Some(ty - by - i64::from(tmd < bmd))
}

// Howard Hinnant's algorithms for the proleptic Gregorian calendar.
pub fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(y: i64, m: i64, d: i64, h: i64, min: i64) -> i64 {
        (days_from_civil(y, m, d) * 86_400 + h * 3600 + min * 60) * 1000
    }

    #[test]
    fn chicago_days_follow_daylight_time() {
        // 2026: DST from March 8 to November 1.
        assert_eq!(utc_offset(ms(2026, 7, 1, 12, 0)), -5 * 3600);
        assert_eq!(utc_offset(ms(2026, 1, 1, 12, 0)), -6 * 3600);
        assert_eq!(utc_offset(ms(2026, 3, 8, 7, 59)), -6 * 3600);
        assert_eq!(utc_offset(ms(2026, 3, 8, 8, 0)), -5 * 3600);
        assert_eq!(utc_offset(ms(2026, 11, 1, 6, 59)), -5 * 3600);
        assert_eq!(utc_offset(ms(2026, 11, 1, 7, 0)), -6 * 3600);
        // 03:00 UTC on Nov 8 is still Nov 7 in Chicago.
        assert_eq!(day_of(ms(2026, 11, 8, 3, 0)), "2026-11-07");
        assert_eq!(day_of(ms(2026, 11, 8, 6, 0)), "2026-11-08");
        assert_eq!(local_minutes(ms(2026, 11, 8, 14, 30)), 8 * 60 + 30);
    }

    #[test]
    fn other_zones_move_days_and_meals() {
        let kolkata = Zone::posix("Asia/Kolkata", "IST-5:30").unwrap();
        with_zone(kolkata, || {
            assert_eq!(zone_name(), "Asia/Kolkata");
            // 20:00 UTC on Nov 8 is 01:30 on Nov 9 in India, and 14:00 on Nov 8 in Chicago.
            assert_eq!(day_of(ms(2026, 11, 8, 20, 0)), "2026-11-09");
            assert_eq!(local_minutes(ms(2026, 11, 8, 20, 0)), 90);
            assert_eq!(meal_at(ms(2026, 11, 8, 20, 0)), "breakfast");
            assert_eq!(meal_at(ms(2026, 11, 8, 8, 0)), "lunch"); // 13:30
            assert_eq!(meal_at(ms(2026, 11, 8, 13, 0)), "dinner"); // 18:30
            assert_eq!(today(), day_of(now_ms()));
        });
        let sydney = Zone::posix("Australia/Sydney", "AEST-10AEDT,M10.1.0,M4.1.0/3").unwrap();
        with_zone(sydney, || {
            // 13:30 UTC on Dec 31 is 00:30 on Jan 1 in Sydney (daylight time, UTC+11).
            assert_eq!(day_of(ms(2026, 12, 31, 13, 30)), "2027-01-01");
            assert_eq!(day_of(ms(2026, 12, 31, 12, 30)), "2026-12-31");
        });
        // Back to Chicago outside.
        assert_eq!(day_of(ms(2026, 11, 8, 20, 0)), "2026-11-08");
        assert_eq!(zone_name(), "America/Chicago");
    }

    #[test]
    fn meals_and_days() {
        assert_eq!(meal_at(ms(2026, 11, 8, 14, 0)), "breakfast"); // 08:00 CST
        assert_eq!(meal_at(ms(2026, 11, 8, 18, 0)), "lunch");
        assert_eq!(meal_at(ms(2026, 11, 9, 1, 0)), "dinner"); // 19:00 CST
        assert_eq!(meal_at(ms(2026, 11, 9, 4, 0)), "snack");
        assert_eq!(add_days("2026-03-01", -1).unwrap(), "2026-02-28");
        assert_eq!(parse_day("2026-13-01"), None);
        assert_eq!(age("2004-07-07", "2026-11-08"), Some(22));
        assert_eq!(age("2004-11-09", "2026-11-08"), Some(21));
    }
}
