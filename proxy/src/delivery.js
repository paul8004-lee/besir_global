// POST /delivery: a simulated food-delivery partner. It has no storage and no log line, and one upstream, for
// {"op":"lookup"} only: that call is handed in by index.js, so this file holds no outgoing call and no key.
// The lookup rule itself lives in lookup.js, shared with the other partner routes.
// Three requests: {"op":"fields"} names the form and the result items; {"op":"submit", request_id, values} takes the order;
// {"op":"lookup", field, text, near?} lists the addresses the partner finds for the typed text.
import { lookupFault, lookupAnswer } from "./lookup.js";

const PARTNER = "Example Delivery";
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
const VALUE_KEYS = ["restaurant", "items", "arrive_at", "address", "card_id"];
const ROW_KEYS = ["item", "quantity"];
const OPEN_MINUTE = 600;
const CLOSE_MINUTE = 1320;
// The partner's fixed tables: the one place the menu, the cards and the fee exist. The menu prices never reach the wire.
const MENU = [
  { id: "ramen", name: "Ramen", price_cents: 1400 },
  { id: "gyoza", name: "Gyoza", price_cents: 700 },
  { id: "curry", name: "Curry rice", price_cents: 1300 },
  { id: "pizza", name: "Cheese pizza", price_cents: 2500 },
  { id: "salad", name: "Garden salad", price_cents: 900 },
  { id: "lemonade", name: "Lemonade", price_cents: 400 },
];
const CARDS = [
  { id: "debit-4242", label: "Example Debit ••4242 (Simulated)" },
  { id: "credit-1881", label: "Example Credit ••1881 (Simulated)" },
];
const FEE_CENTS = 500;
// The form, in the order the app draws it. Only `address` is marked for lookup (the marker is written last), and the
// options of the item and card fields are built from the tables the submit check reads, so they cannot diverge.
const DELIVERY_FIELDS = [
  { key: "restaurant", kind: "text", label: "Restaurant" },
  {
    key: "items",
    kind: "group",
    label: "Items",
    fields: [
      { key: "item", kind: "pick_one", label: "Item", options: MENU.map(({ id, name }) => ({ id, label: name })) },
      { key: "quantity", kind: "number", label: "Quantity" },
    ],
    repeat: 6,
  },
  { key: "arrive_at", kind: "time", label: "Arrival" },
  { key: "address", kind: "place", label: "Delivery place", lookup: true },
  { key: "card_id", kind: "pick_one", label: "Pay with", options: CARDS.map(({ id, label }) => ({ id, label })) },
];
// What a confirmed answer will hold, announced before the card is drawn; the answer repeats these names and kinds.
const RESULT_FIELDS = [
  { name: "Arrival", kind: "time" },
  { name: "Order number", kind: "text" },
  { name: "Estimated total", kind: "money" },
  { name: "Status", kind: "text" },
];
// The fields a lookup may name: the lookup-marked entries of the form, so the list and the check cannot diverge.
const LOOKUP_FIELD_KEYS = DELIVERY_FIELDS.filter((field) => field.lookup === true).map((field) => field.key);
const MIN_ROWS = 1;
const MAX_ROWS = 6;
const MIN_QUANTITY = 1;
const MAX_QUANTITY = 9;
const MAX_TEXT_CHARS = 120;
const SALT = "delivery:";
const UUID_FORM = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const ARRIVAL_FORM = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;
const HIDDEN_CHARACTER = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

const isLeapYear = (year) => (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;

function daysInMonth(year, month) {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

// The calendar is checked by arithmetic, so the route never reads a clock.
// Returns the minute of the day for a real date-time (year 2000 to 2199), otherwise null.
function minuteOfDay(text) {
  const parts = ARRIVAL_FORM.exec(text);
  if (!parts) return null;
  const [year, month, day, hour, minute] = parts.slice(1).map(Number);
  const real =
    year >= 2000 &&
    year <= 2199 &&
    month >= 1 &&
    month <= 12 &&
    day >= 1 &&
    day <= daysInMonth(year, month) &&
    hour <= 23 &&
    minute <= 59;
  return real ? hour * 60 + minute : null;
}

// The value as sent may not hold a control, format or line-separator character; then it is trimmed and counted in code points.
function cleanText(value, longest) {
  if (typeof value !== "string" || HIDDEN_CHARACTER.test(value)) return null;
  const trimmed = value.trim();
  const length = [...trimmed].length;
  return length >= 1 && length <= longest ? trimmed : null;
}

const menuEntry = (id) => MENU.find((entry) => entry.id === id);
const cardIsKnown = (id) => CARDS.some((card) => card.id === id);

// The rows of the group: each row holds exactly an item of the menu and a JSON number with a whole value. The range of
// a whole quantity is the partner's business answer (a decline), not a fault of the request, so it is checked later;
// two rows may name the same item, because each row is priced.
function rowsAreWellFormed(rows) {
  if (!Array.isArray(rows) || rows.length < MIN_ROWS || rows.length > MAX_ROWS) return false;
  for (const row of rows) {
    if (row === null || typeof row !== "object" || Array.isArray(row)) return false;
    const keys = Object.keys(row);
    if (keys.length !== 2 || !keys.every((key) => ROW_KEYS.includes(key))) return false;
    if (typeof row.item !== "string" || menuEntry(row.item) === undefined) return false;
    if (typeof row.quantity !== "number" || !Number.isInteger(row.quantity)) return false;
  }
  return true;
}

// The values are well formed when each one holds the type of its field; the ranges that are the partner's business
// answer (the hours and the quantity range) are not read here.
function valuesAreWellFormed(values) {
  return (
    cleanText(values.restaurant, MAX_TEXT_CHARS) !== null &&
    rowsAreWellFormed(values.items) &&
    typeof values.arrive_at === "string" &&
    minuteOfDay(values.arrive_at) !== null &&
    cleanText(values.address, MAX_TEXT_CHARS) !== null &&
    typeof values.card_id === "string" &&
    cardIsKnown(values.card_id)
  );
}

function fieldsAnswer() {
  return {
    partner: PARTNER,
    simulated: true,
    fields: DELIVERY_FIELDS.map(copyField),
    result_fields: RESULT_FIELDS.map((field) => ({ ...field })),
  };
}

// A copy of a field, one level deeper than a spread so the group's members and the options are fresh objects too.
function copyField(field) {
  const copy = { ...field };
  if (Array.isArray(copy.options)) copy.options = copy.options.map((option) => ({ ...option }));
  if (Array.isArray(copy.fields)) copy.fields = copy.fields.map(copyField);
  return copy;
}

// An item of a confirmed answer: the name and kind come from the announced list, so the two cannot diverge.
function resultItem(name, value) {
  const announced = RESULT_FIELDS.find((field) => field.name === name);
  return { name: announced.name, kind: announced.kind, value };
}

// The total is the sum of price times quantity over the rows, plus the delivery fee.
const totalCents = (rows) => rows.reduce((sum, row) => sum + menuEntry(row.item).price_cents * row.quantity, FEE_CENTS);

async function orderNumber(requestId) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(SALT + requestId.toLowerCase()));
  const bytes = new Uint8Array(digest).slice(0, 6);
  return "DL-" + Array.from(bytes, (byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length]).join("");
}

export async function handleDelivery(request, { json, lookup }) {
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

  // (5) values is an object, (5b) items, when present, is an array of 1 to 6 row objects, (6) the keys of values and of
  // each row, (7) the required keys of values and of each row, (8) the types. The keys of the values come first, then
  // the rows in order.
  const values = value.values;
  if (values === null || typeof values !== "object" || Array.isArray(values)) return json(400, { error: "invalid_field" });
  if (hasOwn(values, "items")) {
    const rows = values.items;
    const wellShaped =
      Array.isArray(rows) &&
      rows.length >= MIN_ROWS &&
      rows.length <= MAX_ROWS &&
      rows.every((row) => row !== null && typeof row === "object" && !Array.isArray(row));
    if (!wellShaped) return json(400, { error: "invalid_field" });
  }
  if (Object.keys(values).some((key) => !VALUE_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  for (const row of values.items ?? []) {
    if (Object.keys(row).some((key) => !ROW_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  }
  if (!VALUE_KEYS.every((key) => hasOwn(values, key))) return json(400, { error: "missing_field" });
  for (const row of values.items) {
    if (!ROW_KEYS.every((key) => hasOwn(row, key))) return json(400, { error: "missing_field" });
  }
  if (typeof value.request_id !== "string" || !UUID_FORM.test(value.request_id) || !valuesAreWellFormed(values)) {
    return json(400, { error: "invalid_field" });
  }

  // The business answers: the hours first, then the quantity range. Nothing the user typed is echoed.
  const minute = minuteOfDay(values.arrive_at);
  if (minute < OPEN_MINUTE || minute > CLOSE_MINUTE) {
    return json(200, { status: "declined", partner: PARTNER, simulated: true, reason: "outside_hours" });
  }
  if (values.items.some((row) => row.quantity < MIN_QUANTITY || row.quantity > MAX_QUANTITY)) {
    return json(200, { status: "declined", partner: PARTNER, simulated: true, reason: "quantity_out_of_range" });
  }
  return json(200, {
    status: "confirmed",
    partner: PARTNER,
    simulated: true,
    results: [
      resultItem("Arrival", values.arrive_at),
      resultItem("Order number", await orderNumber(value.request_id)),
      resultItem("Estimated total", totalCents(values.items)),
      resultItem("Status", "Preparing"),
    ],
  });
}
