// The lookup rule every partner route shares, moved out of booking.js so the two routes cannot drift: one module,
// one answer shape. The Places call is handed in by index.js, so this file holds no outgoing call and no key.
const MIN_LOOKUP_CHARS = 2;
const MAX_LOOKUP_CHARS = 80;
const MAX_CANDIDATES = 5;
const MAX_CANDIDATE_NAME_CHARS = 80;
const MAX_CANDIDATE_ADDRESS_CHARS = 120;
const NEAR_KEYS = ["latitude", "longitude"];
const HIDDEN_CHARACTER = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;

const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

// The same text rule the partner values use: no hidden character, then trimmed and counted in code points.
function cleanText(value, longest, shortest = 1) {
  if (typeof value !== "string" || HIDDEN_CHARACTER.test(value)) return null;
  const trimmed = value.trim();
  const length = [...trimmed].length;
  return length >= shortest && length <= longest ? trimmed : null;
}

// A text as a candidate field is read: it is kept as sent, so no trimming; it may not be blank or hold a hidden character.
function soundText(value, longest) {
  if (typeof value !== "string" || HIDDEN_CHARACTER.test(value) || value.trim() === "") return null;
  return [...value].length <= longest ? value : null;
}

const isCoordinate = (value, limit) => typeof value === "number" && Number.isFinite(value) && value >= -limit && value <= limit;

// The first fault of a lookup after the keys are checked, as an error name, or null: field, text and the shape of `near`
// come first, then the keys of `near`, a missing key, a bad value. `fieldKeys` are the partner's lookup-marked fields.
export function lookupFault(request, fieldKeys) {
  if (!fieldKeys.includes(request.field)) return "invalid_field";
  if (cleanText(request.text, MAX_LOOKUP_CHARS, MIN_LOOKUP_CHARS) === null) return "invalid_field";
  if (!hasOwn(request, "near")) return null;
  const near = request.near;
  if (near === null || typeof near !== "object" || Array.isArray(near)) return "invalid_field";
  if (Object.keys(near).some((key) => !NEAR_KEYS.includes(key))) return "unknown_field";
  if (!NEAR_KEYS.every((key) => hasOwn(near, key))) return "missing_field";
  return isCoordinate(near.latitude, 90) && isCoordinate(near.longitude, 180) ? null : "invalid_field";
}

// One result of the upstream, as the app reads a candidate: anything else about it makes it unusable, and only it.
export function candidateOf(result) {
  if (result === null || typeof result !== "object" || Array.isArray(result)) return null;
  const name = soundText(result.displayName?.text, MAX_CANDIDATE_NAME_CHARS);
  const address = soundText(result.formattedAddress, MAX_CANDIDATE_ADDRESS_CHARS);
  const latitude = result.location?.latitude;
  const longitude = result.location?.longitude;
  if (name === null || address === null || !isCoordinate(latitude, 90) || !isCoordinate(longitude, 180)) return null;
  return { name, address, location: { latitude, longitude } };
}

// The answer to a valid lookup. `lookup` is handed in and says what happened: { outcome: "ok", body } with the upstream's
// JSON, { outcome: "no_key" } or { outcome: "failed" }; nothing the upstream said is passed on except the usable results.
export async function lookupAnswer(request, lookup, json, partner) {
  const found = await lookup({ text: request.text.trim(), near: request.near });
  if (found?.outcome === "no_key") return json(503, { error: "google_key_not_configured" });
  const body = found?.body;
  if (found?.outcome !== "ok" || body === null || typeof body !== "object" || Array.isArray(body)) {
    return json(502, { error: "upstream_failed" });
  }
  const results = body.places ?? [];
  if (!Array.isArray(results)) return json(502, { error: "upstream_failed" });
  const candidates = results.map(candidateOf).filter((candidate) => candidate !== null).slice(0, MAX_CANDIDATES);
  return json(200, { partner, simulated: true, field: request.field, candidates });
}
