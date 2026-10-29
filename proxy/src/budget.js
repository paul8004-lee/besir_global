// POST /budget: a simulated budget partner. It has no upstream, no storage and no log line:
// the answer is computed from the request alone, so nothing personal can be kept.
const PARTNER = "Example Budget";
const WEEKLY_BUDGET_CENTS = 20000;
const MAX_BODY_CHARS = 4096;
const ALL_KEYS = ["op", "week_start", "spent_cents", "amount_cents", "request_id"];
const KEYS_BY_OP = {
  left: ["op", "week_start", "spent_cents"],
  spend: ["op", "week_start", "spent_cents", "amount_cents", "request_id"],
};
const UUID_FORM = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const WEEK_FORM = /^(\d{4})-(\d{2})-(\d{2})$/;

const isLeapYear = (year) => (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;

function daysInMonth(year, month) {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

// The calendar is checked by arithmetic, so the route never reads a clock.
function isRealDate(text) {
  const parts = WEEK_FORM.exec(text);
  if (!parts) return false;
  const [year, month, day] = parts.slice(1).map(Number);
  return year >= 2000 && year <= 2199 && month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth(year, month);
}

const isWholeNumberIn = (value, low, high) =>
  typeof value === "number" && Number.isInteger(value) && value >= low && value <= high;

function valuesAreValid(value) {
  if (typeof value.week_start !== "string" || !isRealDate(value.week_start)) return false;
  if (!isWholeNumberIn(value.spent_cents, 0, 1000000000)) return false;
  if (value.op === "left") return true;
  return (
    isWholeNumberIn(value.amount_cents, 1, 100000000) &&
    typeof value.request_id === "string" &&
    UUID_FORM.test(value.request_id)
  );
}

export async function handleBudget(request, { json }) {
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
  const knownOp = has("op") && (value.op === "left" || value.op === "spend");
  if (has("op") && !knownOp) return json(400, { error: "invalid_field" });
  if (!knownOp || !KEYS_BY_OP[value.op].every(has)) return json(400, { error: "missing_field" });
  if (Object.keys(value).some((key) => !KEYS_BY_OP[value.op].includes(key))) return json(400, { error: "invalid_field" });
  if (!valuesAreValid(value)) return json(400, { error: "invalid_field" });

  const isSpend = value.op === "spend";
  const spent = isSpend ? value.spent_cents + value.amount_cents : value.spent_cents;
  const leftCents = WEEKLY_BUDGET_CENTS - spent;
  const answer = {
    partner: PARTNER,
    simulated: true,
    op: value.op,
    week_start: value.week_start,
    spent_cents: spent,
    budget_cents: WEEKLY_BUDGET_CENTS,
    left_cents: leftCents,
    status: leftCents >= 0 ? "within" : "over",
  };
  if (isSpend) answer.amount_cents = value.amount_cents;
  return json(200, answer);
}
