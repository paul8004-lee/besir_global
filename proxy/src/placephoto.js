// POST /place-photo: one Google place photo by its resource name. The upstream call is handed in by index.js, so this
// module holds no network, key, clock, storage, random or log call; nothing is kept between requests.
const MAX_BODY_CHARS = 4096;
const ALLOWED_KEYS = ["name", "max_width"];
const NAME_PATTERN = /^places\/[A-Za-z0-9_-]{1,300}\/photos\/[A-Za-z0-9_-]{1,2000}$/;
const MIN_WIDTH = 100;
const MAX_WIDTH = 1600;

const has = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

export async function handlePlacePhoto(request, { json, photo }) {
  const text = await request.text();
  if (text.length > MAX_BODY_CHARS) return json(413, { error: "body_too_large" });
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return json(400, { error: "body_must_be_object" });
  }
  if (Object.keys(value).some((key) => !ALLOWED_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  if (!has(value, "name") || !has(value, "max_width")) return json(400, { error: "missing_field" });
  const { name, max_width: width } = value;
  if (typeof name !== "string" || !NAME_PATTERN.test(name)) return json(400, { error: "invalid_field" });
  if (typeof width !== "number" || !Number.isInteger(width) || width < MIN_WIDTH || width > MAX_WIDTH) {
    return json(400, { error: "invalid_field" });
  }
  const result = await photo({ name, width });
  if (result.outcome === "no_key") return json(503, { error: "google_key_not_configured" });
  if (result.outcome !== "ok") return json(502, { error: "upstream_failed" });
  return new Response(result.response.body, {
    status: 200,
    headers: { "content-type": result.response.headers.get("content-type"), "cache-control": "no-store" },
  });
}
