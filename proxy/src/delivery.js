// POST /delivery: a simulated food-delivery partner. It has no upstream, no storage and no log line:
// the answer is computed from the request alone, so nothing personal can be kept.
const PARTNER = "Example Delivery";
const MAX_BODY_CHARS = 4096;
const ALL_KEYS = ["op", "request_id", "restaurant", "arrive_at", "items", "address", "card_id"];
const KEYS_BY_OP = {
  options: ["op"],
  order: ALL_KEYS,
};
const OPEN_MINUTE = 600;
const CLOSE_MINUTE = 1320;
// The partner's fixed tables: the one place the menu, the cards and the fee exist.
const MENU = [
  { id: "ramen", name: "Ramen", price_cents: 1400 },
  { id: "gyoza", name: "Gyoza", price_cents: 700 },
  { id: "curry", name: "Curry rice", price_cents: 1300 },
  { id: "pizza", name: "Cheese pizza", price_cents: 2500 },
  { id: "salad", name: "Garden salad", price_cents: 900 },
  { id: "lemonade", name: "Lemonade", price_cents: 400 },
];
const CARDS = [
  { id: "debit-4242", label: "Example Debit \u2022\u20224242 (Simulated)" },
  { id: "credit-1881", label: "Example Credit \u2022\u20221881 (Simulated)" },
];
const FEE_CENTS = 500;
// The fields of an order, in the order the app draws them. The options of the card field are built from CARDS,
// the table the order check reads, so the options and the accepted cards cannot diverge.
const ORDER_FIELDS = [
  { key: "arrive_at", kind: "time", label: "Arrival" },
  { key: "address", kind: "place", label: "Delivery place" },
  { key: "card_id", kind: "pick_one", label: "Pay with", options: CARDS.map(({ id, label }) => ({ id, label })) },
];
const MAX_LINES = 6;
const MAX_QUANTITY = 9;
const SALT = "delivery:";
const UUID_FORM = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const ARRIVAL_FORM = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;
const HIDDEN_CHARACTER = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

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

const cleanRestaurant = (value) => cleanText(value, 80);
const cleanAddress = (value) => cleanText(value, 120);

const menuEntry = (id) => MENU.find((entry) => entry.id === id);
const cardIsKnown = (id) => CARDS.some((card) => card.id === id);

// Each line holds exactly an item of the menu and a whole quantity; no item is repeated.
function validItems(items) {
  if (!Array.isArray(items) || items.length < 1 || items.length > MAX_LINES) return false;
  const seen = new Set();
  for (const line of items) {
    if (line === null || typeof line !== "object" || Array.isArray(line)) return false;
    const keys = Object.keys(line);
    if (keys.length !== 2 || !keys.includes("item_id") || !keys.includes("quantity")) return false;
    if (typeof line.item_id !== "string" || menuEntry(line.item_id) === undefined || seen.has(line.item_id)) return false;
    seen.add(line.item_id);
    if (typeof line.quantity !== "number" || !Number.isInteger(line.quantity)) return false;
    if (line.quantity < 1 || line.quantity > MAX_QUANTITY) return false;
  }
  return true;
}

function valuesAreValid(value) {
  if (value.op === "options") return true;
  return (
    typeof value.request_id === "string" &&
    UUID_FORM.test(value.request_id) &&
    cleanRestaurant(value.restaurant) !== null &&
    typeof value.arrive_at === "string" &&
    minuteOfDay(value.arrive_at) !== null &&
    validItems(value.items) &&
    cleanAddress(value.address) !== null &&
    typeof value.card_id === "string" &&
    cardIsKnown(value.card_id)
  );
}

function optionsAnswer() {
  return {
    partner: PARTNER,
    simulated: true,
    menu: MENU.map(({ id, name, price_cents }) => ({ id, name, price_cents })),
    delivery_fee_cents: FEE_CENTS,
    order_fields: ORDER_FIELDS.map((field) => ({
      ...field,
      ...(field.options && { options: field.options.map(({ id, label }) => ({ id, label })) }),
    })),
  };
}

// The total is the sum of price times quantity over the lines, plus the delivery fee.
const totalCents = (items) =>
  items.reduce((sum, line) => sum + menuEntry(line.item_id).price_cents * line.quantity, FEE_CENTS);

async function orderId(requestId) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(SALT + requestId.toLowerCase()));
  const bytes = new Uint8Array(digest).slice(0, 6);
  return "DL-" + Array.from(bytes, (byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length]).join("");
}

export async function handleDelivery(request, { json }) {
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
  if (Object.keys(value).some((key) => !ALL_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  const knownOp = has("op") && (value.op === "options" || value.op === "order");
  if (has("op") && !knownOp) return json(400, { error: "invalid_field" });
  if (!knownOp || !KEYS_BY_OP[value.op].every(has)) return json(400, { error: "missing_field" });
  if (Object.keys(value).some((key) => !KEYS_BY_OP[value.op].includes(key))) return json(400, { error: "invalid_field" });
  if (!valuesAreValid(value)) return json(400, { error: "invalid_field" });

  if (value.op === "options") return json(200, optionsAnswer());

  const items = value.items.map(({ item_id, quantity }) => ({ item_id, quantity }));
  const answer = {
    partner: PARTNER,
    simulated: true,
    restaurant: cleanRestaurant(value.restaurant),
    arrive_at: value.arrive_at,
    items,
    address: cleanAddress(value.address),
    card_id: value.card_id,
  };
  const minute = minuteOfDay(value.arrive_at);
  if (minute < OPEN_MINUTE || minute > CLOSE_MINUTE) {
    return json(200, { status: "declined", ...answer, reason: "outside_hours" });
  }
  return json(200, {
    status: "confirmed",
    ...answer,
    order_id: await orderId(value.request_id),
    results: [
      { name: "Arrival", kind: "time", value: value.arrive_at },
      { name: "Estimated total", kind: "money", value: totalCents(items) },
      { name: "Status", kind: "text", value: "Preparing" },
    ],
  });
}
