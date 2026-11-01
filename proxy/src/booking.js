// POST /booking: a simulated table-booking partner. It has no storage and no log line, and one upstream, for
// {"op":"lookup"} only: that call is handed in by index.js, so this file holds no outgoing call and no key.
// The lookup rule itself lives in lookup.js, shared with the other partner routes, so every partner answers alike.
// Apart from the lookup the answer is computed from the request alone, so nothing personal can be kept.
// Three requests: {"op":"fields"} names the form and the result items; {"op":"submit", request_id, values} acts on the form;
// {"op":"lookup", field, text, near?} lists the restaurants the partner finds for the typed text.
import { lookupFault, lookupAnswer } from "./lookup.js";

const PARTNER = "Example Tables";
const MAX_BODY_CHARS = 4096;
const ALL_KEYS = ["op", "request_id", "values", "field", "text", "near"];
const KEYS_BY_OP = {
  fields: ["op"],
  submit: ["op", "request_id", "values"],
  lookup: ["op", "field", "text", "near"],
};
const REQUIRED_KEYS_BY_OP = {
  fields: ["op"],
  submit: ["op", "request_id", "values"],
  lookup: ["op", "field", "text"],
};
const CANCEL_KEYS = ["op", "request_id"];
const VALUE_KEYS = ["restaurant", "party_size", "start", "name", "note"];
const REQUIRED_VALUE_KEYS = ["restaurant", "party_size", "start", "name"];
// The form, in the order the app draws it. Only `note` is optional; a marker (`optional`, `lookup`) is written last,
// and no field carries both. `lookup` marks the place fields the partner resolves itself.
const BOOKING_FIELDS = [
  { key: "restaurant", kind: "place", label: "Restaurant", lookup: true },
  { key: "party_size", kind: "number", label: "Party size" },
  { key: "start", kind: "time", label: "Time" },
  { key: "name", kind: "text", label: "Name" },
  { key: "note", kind: "text", label: "Note", optional: true },
];
// What a confirmed answer will hold, announced before the card is drawn; the answer repeats these names and kinds.
const RESULT_FIELDS = [
  { name: "Booking time", kind: "time" },
  { name: "Reservation number", kind: "text" },
  { name: "Estimated cost", kind: "money" },
  { name: "Partner note", kind: "text" },
];
const LARGEST_PARTY_WE_SEAT = 8;
const LARGEST_PARTY_ASKED = 12;
const ESTIMATE_PER_PERSON_CENTS = 3000;
const MAX_TEXT_CHARS = 120;
// The fields a lookup may name: the lookup-marked entries of the form, so the list and the check cannot diverge.
const LOOKUP_FIELD_KEYS = BOOKING_FIELDS.filter((field) => field.lookup === true).map((field) => field.key);
const NOTE_TEXT = "Table held for 15 minutes";
const UUID_FORM = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const START_FORM = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;
const HIDDEN_CHARACTER = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

const isLeapYear = (year) => (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;

function daysInMonth(year, month) {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

// The calendar is checked by arithmetic, so the route never reads a clock. The years are 2000 to 2199.
function isRealStart(text) {
  const parts = START_FORM.exec(text);
  if (!parts) return false;
  const [year, month, day, hour, minute] = parts.slice(1).map(Number);
  return (
    year >= 2000 &&
    year <= 2199 &&
    month >= 1 &&
    month <= 12 &&
    day >= 1 &&
    day <= daysInMonth(year, month) &&
    hour <= 23 &&
    minute <= 59
  );
}

// The value as sent may not hold a control, format or line-separator character; then it is trimmed and counted in code points.
function cleanText(value, longest, shortest = 1) {
  if (typeof value !== "string" || HIDDEN_CHARACTER.test(value)) return null;
  const trimmed = value.trim();
  const length = [...trimmed].length;
  return length >= shortest && length <= longest ? trimmed : null;
}

const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

// The values are valid when each one present has the type and range of its field; `note` may be absent.
function valuesAreValid(values) {
  return (
    cleanText(values.restaurant, MAX_TEXT_CHARS) !== null &&
    typeof values.party_size === "number" &&
    Number.isInteger(values.party_size) &&
    values.party_size >= 1 &&
    values.party_size <= LARGEST_PARTY_ASKED &&
    typeof values.start === "string" &&
    isRealStart(values.start) &&
    cleanText(values.name, MAX_TEXT_CHARS) !== null &&
    (!hasOwn(values, "note") || cleanText(values.note, MAX_TEXT_CHARS) !== null)
  );
}

function fieldsAnswer() {
  return {
    partner: PARTNER,
    simulated: true,
    fields: BOOKING_FIELDS.map((field) => ({ ...field })),
    result_fields: RESULT_FIELDS.map((field) => ({ ...field })),
  };
}

// An item of a confirmed answer: the name and kind come from the announced list, so the two cannot diverge.
function resultItem(name, value) {
  const announced = RESULT_FIELDS.find((field) => field.name === name);
  return { name: announced.name, kind: announced.kind, value };
}

async function reservationCode(requestId) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(requestId.toLowerCase()));
  const bytes = new Uint8Array(digest).slice(0, 6);
  return "EX-" + Array.from(bytes, (byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length]).join("");
}

export async function handleBooking(request, { json, lookup }) {
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
  const has = (key) => hasOwn(value, key);
  // (1) a key outside the six, (2) an op that is none of fields, submit, lookup, (3) no op or a key the op needs missing,
  // (4) a key the op does not allow.
  if (Object.keys(value).some((key) => !ALL_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  const knownOp = has("op") && (value.op === "fields" || value.op === "submit" || value.op === "lookup");
  if (has("op") && !knownOp) return json(400, { error: "invalid_field" });
  if (!knownOp || !REQUIRED_KEYS_BY_OP[value.op].every(has)) return json(400, { error: "missing_field" });
  if (Object.keys(value).some((key) => !KEYS_BY_OP[value.op].includes(key))) return json(400, { error: "invalid_field" });

  if (value.op === "fields") return json(200, fieldsAnswer());

  // (4b) field, text, near: a field the partner resolves, a text of 2 to 80 code points, a well-formed `near`.
  if (value.op === "lookup") {
    const fault = lookupFault(value, LOOKUP_FIELD_KEYS);
    return fault === null ? lookupAnswer(value, lookup, json, PARTNER) : json(400, { error: fault });
  }

  // (5) values is an object, (6) it holds only the five keys, (7) the four required keys, (8) types and ranges.
  const values = value.values;
  if (values === null || typeof values !== "object" || Array.isArray(values)) return json(400, { error: "invalid_field" });
  if (Object.keys(values).some((key) => !VALUE_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  if (!REQUIRED_VALUE_KEYS.every((key) => hasOwn(values, key))) return json(400, { error: "missing_field" });
  if (typeof value.request_id !== "string" || !UUID_FORM.test(value.request_id) || !valuesAreValid(values)) {
    return json(400, { error: "invalid_field" });
  }

  if (values.party_size > LARGEST_PARTY_WE_SEAT) {
    return json(200, { status: "declined", partner: PARTNER, simulated: true, reason: "no_table" });
  }
  // Nothing of the free text (`restaurant`, `name`, `note`) is answered: only the start and the amount from the party size.
  return json(200, {
    status: "confirmed",
    partner: PARTNER,
    simulated: true,
    results: [
      resultItem("Booking time", values.start),
      resultItem("Reservation number", await reservationCode(value.request_id)),
      resultItem("Estimated cost", values.party_size * ESTIMATE_PER_PERSON_CENTS),
      resultItem("Partner note", NOTE_TEXT),
    ],
  });
}

// POST /booking/cancel: a simulated cancellation. Nothing is kept or looked up, so any well-formed request is answered
// `cancelled`, the same every time. The faults come in this order: the length, JSON, an object, a key outside the two,
// a missing key, a bad value.
export async function handleBookingCancel(request, { json }) {
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
  if (Object.keys(value).some((key) => !CANCEL_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  if (!CANCEL_KEYS.every((key) => hasOwn(value, key))) return json(400, { error: "missing_field" });
  if (value.op !== "cancel" || typeof value.request_id !== "string" || !UUID_FORM.test(value.request_id)) {
    return json(400, { error: "invalid_field" });
  }
  return json(200, { status: "cancelled", partner: PARTNER, simulated: true });
}
