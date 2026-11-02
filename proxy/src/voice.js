// POST /voice: one base64 WAV in, {text} out. The clip goes to Meta Muse Voice Transcribe and nowhere else.
// Everything sent upstream is fixed here; the client picks nothing but the audio.
// The route keeps no audio and no transcript: no storage, no state between requests, no logging.

const UPSTREAM_URL = "https://api.meta.ai/v1/asr/transcribe";
const MODEL = "muse-voice-transcribe-1.0";
const MODE = "PUSH_TO_TALK";
const ENCODING = "WAV";
const MAX_BODY_CHARS = 1_400_000;
const MAX_AUDIO_BYTES = 1_000_000;
const MIN_DATA_BYTES = 3_200;
const MAX_DATA_BYTES = 960_000;
const UPSTREAM_TIMEOUT_MS = 25_000;
const MAX_TEXT_CODEPOINTS = 1000;
const SAMPLE_RATE = 16000;

// Same shape as readBody in snap.js, with its own cap: the size is checked on the text before parsing.
async function readBody(request, json) {
  const text = await request.text();
  if (text.length > MAX_BODY_CHARS) return { error: json(413, { error: "body_too_large" }) };
  try {
    const value = JSON.parse(text);
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      return { error: json(400, { error: "body_must_be_object" }) };
    }
    return { value };
  } catch {
    return { error: json(400, { error: "invalid_json" }) };
  }
}

// Base64 text to bytes with an indexed loop (no per-byte callback: the Worker's CPU budget).
function decode(audio) {
  const binary = atob(audio);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

const tag = (b, at) => String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
const u16 = (b, at) => b[at] | (b[at + 1] << 8);
const u32 = (b, at) => (b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)) >>> 0;

// Walks the chunks from offset 12. A chunk with any other id (JUNK, FLLR, LIST, ...) is skipped wherever it sits
// before "data", including before "fmt ". Returns {fmt, data} (offsets), or null when the file is not a usable WAV.
function walk(b) {
  if (b.length < 12 || tag(b, 0) !== "RIFF" || tag(b, 8) !== "WAVE") return null;
  let fmt = null;
  let offset = 12;
  while (offset + 8 <= b.length) {
    const id = tag(b, offset);
    const size = u32(b, offset + 4);
    const body = offset + 8;
    if (id === "fmt ") {
      if (fmt === null) {
        if (size < 16 || body + 16 > b.length) return null;
        fmt = { tag: u16(b, body), channels: u16(b, body + 2), rate: u32(b, body + 4), bits: u16(b, body + 14) };
      }
    } else if (id === "data") {
      if (fmt === null || body + size > b.length || size % 2 !== 0) return null;
      return { fmt, start: body, size };
    }
    offset = body + size + (size & 1);
  }
  return null;
}

const put16 = (b, at, n) => {
  b[at] = n & 0xff;
  b[at + 1] = (n >> 8) & 0xff;
};
const put32 = (b, at, n) => {
  put16(b, at, n & 0xffff);
  put16(b, at + 2, (n >>> 16) & 0xffff);
};
const putTag = (b, at, text) => {
  for (let i = 0; i < 4; i++) b[at + i] = text.charCodeAt(i);
};

// A plain 44-byte-header mono 16 kHz 16-bit PCM WAV around the validated samples.
function canonical(b, start, size) {
  const out = new Uint8Array(44 + size);
  putTag(out, 0, "RIFF");
  put32(out, 4, 36 + size);
  putTag(out, 8, "WAVE");
  putTag(out, 12, "fmt ");
  put32(out, 16, 16);
  put16(out, 20, 1);
  put16(out, 22, 1);
  put32(out, 24, SAMPLE_RATE);
  put32(out, 28, SAMPLE_RATE * 2);
  put16(out, 32, 2);
  put16(out, 34, 16);
  putTag(out, 36, "data");
  put32(out, 40, size);
  out.set(b.subarray(start, start + size), 44);
  return out;
}

// Returns {wav} or {error: Response}.
function checkAudio(audio, json) {
  if (typeof audio !== "string" || audio === "") return { error: json(400, { error: "audio_required" }) };
  if (audio.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(audio)) return { error: json(400, { error: "audio_not_base64" }) };
  const padding = audio.endsWith("==") ? 2 : audio.endsWith("=") ? 1 : 0;
  if ((audio.length / 4) * 3 - padding > MAX_AUDIO_BYTES) return { error: json(413, { error: "audio_too_large" }) };
  const bytes = decode(audio);
  const found = walk(bytes);
  if (found === null) return { error: json(400, { error: "audio_not_wav" }) };
  const { fmt, start, size } = found;
  if (fmt.tag !== 1 || fmt.channels !== 1 || fmt.rate !== SAMPLE_RATE || fmt.bits !== 16) {
    return { error: json(400, { error: "audio_format_unsupported" }) };
  }
  if (size < MIN_DATA_BYTES) return { error: json(400, { error: "audio_empty" }) };
  if (size > MAX_DATA_BYTES) return { error: json(400, { error: "audio_too_long" }) };
  return { wav: canonical(bytes, start, size) };
}

const isTimeout = (err) => err && (err.name === "TimeoutError" || err.name === "AbortError");
const failure = (err, json) =>
  isTimeout(err) ? json(504, { error: "voice_timeout" }) : json(502, { error: "upstream_unreachable" });

function statusError(status, json) {
  const error = (name) => json(name === "voice_rate_limited" ? 429 : 502, { error: name, upstream_status: status });
  if (status === 429) return error("voice_rate_limited");
  if (status === 401 || status === 403) return error("voice_upstream_auth");
  if (status === 404) return error("voice_upstream_not_found");
  if (status === 400) return error("voice_upstream_rejected");
  if (status >= 500) return error("voice_upstream_unavailable");
  return error("voice_upstream_error");
}

const tryParse = (text) => {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false };
  }
};

function cleanText(v) {
  const collapsed = v.replace(/\s+/g, " ").trim();
  return [...collapsed].slice(0, MAX_TEXT_CODEPOINTS).join("").trim();
}

export async function handleVoice(request, env, { json }) {
  // The key check comes before the body is read, as in handleSnap.
  if (!env.META_API_KEY) return json(503, { error: "meta_key_not_configured" });
  const { value, error } = await readBody(request, json);
  if (error) return error;
  const checked = checkAudio(value.audio, json);
  if (checked.error) return checked.error;

  const form = new FormData();
  form.append("request", new Blob([JSON.stringify({ mode: MODE, model: MODEL, audioEncoding: ENCODING })], { type: "application/json" }));
  form.append("audio", new Blob([checked.wav], { type: "audio/wav" }), "audio.wav");

  let upstream;
  try {
    upstream = await fetch(UPSTREAM_URL, {
      method: "POST",
      headers: { authorization: `Bearer ${env.META_API_KEY}`, accept: "application/json" },
      body: form,
      redirect: "manual",
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (err) {
    return failure(err, json);
  }

  const unparseable = () => json(502, { error: "voice_unparseable", upstream_status: upstream.status });
  if (upstream.status !== 200) {
    if (upstream.status >= 300 && upstream.status < 400) return unparseable();
    if (upstream.status >= 200 && upstream.status < 300) return unparseable();
    return statusError(upstream.status, json);
  }

  let text;
  try {
    text = await upstream.text();
  } catch (err) {
    return failure(err, json);
  }
  const parsed = tryParse(text);
  const body = parsed.ok ? parsed.value : null;
  if (body === null || typeof body !== "object" || Array.isArray(body) || typeof body.transcript !== "string") {
    return json(502, { error: "voice_unparseable", upstream_status: 200 });
  }
  return json(200, { text: cleanText(body.transcript) });
}
