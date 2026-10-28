// POST /booking: a simulated table-booking partner. It has no upstream, no storage and no log line:
// the answer is computed from the request alone, so nothing personal can be kept.
const PARTNER = "Example Tables";
const MAX_BODY_CHARS = 4096;
const KEYS = ["request_id", "restaurant", "party_size", "start"];
const LARGEST_PARTY_WE_SEAT = 8;
const UUID_FORM = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const START_FORM = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;
const HIDDEN_CHARACTER = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

const isLeapYear = (year) => (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;

function daysInMonth(year, month) {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

// The calendar is checked by arithmetic, so the route never reads a clock.
function isRealStart(text) {
  const parts = START_FORM.exec(text);
  if (!parts) return false;
  const [year, month, day, hour, minute] = parts.slice(1).map(Number);
  return month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth(year, month) && hour <= 23 && minute <= 59;
}

// The value as sent may not hold a control, format or line-separator character; then it is trimmed and counted in code points.
function cleanRestaurant(value) {
  if (typeof value !== "string" || HIDDEN_CHARACTER.test(value)) return null;
  const trimmed = value.trim();
  const length = [...trimmed].length;
  return length >= 1 && length <= 80 ? trimmed : null;
}

function valuesAreValid(value) {
  return (
    typeof value.request_id === "string" &&
    UUID_FORM.test(value.request_id) &&
    cleanRestaurant(value.restaurant) !== null &&
    typeof value.party_size === "number" &&
    Number.isInteger(value.party_size) &&
    value.party_size >= 1 &&
    value.party_size <= 12 &&
    typeof value.start === "string" &&
    isRealStart(value.start)
  );
}

async function reservationCode(requestId) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(requestId.toLowerCase()));
  const bytes = new Uint8Array(digest).slice(0, 6);
  return "EX-" + Array.from(bytes, (byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length]).join("");
}

export async function handleBooking(request, { json }) {
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
  const has = (key) => Object.prototype.hasOwnProperty.call(value, key);
  if (Object.keys(value).some((key) => !KEYS.includes(key))) return json(400, { error: "unknown_field" });
  if (!KEYS.every(has)) return json(400, { error: "missing_field" });
  if (!valuesAreValid(value)) return json(400, { error: "invalid_field" });

  const answer = {
    partner: PARTNER,
    simulated: true,
    restaurant: cleanRestaurant(value.restaurant),
    party_size: value.party_size,
    start: value.start,
  };
  if (value.party_size > LARGEST_PARTY_WE_SEAT) {
    return json(200, { status: "declined", ...answer, reason: "no_table" });
  }
  return json(200, { status: "confirmed", ...answer, reservation_code: await reservationCode(value.request_id) });
}
