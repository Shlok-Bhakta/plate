//! Time zones without a dependency: IANA zones from the system's zoneinfo files (TZif, RFC 8536,
//! with the POSIX TZ rule in the footer for times past the last transition), POSIX TZ strings such
//! as `CST6CDT,M3.2.0,M11.1.0`, and UTC. The system zone comes from $TZ or /etc/localtime.

use crate::time::{civil_from_days, days_from_civil};

/// A zone: transitions (UTC seconds, the offset east of UTC in seconds from then on), the offset
/// before the first one, and the rule for times after the last one.
#[derive(Clone, Debug)]
pub struct Zone {
    pub name: String,
    times: Vec<i64>,
    offsets: Vec<i32>,
    initial: i32,
    rule: Option<Rule>,
}

#[derive(Clone, Debug, PartialEq)]
struct Rule {
    std: i32,
    dst: Option<Dst>,
}

#[derive(Clone, Debug, PartialEq)]
struct Dst {
    offset: i32,
    start: (Date, i32),
    end: (Date, i32),
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Date {
    /// Mm.w.d: day d (0 = Sunday) of week w (5 = the last) of month m.
    Month(i64, i64, i64),
    /// Jn: day n from 1 to 365, never counting February 29.
    Julian(i64),
    /// n: day n from 0 to 365, counting February 29.
    Ordinal(i64),
}

impl Zone {
    pub fn utc() -> Zone {
        Zone { name: "UTC".into(), times: vec![], offsets: vec![], initial: 0, rule: None }
    }

    /// The offset east of UTC, in seconds, at a UTC instant in seconds.
    pub fn offset(&self, utc: i64) -> i32 {
        if let Some(&last) = self.times.last() {
            if utc < last || self.rule.is_none() {
                let i = self.times.partition_point(|t| *t <= utc);
                return if i == 0 { self.initial } else { self.offsets[i - 1] };
            }
        }
        match &self.rule {
            Some(rule) => rule.offset(utc),
            None => self.initial,
        }
    }

    /// A POSIX TZ string, such as `CST6CDT,M3.2.0,M11.1.0` or `<+0530>-5:30`.
    pub fn posix(name: &str, text: &str) -> Option<Zone> {
        let rule = parse_rule(text)?;
        Some(Zone { name: name.to_string(), times: vec![], offsets: vec![], initial: rule.std, rule: Some(rule) })
    }

    /// A TZif file's contents.
    pub fn tzif(name: &str, bytes: &[u8]) -> Result<Zone, String> {
        parse_tzif(bytes).map(|(times, offsets, initial, footer)| Zone {
            name: name.to_string(),
            times,
            offsets,
            initial,
            rule: footer.as_deref().and_then(parse_rule),
        })
    }
}

const ZONEINFO: &[&str] = &["/usr/share/zoneinfo", "/var/db/timezone/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo"];

fn zoneinfo_dirs() -> Vec<String> {
    let mut dirs: Vec<String> = std::env::var("TZDIR").ok().filter(|d| !d.is_empty()).into_iter().collect();
    dirs.extend(ZONEINFO.iter().map(|d| d.to_string()));
    dirs
}

/// A zone by name: `UTC`, an IANA name such as `Asia/Kolkata`, a TZif file path, or a POSIX TZ
/// string. None (or empty) is the system zone.
pub fn load(name: Option<&str>) -> Result<Zone, String> {
    let Some(name) = name.map(str::trim).filter(|n| !n.is_empty()) else { return system() };
    let name = name.strip_prefix(':').unwrap_or(name);
    if matches!(name, "UTC" | "utc" | "Z" | "Etc/UTC" | "Etc/UCT" | "UCT" | "Universal" | "Zulu") {
        return Ok(Zone::utc());
    }
    if name.starts_with('/') {
        let bytes = std::fs::read(name).map_err(|e| format!("can't read the time zone file {name}: {e}"))?;
        return Zone::tzif(name.rsplit("zoneinfo/").next().unwrap_or(name), &bytes);
    }
    let safe = !name.contains("..") && name.chars().all(|c| c.is_ascii_alphanumeric() || "/_+-".contains(c));
    if safe {
        for dir in zoneinfo_dirs() {
            if let Ok(bytes) = std::fs::read(format!("{dir}/{name}")) {
                return Zone::tzif(name, &bytes).map_err(|e| format!("time zone {name}: {e}"));
            }
        }
    }
    Zone::posix(name, name).ok_or_else(|| {
        format!("unknown time zone {name:?}: use an IANA name such as America/Chicago or Europe/Berlin (the system's zoneinfo files are needed), UTC, or a POSIX TZ string")
    })
}

/// The system zone: $TZ, else /etc/localtime, else /etc/timezone, else UTC.
pub fn system() -> Result<Zone, String> {
    if let Ok(tz) = std::env::var("TZ") {
        let tz = tz.trim().trim_start_matches(':');
        if tz.is_empty() {
            return Ok(Zone::utc());
        }
        if let Ok(zone) = load(Some(tz)) {
            return Ok(zone);
        }
    }
    if let Ok(bytes) = std::fs::read("/etc/localtime") {
        let name = std::fs::read_link("/etc/localtime")
            .ok()
            .and_then(|target| target.to_string_lossy().split("zoneinfo/").nth(1).map(str::to_string))
            .unwrap_or_else(|| "localtime".to_string());
        if let Ok(zone) = Zone::tzif(&name, &bytes) {
            return Ok(zone);
        }
    }
    if let Ok(text) = std::fs::read_to_string("/etc/timezone") {
        if let Ok(zone) = load(Some(text.trim())) {
            return Ok(zone);
        }
    }
    Err("can't tell the system time zone".to_string())
}

// MARK: TZif

type Parsed = (Vec<i64>, Vec<i32>, i32, Option<String>);

fn parse_tzif(b: &[u8]) -> Result<Parsed, String> {
    let bad = || "not a TZif file".to_string();
    let u32_at = |i: usize| b.get(i..i + 4).map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]]) as usize);
    let header = |at: usize| -> Option<[usize; 6]> {
        if b.get(at..at + 4)? != b"TZif" {
            return None;
        }
        let mut counts = [0; 6];
        for (k, count) in counts.iter_mut().enumerate() {
            *count = u32_at(at + 20 + 4 * k)?;
        }
        Some(counts)
    };
    let [isut, isstd, leap, time, kinds, chars] = header(0).ok_or_else(bad)?;
    let version = b[4];
    let v1_len = 44 + time * 5 + kinds * 6 + chars + leap * 8 + isstd + isut;
    let (start, size, counts) = if version >= b'2' {
        (v1_len + 44, 8, header(v1_len).ok_or_else(bad)?)
    } else {
        (44, 4, [isut, isstd, leap, time, kinds, chars])
    };
    let [isut, isstd, leap, time, kinds, chars] = counts;
    let times_at = start;
    let index_at = times_at + time * size;
    let types_at = index_at + time;
    let end = types_at + kinds * 6 + chars + leap * (size + 4) + isstd + isut;
    if b.len() < end || kinds == 0 {
        return Err(bad());
    }
    let utoff = |k: usize| -> Option<i32> {
        let at = types_at + k.checked_mul(6)?;
        (k < kinds).then(|| i32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]))
    };
    let mut times = Vec::with_capacity(time);
    let mut offsets = Vec::with_capacity(time);
    for i in 0..time {
        let at = times_at + i * size;
        let t = if size == 8 {
            i64::from_be_bytes(b[at..at + 8].try_into().map_err(|_| bad())?)
        } else {
            i64::from(i32::from_be_bytes(b[at..at + 4].try_into().map_err(|_| bad())?))
        };
        times.push(t);
        offsets.push(utoff(b[index_at + i] as usize).ok_or_else(bad)?);
    }
    let footer = if version >= b'2' {
        let rest = &b[end..];
        std::str::from_utf8(rest).ok().and_then(|s| s.strip_prefix('\n')).and_then(|s| s.split('\n').next()).map(str::to_string).filter(|s| !s.is_empty())
    } else {
        None
    };
    Ok((times, offsets, utoff(0).ok_or_else(bad)?, footer))
}

// MARK: POSIX TZ rules

impl Rule {
    fn offset(&self, utc: i64) -> i32 {
        let Some(dst) = &self.dst else { return self.std };
        let year = civil_from_days((utc + i64::from(self.std)).div_euclid(86_400)).0;
        // The switch to daylight time is at a wall time in standard time, and back in daylight time.
        let start = day_of_rule(year, dst.start.0) * 86_400 + i64::from(dst.start.1) - i64::from(self.std);
        let end = day_of_rule(year, dst.end.0) * 86_400 + i64::from(dst.end.1) - i64::from(dst.offset);
        let in_dst = if start <= end { utc >= start && utc < end } else { !(utc >= end && utc < start) };
        if in_dst { dst.offset } else { self.std }
    }
}

fn day_of_rule(year: i64, date: Date) -> i64 {
    let jan1 = days_from_civil(year, 1, 1);
    let leap = days_from_civil(year + 1, 1, 1) - jan1 == 366;
    match date {
        Date::Julian(n) => jan1 + n - 1 + i64::from(leap && n >= 60),
        Date::Ordinal(n) => jan1 + n,
        Date::Month(m, w, d) => {
            let first = days_from_civil(year, m, 1);
            let next = if m == 12 { days_from_civil(year + 1, 1, 1) } else { days_from_civil(year, m + 1, 1) };
            let weekday = (first + 4).rem_euclid(7); // 1970-01-01 was a Thursday
            let mut day = first + (d - weekday).rem_euclid(7) + (w - 1) * 7;
            while day >= next {
                day -= 7;
            }
            day
        }
    }
}

struct Cursor<'a> {
    s: &'a [u8],
    i: usize,
}

impl Cursor<'_> {
    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn eat(&mut self, c: u8) -> bool {
        let found = self.peek() == Some(c);
        self.i += usize::from(found);
        found
    }

    fn name(&mut self) -> Option<()> {
        if self.eat(b'<') {
            while self.peek()? != b'>' {
                self.i += 1;
            }
            self.i += 1;
            return Some(());
        }
        let start = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_alphabetic()) {
            self.i += 1;
        }
        (self.i - start >= 3).then_some(())
    }

    fn number(&mut self) -> Option<i64> {
        let start = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.i += 1;
        }
        std::str::from_utf8(&self.s[start..self.i]).ok()?.parse().ok()
    }

    /// [+-]hh[:mm[:ss]] in seconds.
    fn clock(&mut self) -> Option<i64> {
        let sign = if self.eat(b'-') { -1 } else { self.eat(b'+'); 1 };
        let mut seconds = self.number()? * 3600;
        if self.eat(b':') {
            seconds += self.number()? * 60;
            if self.eat(b':') {
                seconds += self.number()?;
            }
        }
        (seconds <= 167 * 3600).then_some(sign * seconds)
    }

    fn date(&mut self) -> Option<(Date, i32)> {
        let date = if self.eat(b'M') {
            let m = self.number()?;
            self.eat(b'.').then_some(())?;
            let w = self.number()?;
            self.eat(b'.').then_some(())?;
            let d = self.number()?;
            ((1..=12).contains(&m) && (1..=5).contains(&w) && (0..=6).contains(&d)).then_some(Date::Month(m, w, d))?
        } else if self.eat(b'J') {
            Some(self.number()?).filter(|n| (1..=365).contains(n)).map(Date::Julian)?
        } else {
            Some(self.number()?).filter(|n| (0..=365).contains(n)).map(Date::Ordinal)?
        };
        let time = if self.eat(b'/') { self.clock()? } else { 2 * 3600 };
        Some((date, time as i32))
    }
}

fn parse_rule(text: &str) -> Option<Rule> {
    let mut c = Cursor { s: text.trim().as_bytes(), i: 0 };
    c.name()?;
    // POSIX offsets are west of UTC; ours are east.
    let std = -c.clock()? as i32;
    if c.peek().is_none() {
        return Some(Rule { std, dst: None });
    }
    c.name()?;
    let offset = match c.peek() {
        Some(b',') | None => std + 3600,
        _ => -c.clock()? as i32,
    };
    let (start, end) = if c.eat(b',') {
        let start = c.date()?;
        c.eat(b',').then_some(())?;
        (start, c.date()?)
    } else {
        // No rule given: the US rule, as glibc assumes.
        ((Date::Month(3, 2, 0), 7200), (Date::Month(11, 1, 0), 7200))
    };
    c.peek().is_none().then_some(Rule { std, dst: Some(Dst { offset, start, end }) })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(y: i64, m: i64, d: i64, h: i64, min: i64) -> i64 {
        days_from_civil(y, m, d) * 86_400 + h * 3600 + min * 60
    }

    #[test]
    fn posix_rules() {
        let chicago = Zone::posix("America/Chicago", "CST6CDT,M3.2.0,M11.1.0").unwrap();
        assert_eq!(chicago.offset(at(2026, 3, 8, 7, 59)), -6 * 3600);
        assert_eq!(chicago.offset(at(2026, 3, 8, 8, 0)), -5 * 3600);
        assert_eq!(chicago.offset(at(2026, 11, 1, 6, 59)), -5 * 3600);
        assert_eq!(chicago.offset(at(2026, 11, 1, 7, 0)), -6 * 3600);
        // India: no daylight time, half-hour offset, a quoted name.
        let kolkata = Zone::posix("Asia/Kolkata", "IST-5:30").unwrap();
        assert_eq!(kolkata.offset(at(2026, 7, 1, 0, 0)), 5 * 3600 + 1800);
        assert_eq!(Zone::posix("x", "<+0545>-5:45").unwrap().offset(0), 5 * 3600 + 45 * 60);
        // Sydney: southern hemisphere, daylight time across the new year, ends at 3:00.
        let sydney = Zone::posix("Australia/Sydney", "AEST-10AEDT,M10.1.0,M4.1.0/3").unwrap();
        assert_eq!(sydney.offset(at(2026, 1, 15, 0, 0)), 11 * 3600);
        assert_eq!(sydney.offset(at(2026, 7, 15, 0, 0)), 10 * 3600);
        // 2026-04-05 03:00 AEDT is 2026-04-04 16:00 UTC.
        assert_eq!(sydney.offset(at(2026, 4, 4, 15, 59)), 11 * 3600);
        assert_eq!(sydney.offset(at(2026, 4, 4, 16, 0)), 10 * 3600);
        // London: the last Sunday of March at 01:00 UTC.
        let london = Zone::posix("Europe/London", "GMT0BST,M3.5.0/1,M10.5.0").unwrap();
        assert_eq!(london.offset(at(2026, 3, 29, 0, 59)), 0);
        assert_eq!(london.offset(at(2026, 3, 29, 1, 0)), 3600);
        assert_eq!(london.offset(at(2026, 10, 25, 0, 59)), 3600);
        assert_eq!(london.offset(at(2026, 10, 25, 1, 0)), 0);
        assert!(Zone::posix("x", "Nowhere/Land").is_none());
        assert!(load(Some("Not/AZone")).is_err());
        assert_eq!(load(Some("UTC")).unwrap().offset(at(2026, 7, 1, 0, 0)), 0);
    }

    #[test]
    fn system_zoneinfo_files_match_the_rules() {
        // Skipped where the system has no zoneinfo files.
        let Ok(chicago) = load(Some("America/Chicago")) else { return };
        let rule = Zone::posix("r", "CST6CDT,M3.2.0,M11.1.0").unwrap();
        // Every 3 hours from 2010 to 2045 (past the files' last transition too).
        let mut t = at(2010, 1, 1, 0, 0);
        while t < at(2045, 1, 1, 0, 0) {
            assert_eq!(chicago.offset(t), rule.offset(t), "at {t}");
            t += 3 * 3600;
        }
        for (name, utc, offset) in [
            ("Asia/Kolkata", at(2026, 11, 9, 0, 0), 19_800),
            ("Asia/Tokyo", at(2026, 11, 9, 0, 0), 9 * 3600),
            ("Europe/Berlin", at(2026, 7, 1, 0, 0), 2 * 3600),
            ("Europe/Berlin", at(2026, 12, 1, 0, 0), 3600),
            ("Australia/Sydney", at(2030, 1, 1, 0, 0), 11 * 3600),
            ("America/Sao_Paulo", at(2026, 1, 1, 0, 0), -3 * 3600),
        ] {
            assert_eq!(load(Some(name)).unwrap().offset(utc), offset, "{name}");
        }
        assert!(load(Some("../../etc/passwd")).is_err());
    }
}
