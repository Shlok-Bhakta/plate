//! The model provider for AI logging: any OpenAI-compatible Chat Completions API (OpenRouter by
//! default, OpenAI, a local server). Blocking `ureq`, retries on 429, 5xx and connection errors,
//! and plain-language errors. The API key is only ever put in the Authorization header: it's
//! scrubbed from every error, and the provider's Debug output hides it.

use serde_json::{json, Value};
use std::io::Read;
use std::time::{Duration, Instant};

/// Replies past this are cut off (OpenRouter's whole model list is about 1 MB).
const MAX_REPLY: u64 = 32 << 20;
/// Tries after the first, for 429, 5xx and connection errors.
const RETRIES: u32 = 2;

pub struct Provider {
    pub base_url: String,
    pub model: String,
    key: String,
}

impl std::fmt::Debug for Provider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Provider").field("base_url", &self.base_url).field("model", &self.model)
            .field("authorization", &"Bearer [redacted]").finish()
    }
}

/// One failed attempt.
enum Failure {
    Status(u16, String, Option<Duration>),
    Transport(String),
}

impl Failure {
    fn retryable(&self) -> bool {
        matches!(self, Failure::Transport(_) | Failure::Status(429 | 500..=599, _, _))
    }
}

pub fn is_openrouter(base_url: &str) -> bool {
    base_url.to_ascii_lowercase().contains("openrouter.ai")
}

impl Provider {
    pub fn new(base_url: &str, key: &str, model: &str) -> Provider {
        Provider { base_url: base_url.trim_end_matches('/').to_string(), key: key.to_string(), model: model.to_string() }
    }

    pub fn openrouter(&self) -> bool {
        is_openrouter(&self.base_url)
    }

    /// Takes the key out of any text that leaves this module.
    pub fn redact(&self, text: &str) -> String {
        if self.key.len() >= 4 { text.replace(&self.key, "[redacted]") } else { text.to_string() }
    }

    fn attempt(&self, path: &str, body: Option<&Value>, timeout: Duration) -> Result<Value, Failure> {
        let agent = ureq::AgentBuilder::new().timeout(timeout).user_agent(&crate::config::get().user_agent()).build();
        let url = format!("{}{path}", self.base_url);
        let mut request = match body {
            Some(_) => agent.post(&url),
            None => agent.get(&url),
        };
        if !self.key.is_empty() {
            request = request.set("Authorization", &format!("Bearer {}", self.key));
        }
        if self.openrouter() {
            request = request.set("HTTP-Referer", "http://localhost/plate").set("X-Title", "Plate");
        }
        let result = match body {
            Some(body) => request.set("Content-Type", "application/json").send_string(&body.to_string()),
            None => request.call(),
        };
        let read = |response: ureq::Response| {
            let mut text = String::new();
            let _ = response.into_reader().take(MAX_REPLY).read_to_string(&mut text);
            text
        };
        match result {
            Ok(response) => {
                let text = read(response);
                let value: Value = serde_json::from_str(&text)
                    .map_err(|_| Failure::Status(502, format!("not JSON: {}", text.chars().take(200).collect::<String>()), None))?;
                // OpenRouter can answer 200 with an error object.
                if let Some(error) = value.get("error").filter(|e| e.is_object()) {
                    let code = error["code"].as_u64().filter(|c| (400..600).contains(c)).unwrap_or(502) as u16;
                    return Err(Failure::Status(code, value.to_string(), None));
                }
                Ok(value)
            }
            Err(ureq::Error::Status(code, response)) => {
                let wait = response.header("retry-after").and_then(|s| s.trim().parse::<f64>().ok())
                    .filter(|s| s.is_finite() && *s >= 0.0).map(|s| Duration::from_secs_f64(s.min(30.0)));
                Err(Failure::Status(code, read(response), wait))
            }
            Err(ureq::Error::Transport(error)) => Err(Failure::Transport(error.to_string())),
        }
    }

    /// A request with retries, all of it finished by `deadline`. Each try waits at most `per_try`.
    fn send(&self, path: &str, body: Option<&Value>, per_try: Duration, deadline: Instant) -> Result<Value, String> {
        let mut tries = 0;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left < Duration::from_secs(1) {
                return Err("timed out waiting for the model".to_string());
            }
            match self.attempt(path, body, per_try.min(left)) {
                Ok(value) => return Ok(value),
                Err(failure) if failure.retryable() && tries < RETRIES => {
                    tries += 1;
                    let base = if cfg!(test) { Duration::from_millis(20) } else { Duration::from_secs(1) };
                    let backoff = base * 3u32.pow(tries - 1);
                    let wait = match &failure {
                        Failure::Status(_, _, Some(after)) if !cfg!(test) => (*after).max(backoff),
                        _ => backoff,
                    };
                    if Instant::now() + wait + Duration::from_secs(1) >= deadline {
                        return Err(self.redact(&self.describe(&failure)));
                    }
                    std::thread::sleep(wait);
                }
                Err(failure) => return Err(self.redact(&self.describe(&failure))),
            }
        }
    }

    fn describe(&self, failure: &Failure) -> String {
        match failure {
            Failure::Status(code, body, _) => describe(*code, body, &self.model),
            Failure::Transport(error) => format!("can't reach the provider at {}: {error}", self.base_url),
        }
    }

    /// `POST {base_url}/chat/completions`.
    pub fn chat(&self, body: &Value, per_try: Duration, deadline: Instant) -> Result<Value, String> {
        self.send("/chat/completions", Some(body), per_try, deadline)
    }

    /// `GET {base_url}/models`.
    pub fn models(&self) -> Result<Value, String> {
        self.send("/models", None, Duration::from_secs(20), Instant::now() + Duration::from_secs(45))
    }

    /// The request body every chat call shares: model, token limit, and OpenRouter's usage flag.
    pub fn body(&self, messages: &[Value], tools: Option<&Value>, max_tokens: u64) -> Value {
        let mut body = json!({"model": self.model, "messages": messages});
        if let Some(tools) = tools {
            body["tools"] = tools.clone();
            body["tool_choice"] = json!("auto");
        }
        // OpenAI's newer models only take max_completion_tokens; everyone else knows max_tokens.
        let limit = if self.base_url.contains("api.openai.com") { "max_completion_tokens" } else { "max_tokens" };
        body[limit] = json!(max_tokens);
        if self.openrouter() {
            // Asks OpenRouter for usage.cost in USD. Sent only there: strict servers reject unknown fields.
            body["usage"] = json!({"include": true});
        }
        body
    }
}

/// The provider's own error text: `error.message`, else the body, short.
fn provider_message(body: &str) -> String {
    let parsed: Option<Value> = serde_json::from_str(body).ok();
    let text = parsed.as_ref()
        .and_then(|v| v["error"]["message"].as_str().or(v["error"].as_str()).or(v["message"].as_str()).or(v["detail"].as_str()))
        .map(str::to_string)
        .unwrap_or_else(|| body.trim().to_string());
    let mut text: String = text.chars().filter(|c| !c.is_control()).take(300).collect();
    if text.is_empty() {
        text = "no details".to_string();
    }
    text
}

/// A failed status as something a person can act on.
pub fn describe(code: u16, body: &str, model: &str) -> String {
    let message = provider_message(body);
    let lower = format!("{message} {body}").to_lowercase();
    let filtered = ["content filter", "content_filter", "moderation", "flagged", "content management policy", "safety system"]
        .iter().any(|w| lower.contains(w));
    let model_missing = lower.contains("model")
        && ["not found", "not a valid", "does not exist", "unknown model", "no such model", "invalid model", "not available"]
            .iter().any(|w| lower.contains(w));
    match code {
        401 => "API key is invalid".to_string(),
        402 => "out of credit: add credit with your provider (or pick a cheaper model)".to_string(),
        _ if lower.contains("no endpoints found that support") || lower.contains("does not support image")
            || lower.contains("does not support tools") => {
            format!("{model:?} can't do this ({message}); pick a model with image input and tool calling")
        }
        _ if filtered => format!("the provider's content filter blocked this request ({message})"),
        404 => format!("unknown model {model:?}: check the model id (`food agent models`)"),
        _ if model_missing => format!("unknown model {model:?}: check the model id ({message})"),
        403 => format!("the provider refused the request (HTTP 403): {message}"),
        429 => format!("rate limited by the provider; try again in a minute ({message})"),
        500..=599 => format!("the provider had an error (HTTP {code}); try again ({message})"),
        _ => format!("the provider said (HTTP {code}): {message}"),
    }
}

/// Usage from a chat reply: prompt and completion tokens, and USD cost when the provider says.
pub fn usage(reply: &Value) -> (i64, i64, Option<f64>) {
    let u = &reply["usage"];
    let cost = u["cost"].as_f64().or_else(|| u["cost"].as_str().and_then(|s| s.parse().ok())).filter(|c| c.is_finite() && *c >= 0.0);
    (u["prompt_tokens"].as_i64().unwrap_or(0).max(0), u["completion_tokens"].as_i64().unwrap_or(0).max(0), cost)
}

/// A per-token price string as USD per 1M tokens. OpenRouter's "-1" (variable) is unknown.
fn per_million(price: &Value) -> Value {
    let x = price.as_f64().or_else(|| price.as_str().and_then(|s| s.trim().parse().ok()));
    match x {
        Some(x) if x.is_finite() && x >= 0.0 => json!(((x * 1e6) * 10_000.0).round() / 10_000.0),
        _ => Value::Null,
    }
}

/// `GET /models` as `{id, name, context_length, prompt_price, completion_price}`, sorted by name
/// and matched against `q`. For OpenRouter, only models that take images and call tools.
pub fn parse_models(reply: &Value, openrouter: bool, q: &str) -> Vec<Value> {
    let has = |list: &Value, word: &str| list.as_array().is_some_and(|l| l.iter().any(|v| v.as_str() == Some(word)));
    let words: Vec<String> = q.split_whitespace().map(str::to_lowercase).collect();
    let mut out: Vec<Value> = reply["data"].as_array().cloned().unwrap_or_default().iter()
        .filter_map(|m| {
            let id = m["id"].as_str()?;
            if openrouter && !(has(&m["architecture"]["input_modalities"], "image") && has(&m["supported_parameters"], "tools")) {
                return None;
            }
            let name = m["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(id);
            let hay = format!("{id} {name}").to_lowercase();
            if !words.iter().all(|w| hay.contains(w)) {
                return None;
            }
            let (prompt, completion) = if openrouter {
                (per_million(&m["pricing"]["prompt"]), per_million(&m["pricing"]["completion"]))
            } else {
                (Value::Null, Value::Null)
            };
            Some(json!({"id": id, "name": name, "context_length": m["context_length"].as_i64(),
                        "prompt_price": prompt, "completion_price": completion}))
        })
        .collect();
    out.sort_by_key(|m| (m["name"].as_str().unwrap_or("").to_lowercase(), m["id"].as_str().unwrap_or("").to_string()));
    out
}

// MARK: Base64 (images travel as base64; no crate for 40 lines)

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16) | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8) | u32::from(*chunk.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Standard or URL-safe base64, padded or not, with whitespace ignored. `max` caps the output.
pub fn base64_decode(text: &str, max: usize) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity((text.len() / 4 * 3).min(max + 3));
    let (mut buffer, mut bits) = (0u32, 0);
    for c in text.bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' => break,
            b' ' | b'\n' | b'\r' | b'\t' => continue,
            _ => return Err("the image isn't valid base64".to_string()),
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
            if out.len() > max {
                return Err(format!("the image is over {:.1} MB", max as f64 / 1_048_576.0));
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
pub mod tests {
    use super::*;

    #[test]
    fn base64_round_trips() {
        for text in ["", "f", "fo", "foo", "foob", "fooba", "foobar"] {
            let encoded = base64_encode(text.as_bytes());
            assert_eq!(base64_decode(&encoded, 100).unwrap(), text.as_bytes(), "{text}");
        }
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_decode("Zm9v\nYmE", 100).unwrap(), b"fooba");
        let bytes: Vec<u8> = (0..=255).collect();
        assert_eq!(base64_decode(&base64_encode(&bytes), 1000).unwrap(), bytes);
        assert!(base64_decode("Zm9v*", 100).is_err());
        assert!(base64_decode(&base64_encode(&[0; 200]), 100).unwrap_err().contains("over"));
    }

    #[test]
    fn errors_say_what_to_do() {
        let body = |m: &str| json!({"error": {"message": m, "code": 0}}).to_string();
        assert_eq!(describe(401, &body("No auth credentials found"), "m"), "API key is invalid");
        assert!(describe(402, &body("Insufficient credits"), "m").starts_with("out of credit"));
        assert!(describe(404, "", "x/y").starts_with("unknown model \"x/y\""));
        assert!(describe(400, &body("foo/bar is not a valid model ID"), "foo/bar").starts_with("unknown model"));
        assert!(describe(404, &body("No endpoints found that support image input"), "m").contains("image input and tool calling"));
        assert!(describe(403, &body("Input was flagged by moderation"), "m").contains("content filter"));
        assert!(describe(429, &body("slow down"), "m").starts_with("rate limited"));
        assert!(describe(503, "<html>oops</html>", "m").contains("HTTP 503"));
        assert!(describe(400, &body("bad things"), "m").contains("bad things"));
        let provider = Provider::new("https://openrouter.ai/api/v1/", "sk-or-v1-secret", "m");
        assert_eq!(provider.base_url, "https://openrouter.ai/api/v1");
        assert_eq!(provider.redact("Incorrect API key provided: sk-or-v1-secret"), "Incorrect API key provided: [redacted]");
        let shown = format!("{provider:?}");
        assert!(!shown.contains("secret") && shown.contains("[redacted]"), "{shown}");
    }

    #[test]
    fn bodies_fit_the_provider() {
        let open_router = Provider::new("https://openrouter.ai/api/v1", "k", "a/b");
        let body = open_router.body(&[json!({"role": "user", "content": "hi"})], Some(&json!([])), 100);
        assert_eq!((body["usage"]["include"].as_bool(), body["max_tokens"].as_u64(), body["tool_choice"].as_str()), (Some(true), Some(100), Some("auto")));
        let openai = Provider::new("https://api.openai.com/v1", "k", "gpt").body(&[], None, 100);
        assert!(openai.get("usage").is_none() && openai.get("tools").is_none());
        assert_eq!(openai["max_completion_tokens"], 100);
        assert_eq!(usage(&json!({"usage": {"prompt_tokens": 10, "completion_tokens": 5, "cost": 0.0012}})), (10, 5, Some(0.0012)));
        assert_eq!(usage(&json!({"usage": {"prompt_tokens": 10}})), (10, 0, None));
    }

    /// A trimmed copy of OpenRouter's GET /api/v1/models (the field names as of 2026-11).
    pub const OPENROUTER_MODELS: &str = r#"{"data": [
      {"id": "openai/gpt-5-mini", "name": "OpenAI: GPT-5 Mini", "context_length": 400000,
       "architecture": {"modality": "text+image->text", "input_modalities": ["text", "image", "file"], "output_modalities": ["text"]},
       "pricing": {"prompt": "0.00000025", "completion": "0.000002", "request": "0", "image": "0"},
       "supported_parameters": ["max_tokens", "tools", "tool_choice", "response_format"]},
      {"id": "meta-llama/llama-3-8b-instruct", "name": "Meta: Llama 3 8B Instruct", "context_length": 8192,
       "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
       "pricing": {"prompt": "0.00000003", "completion": "0.00000006"}, "supported_parameters": ["max_tokens", "tools"]},
      {"id": "some/vision-no-tools", "name": "Vision Without Tools", "context_length": 32000,
       "architecture": {"input_modalities": ["image", "text"]}, "pricing": {"prompt": "0.000001", "completion": "0.000001"},
       "supported_parameters": ["max_tokens"]},
      {"id": "anthropic/claude-sonnet-4.5", "name": "Anthropic: Claude Sonnet 4.5", "context_length": 1000000,
       "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"prompt": "0.000003", "completion": "0.000015"},
       "supported_parameters": ["tools", "tool_choice", "max_tokens"]},
      {"id": "openrouter/auto", "name": "Auto Router", "context_length": 2000000,
       "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"prompt": "-1", "completion": "-1"},
       "supported_parameters": ["tools"]}
    ]}"#;

    #[test]
    fn open_router_models_are_filtered_to_images_and_tools() {
        let reply: Value = serde_json::from_str(OPENROUTER_MODELS).unwrap();
        let models = parse_models(&reply, true, "");
        let ids: Vec<&str> = models.iter().filter_map(|m| m["id"].as_str()).collect();
        assert_eq!(ids, ["anthropic/claude-sonnet-4.5", "openrouter/auto", "openai/gpt-5-mini"], "sorted by name");
        assert_eq!(models[0]["prompt_price"], json!(3.0));
        assert_eq!(models[0]["completion_price"], json!(15.0));
        assert_eq!(models[0]["context_length"], json!(1000000));
        assert_eq!(models[2]["prompt_price"], json!(0.25));
        assert!(models[1]["prompt_price"].is_null(), "variable pricing is unknown");
        assert_eq!(parse_models(&reply, true, "GPT mini").len(), 1);
        // Other providers: every id, no prices.
        let all = parse_models(&reply, false, "");
        assert_eq!(all.len(), 5);
        assert!(all.iter().all(|m| m["prompt_price"].is_null()));
    }
}
