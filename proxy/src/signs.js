// POST /signs: one image in, {width, height, boxes} out, at most 5 boxes of storefront signs.
// Meta SAM 3.1 proposes boxes; the app's existing reader decides which of them is a shop name sign.
// Everything sent to Meta is fixed here; the client picks nothing but the image and its mime.
// The answer is an event stream whose closing events repeat the whole text, so only the text deltas are read.
// Masks are never kept. Nothing is stored, logged or cached; an upstream call is made once per request.
// The body helpers are copies of the ones in snap.js, so that file stays untouched.

const META_RESPONSES_URL = "https://api.meta.ai/v1/responses";
const SIGNS_MODEL = "sam-3.1";
const MAX_BODY_CHARS = 6 * 1024 * 1024;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const MAX_STREAM_CHARS = 2 * 1024 * 1024;
const UPSTREAM_TIMEOUT_MS = 10000;
const ALLOWED_MIMES = ["image/jpeg", "image/png", "image/webp"];

// Reduction constants, in pixels of the analysed image (the box tokens' own pixel space).
const MIN_SHORT_SIDE = 24;
const MIN_LONG_SIDE = 60;
const INSIDE_PERCENT = 80;
const CONTAINER_MAX_PERCENT = 25;
const MAX_BOXES = 5;

// Same shape as readBody in snap.js: the size is checked on the text before parsing.
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

function hasMagic(mime, b) {
  if (b.length < 12) return false;
  if (mime === "image/jpeg") return b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  if (mime === "image/png") return [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((v, i) => b[i] === v);
  const at = (s, i) => [...s].every((c, k) => b[i + k] === c.charCodeAt(0));
  return at("RIFF", 0) && at("WEBP", 8);
}

// Returns the error response for a bad image, or null. Only the first 12 bytes are decoded.
function checkImage(image, mime, json) {
  if (typeof image !== "string" || image === "") return json(400, { error: "image_required" });
  if (!ALLOWED_MIMES.includes(mime)) return json(400, { error: "mime_not_allowed" });
  if (image.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(image)) return json(400, { error: "image_not_base64" });
  const head = image.length >= 16 ? image.slice(0, 16) : image;
  const bytes = Uint8Array.from(atob(head), (c) => c.charCodeAt(0));
  if (!hasMagic(mime, bytes)) return json(400, { error: "image_mime_mismatch" });
  const padding = image.endsWith("==") ? 2 : image.endsWith("=") ? 1 : 0;
  if ((image.length / 4) * 3 - padding > MAX_IMAGE_BYTES) return json(413, { error: "image_too_large" });
  return null;
}

const isTimeout = (err) => err && (err.name === "TimeoutError" || err.name === "AbortError");
const failure = (err, json) =>
  isTimeout(err) ? json(504, { error: "signs_timeout" }) : json(502, { error: "upstream_unreachable" });

// A fixed answer for a status: nothing of the upstream body or headers is passed on.
function statusError(status, json) {
  if (status === 429) return json(429, { error: "signs_rate_limited" });
  if (status === 401 || status === 403) return json(502, { error: "signs_upstream_auth" });
  if (status === 400) return json(502, { error: "signs_upstream_rejected" });
  if (status >= 500) return json(502, { error: "signs_upstream_unavailable" });
  return json(502, { error: "signs_upstream_error" });
}

// Reads the whole stream as text, or stops at the size bound. Returns { text } or { tooLarge }.
async function readStream(body) {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    text += decoder.decode(value, { stream: true });
    if (text.length > MAX_STREAM_CHARS) {
      await reader.cancel().catch(() => {});
      return { tooLarge: true };
    }
  }
  return { text: text + decoder.decode() };
}

// The text deltas joined, and whether the stream finished. Returns null for a stream that cannot be read.
function readEvents(raw) {
  let answer = "";
  let completed = false;
  for (const line of raw.split(/\r?\n/)) {
    if (!line.startsWith("data:")) continue;
    const data = line.slice(5).trim();
    if (data === "[DONE]") break;
    let event;
    try {
      event = JSON.parse(data);
    } catch {
      return null;
    }
    if (event === null || typeof event !== "object") return null;
    if (event.type === "response.output_text.delta") {
      if (typeof event.delta !== "string") return null;
      answer += event.delta;
    } else if (event.type === "response.completed") {
      completed = true;
    } else if (event.type === "response.failed" || event.type === "response.incomplete" || event.type === "error") {
      return null;
    }
  }
  return completed ? answer : null;
}

const INTEGER = /^[0-9]+$/;
const NUMBER = /^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/;

// Every box token of the answer text, masks dropped. Returns null when any token is malformed or the
// boxes do not agree on one image size. A completed answer with no token is { w: 0, h: 0, boxes: [] }.
function parseBoxes(answer) {
  const boxes = [];
  let w = 0;
  let h = 0;
  const parts = answer.split("<|box;").slice(1);
  for (const part of parts) {
    const end = part.indexOf("|>");
    if (end === -1) return null;
    const fields = {};
    for (const pair of part.slice(0, end).split(";")) {
      const at = pair.indexOf("=");
      if (at === -1) return null;
      fields[pair.slice(0, at)] = pair.slice(at + 1);
    }
    const ints = ["x1", "y1", "x2", "y2", "w", "h"];
    if (!ints.every((k) => typeof fields[k] === "string" && INTEGER.test(fields[k]))) return null;
    if (typeof fields.c !== "string" || !NUMBER.test(fields.c)) return null;
    const [x1, y1, x2, y2, bw, bh] = ints.map((k) => Number(fields[k]));
    const confidence = Number(fields.c);
    if (!Number.isFinite(confidence)) return null;
    if (bw <= 0 || bh <= 0 || !(0 <= x1 && x1 < x2 && x2 <= bw) || !(0 <= y1 && y1 < y2 && y2 <= bh)) return null;
    if (boxes.length > 0 && (bw !== w || bh !== h)) return null;
    w = bw;
    h = bh;
    boxes.push({ x1, y1, x2, y2, confidence });
  }
  return { w, h, boxes };
}

const area = (b) => (b.x2 - b.x1) * (b.y2 - b.y1);

function intersection(a, b) {
  const dx = Math.min(a.x2, b.x2) - Math.max(a.x1, b.x1);
  const dy = Math.min(a.y2, b.y2) - Math.max(a.y1, b.y1);
  return dx > 0 && dy > 0 ? dx * dy : 0;
}

// Size rule, then the inside rule among the boxes that passed it, then the order and the cap.
function reduce({ w, h, boxes }) {
  const sized = boxes.filter((b) => {
    const dx = b.x2 - b.x1;
    const dy = b.y2 - b.y1;
    return Math.min(dx, dy) >= MIN_SHORT_SIDE && Math.max(dx, dy) >= MIN_LONG_SIDE;
  });
  const kept = sized.filter(
    (b) =>
      !sized.some(
        (c) =>
          c !== b &&
          area(c) > area(b) &&
          area(c) * 100 <= w * h * CONTAINER_MAX_PERCENT &&
          intersection(b, c) * 100 >= area(b) * INSIDE_PERCENT,
      ),
  );
  kept.sort((a, b) => b.confidence - a.confidence || area(b) - area(a) || a.y1 - b.y1 || a.x1 - b.x1);
  return kept.slice(0, MAX_BOXES);
}

export async function handleSigns(request, env, { json }) {
  // The key check comes before the body is read, as in handleSnap.
  if (!env.META_API_KEY) return json(503, { error: "meta_key_not_configured" });
  const { value, error } = await readBody(request, json);
  if (error) return error;
  const { image, mime } = value;
  const bad = checkImage(image, mime, json);
  if (bad) return bad;

  const unparseable = () => json(502, { error: "signs_unparseable" });
  let raw;
  try {
    const upstream = await fetch(META_RESPONSES_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "text/event-stream",
        authorization: `Bearer ${env.META_API_KEY}`,
      },
      body: JSON.stringify({
        model: SIGNS_MODEL,
        stream: true,
        store: false,
        metadata: { include_confidence: "true" },
        input: [
          {
            type: "message",
            role: "user",
            content: [
              { type: "input_text", text: "storefront sign" },
              { type: "input_image", image_url: `data:${mime};base64,${image}` },
            ],
          },
        ],
      }),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    if (upstream.status !== 200) return statusError(upstream.status, json);
    if (!upstream.body) return unparseable();
    const read = await readStream(upstream.body);
    if (read.tooLarge) return json(502, { error: "signs_too_large" });
    raw = read.text;
  } catch (err) {
    return failure(err, json);
  }

  const answer = readEvents(raw);
  if (answer === null) return unparseable();
  const parsed = parseBoxes(answer);
  if (parsed === null) return unparseable();
  const boxes = reduce(parsed);
  if (boxes.length === 0 && parsed.boxes.length === 0) return json(200, { width: 0, height: 0, boxes: [] });
  return json(200, { width: parsed.w, height: parsed.h, boxes });
}
