import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: "g" };
const envWithoutKey = { APP_TOKEN: "app-test", META_API_KEY: "m" };
const ID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b";
const ID2 = "9a1d4c7e-2b3f-4a50-8c61-7d8e9f0a1b2c";

// The partner's fixed tables, written out here on purpose: the route and the test do not share them.
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
const FEE = 500;
const PRICE = Object.fromEntries(MENU.map((entry) => [entry.id, entry.price_cents]));

// The form the fields answer holds, written out here on purpose, in the partner's order and with the key order of the contract.
const FIELDS = [
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
const RESULT_FIELDS = [
  { name: "Arrival", kind: "time" },
  { name: "Order number", kind: "text" },
  { name: "Estimated total", kind: "money" },
  { name: "Status", kind: "text" },
];

const BASE_VALUES = {
  restaurant: "Test Cafe",
  items: [{ item: "ramen", quantity: 2 }],
  arrive_at: "2026-11-02T19:40",
  address: "12 Test Street",
  card_id: "debit-4242",
};
const values = (over = {}) => ({ ...BASE_VALUES, ...over });
const submit = (over = {}) => ({ op: "submit", request_id: ID, values: values(), ...over });
const submitValues = (over) => submit({ values: values(over) });
const drop = (object, ...keys) => Object.fromEntries(Object.entries(object).filter(([key]) => !keys.includes(key)));

// The order number of a confirmed answer, computed here from the rule the route has kept: SHA-256 of
// "delivery:" and the lower-cased request id, six bytes, each mod 36 over A-Z0-9.
async function expectedCode(requestId) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("delivery:" + requestId.toLowerCase()));
  const bytes = new Uint8Array(digest).slice(0, 6);
  return "DL-" + Array.from(bytes, (byte) => "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"[byte % 36]).join("");
}

// The money item of a confirmed answer.
const totalOf = (body) => body.results.find((item) => item.name === "Estimated total").value;

// A body object is JSON-encoded; `raw` sends the string as it is.
const call = (body, { token = "app-test", raw, method = "POST", e = env, path = "/delivery" } = {}) =>
  worker.fetch(
    new Request(`https://x.test${path}`, {
      method,
      headers: { "x-besir-token": token },
      body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
    }),
    e,
  );

async function expectError(res, status, error) {
  assert.equal(res.status, status);
  assert.deepEqual(await res.json(), { error });
}

const realFetch = globalThis.fetch;

test("AC-DELIVERYCARD-014 D01: 401 for no token, a wrong token and no APP_TOKEN, before the body is read", async () => {
  const unreadable = (token) => ({
    method: "POST",
    url: "https://x.test/delivery",
    headers: new Headers(token === null ? {} : { "x-besir-token": token }),
    text: async () => {
      throw new Error("the body must not be read");
    },
  });
  await expectError(await worker.fetch(unreadable(null), env), 401, "unauthorized");
  await expectError(await worker.fetch(unreadable("nope"), env), 401, "unauthorized");
  await expectError(await worker.fetch(unreadable("app-test"), { ...env, APP_TOKEN: undefined }), 401, "unauthorized");
  await expectError(await worker.fetch(unreadable("app-test"), { ...env, APP_TOKEN: "" }), 401, "unauthorized");
  // Positive counterpart: the right token reaches the body.
  await assert.rejects(worker.fetch(unreadable("app-test"), env), /must not be read/);
});

test("AC-DELIVERYCARD-014 D02: a non-POST is 405 and the other routes still answer 401 to a bad token", async () => {
  for (const method of ["GET", "PUT", "DELETE"]) {
    await expectError(await call(null, { method }), 405, "method_not_allowed");
  }
  for (const path of ["/ai", "/places", "/routes", "/vision", "/booking", "/budget", "/delivery"]) {
    const res = await worker.fetch(
      new Request(`https://x.test${path}`, { method: "POST", headers: { "x-besir-token": "nope" }, body: "{}" }),
      env,
    );
    await expectError(res, 401, "unauthorized");
  }
});

test("AC-DELIVERYCARD-002 D03: the fields answer holds exactly four keys, the five fields and the four result items", async () => {
  const res = await call({ op: "fields" });
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.deepEqual(Object.keys(body), ["partner", "simulated", "fields", "result_fields"]);
  assert.equal(body.partner, "Example Delivery");
  assert.equal(body.simulated, true);
  assert.deepEqual(body.fields.map((field) => field.key), ["restaurant", "items", "arrive_at", "address", "card_id"]);
  assert.deepEqual(body.fields, FIELDS);
  // The key order of every field shape, including the group and its members.
  assert.deepEqual(Object.keys(body.fields[0]), ["key", "kind", "label"]);
  assert.deepEqual(Object.keys(body.fields[1]), ["key", "kind", "label", "fields", "repeat"]);
  assert.deepEqual(Object.keys(body.fields[1].fields[0]), ["key", "kind", "label", "options"]);
  assert.deepEqual(Object.keys(body.fields[1].fields[1]), ["key", "kind", "label"]);
  assert.deepEqual(Object.keys(body.fields[3]), ["key", "kind", "label", "lookup"]);
  assert.deepEqual(Object.keys(body.fields[4]), ["key", "kind", "label", "options"]);
  assert.equal(body.fields[1].repeat, 6);
  assert.deepEqual(body.fields[1].fields[0].options, MENU.map(({ id, name }) => ({ id, label: name })));
  assert.deepEqual(body.fields[4].options, CARDS);
  assert.deepEqual(body.result_fields, RESULT_FIELDS);
  assert.deepEqual(Object.keys(body.result_fields[0]), ["name", "kind"]);
  // No key anywhere holds a price, a fee or a total.
  const keyProblems = [];
  const walkKeys = (value, path) => {
    if (Array.isArray(value)) {
      value.forEach((item, index) => walkKeys(item, `${path}[${index}]`));
      return;
    }
    if (value !== null && typeof value === "object") {
      for (const [key, inner] of Object.entries(value)) {
        if (/price|fee|total/i.test(key)) keyProblems.push(`${path}.${key}`);
        walkKeys(inner, `${path}.${key}`);
      }
    }
  };
  walkKeys(body, "");
  assert.deepEqual(keyProblems, []);
  // The same text every time.
  const text = await (await call({ op: "fields" })).text();
  assert.equal(text, JSON.stringify(body));
});

// An independent statement of the field grammar (SPEC-GROUPFIELD-001 v0.3.1): nothing here is imported from the route.
const HIDDEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const SCALAR_KINDS = ["text", "place", "time", "pick_one", "on_off", "number"];
const MEMBER_KINDS = ["text", "number", "pick_one"];
const codePoints = (text) => [...text].length;
const plain = (text, longest) => typeof text === "string" && !HIDDEN.test(text) && codePoints(text) >= 1 && codePoints(text) <= longest;
const plainObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const keyForm = (key) => typeof key === "string" && /^[a-z_]{1,32}$/.test(key);

function optionDefects(field) {
  const defects = [];
  const options = field.options;
  if (!Array.isArray(options) || options.length < 1) return [`${field.key}: options missing`];
  for (const option of options) {
    if (!plainObject(option) || JSON.stringify(Object.keys(option).sort()) !== '["id","label"]') {
      defects.push(`${field.key}: option keys`);
    } else {
      if (!plain(option.label, 60)) defects.push(`${field.key}: option label`);
      if (typeof option.id !== "string" || !/^[a-z0-9_-]{1,32}$/.test(option.id)) defects.push(`${field.key}: option id`);
    }
  }
  if (defects.length > 0) return defects;
  const ids = options.map((option) => option.id);
  if (new Set(ids).size !== ids.length) defects.push(`${field.key}: option id repeated`);
  if (field.kind === "on_off") {
    if (JSON.stringify(ids) !== '["true","false"]') defects.push(`${field.key}: on_off ids`);
    if (options.length === 2 && options[0].label === options[1].label) defects.push(`${field.key}: on_off labels`);
  }
  return defects;
}

// One scalar field: `kinds` says which kinds are allowed here (a group member allows fewer than a top-level entry).
function scalarDefects(field, kinds, seen) {
  const defects = [];
  const names = Object.keys(field);
  const withOptions = field.kind === "pick_one" || field.kind === "on_off";
  const base = withOptions ? ["key", "kind", "label", "options"] : ["key", "kind", "label"];
  const markers = names.filter((name) => name === "optional" || name === "lookup");
  if (names.includes("optional") && names.includes("lookup")) defects.push(`${field.key}: optional beside lookup`);
  if (names.slice(0, names.length - markers.length).join() !== base.join()) defects.push(`${field.key}: keys`);
  if (names.slice(0, names.length - markers.length).join() === base.join() && markers.length > 0) {
    // A marker must be the trailing key, and exactly the boolean true.
    for (const marker of markers) {
      if (names[names.length - 1] !== marker && names[names.length - 2] !== marker) defects.push(`${field.key}: marker not last`);
    }
  }
  if (markers.includes("lookup") && (field.lookup !== true || field.kind !== "place")) defects.push(`${field.key}: lookup`);
  if (markers.includes("optional") && field.optional !== true) defects.push(`${field.key}: optional`);
  if (!keyForm(field.key)) defects.push(`${field.key}: key form`);
  if (seen.has(field.key)) defects.push(`${field.key}: key repeated`);
  seen.add(field.key);
  if (!kinds.includes(field.kind)) defects.push(`${field.key}: kind`);
  if (!plain(field.label, 40)) defects.push(`${field.key}: label`);
  if (withOptions) defects.push(...optionDefects(field));
  return defects;
}

function fieldListDefects(fields) {
  if (!Array.isArray(fields) || fields.length < 1 || fields.length > 8) return ["field count"];
  const defects = [];
  const seen = new Set();
  for (const field of fields) {
    if (!plainObject(field)) {
      defects.push("field is not an object");
      continue;
    }
    if (field.kind === "group") {
      if (JSON.stringify(Object.keys(field)) !== JSON.stringify(["key", "kind", "label", "fields", "repeat"])) {
        defects.push(`${field.key}: group keys`);
      }
      if (!keyForm(field.key)) defects.push(`${field.key}: key form`);
      if (seen.has(field.key)) defects.push(`${field.key}: key repeated`);
      seen.add(field.key);
      if (!plain(field.label, 40)) defects.push(`${field.key}: label`);
      const repeat = field.repeat;
      if (typeof repeat !== "number" || !Number.isInteger(repeat) || repeat < 1 || repeat >= 1e12) {
        defects.push(`${field.key}: repeat`);
      }
      if (!Array.isArray(field.fields) || field.fields.length < 1) {
        defects.push(`${field.key}: members missing`);
        continue;
      }
      let optional = 0;
      for (const member of field.fields) {
        if (plainObject(member) && member.optional === true) optional += 1;
        if (!plainObject(member)) {
          defects.push(`${field.key}: member is not an object`);
          continue;
        }
        defects.push(...scalarDefects(member, MEMBER_KINDS, seen));
      }
      if (optional === field.fields.length) defects.push(`${field.key}: every member optional`);
    } else {
      defects.push(...scalarDefects(field, SCALAR_KINDS, seen));
    }
  }
  return defects;
}

function resultFieldsDefects(items) {
  if (!Array.isArray(items) || items.length < 1 || items.length > 8) return ["item count"];
  const defects = [];
  for (const item of items) {
    if (!plainObject(item) || JSON.stringify(Object.keys(item)) !== '["name","kind"]') {
      defects.push("item keys");
      continue;
    }
    if (typeof item.name !== "string" || !/^[\x20-\x7e]{1,40}$/.test(item.name)) defects.push(`${item.name}: name`);
    if (![...SCALAR_KINDS, "money"].includes(item.kind)) defects.push(`${item.name}: kind`);
  }
  return defects;
}

test("AC-DELIVERYCARD-002 D04: an independent validator accepts the fields answer and refuses planted defects", async () => {
  // The validator itself: every scalar kind, a group with members and repeat, the trailing markers (eight entries, the cap).
  const entry = (key, kind, extra = {}) => ({ key, kind, label: "L", ...extra });
  const good = [
    entry("note", "text"),
    entry("where", "place", { lookup: true }),
    entry("when", "time"),
    entry("many", "number"),
    { key: "pay", kind: "pick_one", label: "Pay", options: [{ id: "a-1", label: "A" }, { id: "b_2", label: "B" }] },
    { key: "door", kind: "on_off", label: "Leave at door", options: [{ id: "true", label: "Leave" }, { id: "false", label: "Hand over" }] },
    entry("maybe", "text", { optional: true }),
    {
      key: "rows",
      kind: "group",
      label: "Rows",
      fields: [entry("one", "text"), { key: "pick", kind: "pick_one", label: "Pick", options: MENU.map(({ id }) => ({ id, label: id })) }],
      repeat: 6,
    },
  ];
  assert.deepEqual(fieldListDefects(good), []);
  // A pick_one with any count of options from one upward is accepted.
  assert.deepEqual(
    fieldListDefects([entry("pick", "pick_one", { options: [{ id: "only", label: "Only" }] })]),
    [],
  );
  assert.deepEqual(
    fieldListDefects([entry("pick", "pick_one", { options: MENU.map(({ id, name }) => ({ id, label: name })) })]),
    [],
  );
  const group = (over = {}) => ({
    key: "rows",
    kind: "group",
    label: "Rows",
    fields: [{ key: "one", kind: "text", label: "One" }],
    repeat: 2,
    ...over,
  });
  const swapFirst = (list, field) => [field, ...list.slice(1)];
  const planted = [
    ["no field", []],
    ["nine fields", Array.from({ length: 9 }, (_, i) => entry(`f${"i".repeat(i)}${"x".repeat(30)}`.slice(0, 32), "text"))],
    ["an upper-case key", [entry("Door", "text")]],
    ["a key of 33 characters", [entry("a".repeat(33), "text")]],
    ["a kind outside the grammar", [entry("a", "flag")]],
    ["an empty label", [entry("a", "text", { label: "" })]],
    ["a hidden character in the label", [entry("a", "text", { label: "a​b" })]],
    ["a label of 41 characters", [entry("a", "text", { label: "x".repeat(41) })]],
    ["a repeated key", [entry("a", "text"), entry("a", "time")]],
    ["a text field with options", [entry("a", "text", { options: [] })]],
    ["a field with an extra key", [{ key: "a", kind: "text", label: "L", extra: 1 }]],
    ["a pick_one with no options", [entry("a", "pick_one")]],
    ["a pick_one with an empty options list", [entry("a", "pick_one", { options: [] })]],
    ["a repeated option id", [entry("a", "pick_one", { options: [{ id: "x", label: "X" }, { id: "x", label: "Y" }] })]],
    ["an upper-case option id", [entry("a", "pick_one", { options: [{ id: "X", label: "X" }] })]],
    ["an empty option label", [entry("a", "pick_one", { options: [{ id: "x", label: "" }] })]],
    ["an option label of 61 characters", [entry("a", "pick_one", { options: [{ id: "x", label: "y".repeat(61) }] })]],
    ["an option with an extra key", [entry("a", "pick_one", { options: [{ id: "x", label: "X", extra: 1 }] })]],
    ["an on_off with one option", [entry("a", "on_off", { options: [{ id: "true", label: "Yes" }] })]],
    ["an on_off with three options", [entry("a", "on_off", { options: [{ id: "true", label: "A" }, { id: "false", label: "B" }, { id: "x", label: "C" }] })]],
    ["an on_off with wrong ids", [entry("a", "on_off", { options: [{ id: "false", label: "A" }, { id: "true", label: "B" }] })]],
    ["an on_off with equal labels", [entry("a", "on_off", { options: [{ id: "true", label: "Same" }, { id: "false", label: "Same" }] })]],
    ["an optional of false", [entry("a", "text", { optional: false })]],
    ["a lookup on a text field", [entry("a", "text", { lookup: true })]],
    ["a lookup not last", [{ key: "a", kind: "place", lookup: true, label: "L" }]],
    ["a lookup beside an optional", [{ key: "a", kind: "place", label: "L", lookup: true, optional: true }]],
    ["a group without repeat", [{ key: "rows", kind: "group", label: "Rows", fields: [{ key: "one", kind: "text", label: "One" }] }]],
    ["a group with repeat 0", [group({ repeat: 0 })]],
    ["a group with a negative repeat", [group({ repeat: -1 })]],
    ["a group with a fractional repeat", [group({ repeat: 2.5 })]],
    ["a group with a text repeat", [group({ repeat: "2" })]],
    ["a group with a boolean repeat", [group({ repeat: true })]],
    ["a group with a repeat of 10^12", [group({ repeat: 1e12 })]],
    ["a group with an optional marker", [group({ optional: true })]],
    ["a group with a lookup marker", [group({ lookup: true })]],
    ["a group with an extra key", [group({ extra: 1 })]],
    ["a group without members", [group({ fields: [] })]],
    ["a group whose member is a group", [group({ fields: [group({ key: "inner" })] })]],
    ["a group member of kind place", [group({ fields: [{ key: "one", kind: "place", label: "One" }] })]],
    ["a group member with a lookup marker", [group({ fields: [{ key: "one", kind: "text", label: "One", lookup: true }] })]],
    ["a group whose members are all optional", [group({ fields: [{ key: "one", kind: "text", label: "One", optional: true }] })]],
    ["a group key repeated by a member of another field", [{ ...group(), fields: [{ key: "rows", kind: "text", label: "One" }] }]],
    ["a key repeated between a group member and a top-level field", [swapFirst([group()], entry("one", "text"))]],
  ];
  for (const [name, list] of planted) {
    assert.notDeepEqual(fieldListDefects(list), [], `the validator misses ${name}`);
  }
  // The route's own answer passes both validators.
  const body = await (await call({ op: "fields" })).json();
  assert.deepEqual(fieldListDefects(body.fields), []);
  assert.deepEqual(resultFieldsDefects(body.result_fields), []);
  assert.deepEqual(resultFieldsDefects(RESULT_FIELDS), []);
  const badResults = [
    [],
    [{ name: "Arrival", kind: "time", value: "x" }],
    [{ name: "Arrival" }],
    [{ name: "Arrival", kind: "time", extra: 1 }],
    [{ name: "N".repeat(41), kind: "text" }],
    [{ name: "Café", kind: "text" }],
    [{ name: "Note", kind: "flag" }],
    Array.from({ length: 9 }, (_, i) => ({ name: `Note ${i}`, kind: "text" })),
  ];
  for (const list of badResults) {
    assert.notDeepEqual(resultFieldsDefects(list), [], JSON.stringify(list));
  }
});

test("AC-DELIVERYCARD-004 D05: a valid submit gives exactly the four keys and answers by the rule", async () => {
  const res = await call(submitValues({ restaurant: "SENTINEL-RESTAURANT", address: "SENTINEL-ADDRESS" }));
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(Object.keys(body), ["status", "partner", "simulated", "results"]);
  assert.equal(body.status, "confirmed");
  assert.equal(body.partner, "Example Delivery");
  assert.equal(body.simulated, true);
  assert.deepEqual(
    body.results.map(({ name, kind }) => [name, kind]),
    RESULT_FIELDS.map(({ name, kind }) => [name, kind]),
  );
  for (const item of body.results) {
    assert.deepEqual(Object.keys(item), ["name", "kind", "value"]);
  }
  assert.equal(body.results[0].value, "2026-11-02T19:40");
  assert.match(body.results[1].value, /^DL-[A-Z0-9]{6}$/);
  assert.equal(body.results[1].value, await expectedCode(ID));
  // The code depends on the request id alone and ignores its case.
  const upper = await (
    await call(submit({ request_id: ID.toUpperCase(), values: values({ restaurant: "SENTINEL-RESTAURANT", address: "SENTINEL-ADDRESS" }) }))
  ).json();
  assert.equal(upper.results[1].value, body.results[1].value);
  const changed = await (
    await call(
      submitValues({ items: [{ item: "pizza", quantity: 1 }], card_id: "credit-1881", arrive_at: "2027-01-05T12:30" }),
    )
  ).json();
  assert.equal(changed.results[1].value, body.results[1].value);
  const other = await (await call(submit({ request_id: ID2 }))).json();
  assert.notEqual(other.results[1].value, body.results[1].value);
  // No free-text value, no item and no card is echoed.
  const text = JSON.stringify(body);
  for (const secret of ["SENTINEL-RESTAURANT", "SENTINEL-ADDRESS", "ramen", "debit-4242"]) {
    assert.equal(text.includes(secret), false, secret);
  }
  for (const key of ["order_id", "restaurant", "items", "address", "card_id"]) {
    assert.equal(key in body, false, key);
  }
});

test("AC-DELIVERYCARD-004 D06: hours and quantity declines, the hours first", async () => {
  const answerOf = async (over) => (await call(submitValues(over))).json();
  for (const time of ["10:00", "22:00", "19:40"]) {
    const body = await answerOf({ arrive_at: `2026-11-02T${time}` });
    assert.equal(body.status, "confirmed", time);
  }
  for (const [name, over, reason] of [
    ["09:59", { arrive_at: "2026-11-02T09:59" }, "outside_hours"],
    ["22:01", { arrive_at: "2026-11-02T22:01" }, "outside_hours"],
    ["quantity 0", { items: [{ item: "ramen", quantity: 0 }] }, "quantity_out_of_range"],
    ["quantity 10", { items: [{ item: "ramen", quantity: 10 }] }, "quantity_out_of_range"],
    ["a second row out of range", { items: [{ item: "ramen", quantity: 1 }, { item: "gyoza", quantity: 99 }] }, "quantity_out_of_range"],
  ]) {
    const body = await answerOf(over);
    assert.equal(body.status, "declined", name);
    assert.deepEqual(Object.keys(body), ["status", "partner", "simulated", "reason"], name);
    assert.equal(body.reason, reason, name);
    assert.equal(body.partner, "Example Delivery", name);
    assert.equal(body.simulated, true, name);
    assert.equal("results" in body, false, name);
  }
  for (const quantity of [1, 9]) {
    const body = await answerOf({ items: [{ item: "ramen", quantity }] });
    assert.equal(body.status, "confirmed", `quantity ${quantity}`);
  }
  // A request with both faults gives the hours answer.
  const both = await answerOf({ arrive_at: "2026-11-02T22:01", items: [{ item: "ramen", quantity: 10 }] });
  assert.equal(both.status, "declined");
  assert.equal(both.reason, "outside_hours");
});

test("AC-DELIVERYCARD-004 D07: the estimated total is the sum of price times quantity plus the fee", async () => {
  const totalOfRows = async (items) => {
    const body = await (await call(submitValues({ items }))).json();
    assert.equal(body.status, "confirmed", JSON.stringify(items));
    assert.equal(Number.isInteger(totalOf(body)), true);
    return totalOf(body);
  };
  assert.equal(await totalOfRows([{ item: "ramen", quantity: 1 }]), PRICE.ramen + FEE);
  assert.equal(
    await totalOfRows([
      { item: "gyoza", quantity: 1 },
      { item: "ramen", quantity: 2 },
    ]),
    PRICE.gyoza + 2 * PRICE.ramen + FEE,
  );
  // Six rows, every menu item once.
  assert.equal(
    await totalOfRows(MENU.map(({ id }) => ({ item: id, quantity: 1 }))),
    MENU.reduce((sum, { price_cents }) => sum + price_cents, FEE),
  );
  // A repeated item is priced per row.
  assert.equal(
    await totalOfRows([
      { item: "ramen", quantity: 2 },
      { item: "ramen", quantity: 3 },
    ]),
    5 * PRICE.ramen + FEE,
  );
  // Every item at 1 and at 9.
  for (const { id, price_cents } of MENU) {
    assert.equal(await totalOfRows([{ item: id, quantity: 1 }]), price_cents + FEE, `${id} once`);
    assert.equal(await totalOfRows([{ item: id, quantity: 9 }]), price_cents * 9 + FEE, `${id} nine times`);
  }
});

test("AC-DELIVERYCARD-003 D08: the ladder of the faults, step by step and two at once", async () => {
  await expectError(await call(null, { raw: "x".repeat(4097) }), 413, "body_too_large");
  await expectError(await call(null, { raw: "x".repeat(4096) }), 400, "invalid_json");
  await expectError(await call(null, { raw: "not json" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "[1,2]" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "null" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "5" }), 400, "body_must_be_object");
  // (1) a key outside the six.
  await expectError(await call({ ...submit(), people: 2 }), 400, "unknown_field");
  await expectError(await call({ op: "fields", people: 2 }), 400, "unknown_field");
  // (2) an op that is present and none of the three words.
  for (const op of ["options", "order", "ORDER", "Submit", "", 5, null, true]) {
    await expectError(await call(submit({ op })), 400, "invalid_field", `op ${JSON.stringify(op)}`);
  }
  // (3) no op, or a key the op needs missing.
  const { op: withoutOpValue, ...noOp } = submit();
  await expectError(await call(noOp), 400, "missing_field");
  await expectError(await call({}), 400, "missing_field");
  await expectError(await call({ op: "submit" }), 400, "missing_field");
  await expectError(await call({ op: "submit", values: values() }), 400, "missing_field");
  await expectError(await call({ op: "submit", request_id: ID }), 400, "missing_field");
  await expectError(await call({ op: "lookup" }), 400, "missing_field");
  await expectError(await call({ op: "lookup", field: "address" }), 400, "missing_field");
  await expectError(await call({ op: "lookup", text: "Tartine" }), 400, "missing_field");
  // (4) a key the op does not allow.
  await expectError(await call({ op: "fields", request_id: ID }), 400, "invalid_field");
  await expectError(await call(submit({ field: "address" })), 400, "invalid_field");
  await expectError(await call({ op: "lookup", field: "address", text: "Tartine", request_id: ID }), 400, "invalid_field");
  // (5) values is not an object.
  for (const bad of [[], "x", 5, null, true]) {
    await expectError(await call({ op: "submit", request_id: ID, values: bad }), 400, "invalid_field");
  }
  // (5b) items present and not an array of 1 to 6 objects.
  for (const items of [[], "x", 5, null, {}, ["x"], [5], [null], [[]], [{ item: "ramen", quantity: 1 }, "x"]]) {
    await expectError(await call(submitValues({ items })), 400, "invalid_field", `items ${JSON.stringify(items)}`);
  }
  for (let count of [0, 7]) {
    const rows = Array.from({ length: count === 0 ? 2 : 7 }, () => ({ item: "ramen", quantity: 1 }));
    const items = count === 0 ? [] : rows;
    await expectError(await call(submitValues({ items })), 400, "invalid_field", `${count} rows`);
  }
  // (6) a key of values outside the five, then of a row outside the two.
  await expectError(await call(submitValues({ extra: 1 })), 400, "unknown_field");
  await expectError(await call(submitValues({ note: "x" })), 400, "unknown_field");
  await expectError(
    await call(submitValues({ items: [{ item: "ramen", quantity: 1, note: "x" }] })),
    400,
    "unknown_field",
  );
  // (7) a required key of values, then of a row, missing.
  for (const key of Object.keys(BASE_VALUES)) {
    await expectError(await call(submit({ values: drop(BASE_VALUES, key) })), 400, "missing_field", `no ${key}`);
  }
  await expectError(await call(submitValues({ items: [{ quantity: 1 }] })), 400, "missing_field");
  await expectError(await call(submitValues({ items: [{ item: "ramen" }] })), 400, "missing_field");
  // (8) types and ranges.
  await expectError(await call(submit({ request_id: "not-a-uuid" })), 400, "invalid_field");
  await expectError(await call(submitValues({ restaurant: "x".repeat(121) })), 400, "invalid_field");
  await expectError(await call(submitValues({ arrive_at: "2026-13-01T12:00" })), 400, "invalid_field");
  await expectError(await call(submitValues({ address: "12 Test\u0007Street" })), 400, "invalid_field");
  await expectError(await call(submitValues({ card_id: "nope" })), 400, "invalid_field");
  await expectError(await call(submitValues({ items: [{ item: "sushi", quantity: 1 }] })), 400, "invalid_field");
  for (const quantity of ["2", 2.5, true, null]) {
    await expectError(await call(submitValues({ items: [{ item: "ramen", quantity }] })), 400, "invalid_field");
  }
  // Each adjacent pair that can co-occur, broken at once: the earlier step answers.
  await expectError(await call({ op: "options", people: 1 }), 400, "unknown_field");
  await expectError(await call({ op: "refund", request_id: ID }), 400, "invalid_field");
  await expectError(await call({ op: "submit", request_id: ID, text: "x" }), 400, "missing_field");
  await expectError(await call({ op: "submit", request_id: ID, values: values(), text: "x" }), 400, "invalid_field");
  await expectError(await call({ op: "submit", request_id: ID, values: [], text: "x" }), 400, "invalid_field");
  await expectError(await call(submitValues({ items: [], extra: 1 })), 400, "invalid_field");
  await expectError(await call(submit({ values: { ...drop(BASE_VALUES, "restaurant"), extra: 1 } })), 400, "unknown_field");
  await expectError(
    await call(submit({ values: { ...drop(BASE_VALUES, "restaurant"), card_id: "nope" } })),
    400,
    "missing_field",
  );
  await expectError(
    await call(submitValues({ items: [{ item: "ramen", quantity: 1, note: "x" }, { quantity: 1 }] })),
    400,
    "unknown_field",
  );
});

test("AC-DELIVERYCARD-003 D09: the value rules of the five fields and the request id", async () => {
  // restaurant and address: 1 to 120 code points, trimmed, no hidden character.
  const wide = "\u{1D49C}"; // one code point, two UTF-16 units
  for (const key of ["restaurant", "address"]) {
    assert.equal((await call(submitValues({ [key]: wide.repeat(120) }))).status, 200, `${key} 120`);
    await expectError(await call(submitValues({ [key]: wide.repeat(121) })), 400, "invalid_field");
    const padded = await (await call(submitValues({ [key]: `  Test Cafe  ` }))).json();
    assert.equal(padded.status, "confirmed");
    const trimmed120 = await call(submitValues({ [key]: `  ${"a".repeat(120)}  ` }));
    assert.equal(trimmed120.status, 200);
    for (const bad of ["", "   ", "Test\u0007Cafe", "Test​Cafe", "Test Cafe", "Test Cafe", "Test Cafe\n", "Test\tCafe", 5, null, ["Test Cafe"]]) {
      await expectError(await call(submitValues({ [key]: bad })), 400, "invalid_field", `${key} ${JSON.stringify(bad)}`);
    }
  }
  // arrive_at: a real local date-time of the years 2000 to 2199. The year edges fall outside the open hours, and a
  // date the rule accepts answers the hours decline, so both prove the date itself passed.
  for (const arrive_at of ["2028-02-29T12:00", "2000-02-29T12:00", "2100-02-28T12:00"]) {
    const body = await (await call(submitValues({ arrive_at }))).json();
    assert.equal(body.status, "confirmed", arrive_at);
    assert.equal(body.results[0].value, arrive_at);
  }
  for (const arrive_at of ["2000-01-01T00:00", "2199-12-31T23:59"]) {
    const res = await call(submitValues({ arrive_at }));
    assert.equal(res.status, 200, arrive_at);
    const body = await res.json();
    assert.equal(body.status, "declined", arrive_at);
    assert.equal(body.reason, "outside_hours", arrive_at);
  }
  for (const arrive_at of ["2026-02-29T12:00", "2100-02-29T12:00", "2026-13-01T12:00", "2026-11-02T24:00", "2026-11-02T12:60", "1999-12-31T12:00", "2200-01-01T12:00", "2026-11-02 12:00", "2026-11-02T12:00:00", "2026-11-02", "", 20261102, null]) {
    await expectError(await call(submitValues({ arrive_at })), 400, "invalid_field", arrive_at);
  }
  // card_id: one of the two cards.
  for (const card of CARDS) {
    assert.equal((await call(submitValues({ card_id: card.id }))).status, 200);
  }
  for (const card_id of ["", "nope", "DEBIT-4242", " debit-4242", "debit-4243", 5, null, ["debit-4242"]]) {
    await expectError(await call(submitValues({ card_id })), 400, "invalid_field");
  }
  // item: the id of a menu item.
  for (const item of ["sushi", "Ramen", "", 5, null, ["ramen"]]) {
    await expectError(await call(submitValues({ items: [{ item, quantity: 1 }] })), 400, "invalid_field", JSON.stringify(item));
  }
  // quantity: a JSON number with a whole value; 2.0 is accepted as sent.
  const twoPointZero = await call(null, {
    raw: `{"op":"submit","request_id":${JSON.stringify(ID)},"values":{"restaurant":"Test Cafe","items":[{"item":"ramen","quantity":2.0}],"arrive_at":"2026-11-02T19:40","address":"12 Test Street","card_id":"debit-4242"}}`,
  });
  assert.equal(twoPointZero.status, 200);
  assert.equal(totalOf(await twoPointZero.json()), 2 * PRICE.ramen + FEE);
  // request_id: a UUID in either case.
  assert.equal((await call(submit({ request_id: ID.toUpperCase() }))).status, 200);
  for (const request_id of ["not-a-uuid", `${ID}0`, ` ${ID}`, ID.replaceAll("-", ""), "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6g", 1, null]) {
    await expectError(await call(submit({ request_id })), 400, "invalid_field");
  }
});

test("AC-DELIVERYCARD-003 D10: the row rules of the group", async () => {
  // One row and six rows are accepted, in the order sent.
  for (const items of [
    [{ item: "lemonade", quantity: 1 }],
    MENU.map(({ id }) => ({ item: id, quantity: 1 })),
  ]) {
    assert.equal((await call(submitValues({ items }))).status, 200, JSON.stringify(items));
  }
  // A repeated item is accepted and priced per row.
  const repeated = await (await call(submitValues({ items: [{ item: "ramen", quantity: 2 }, { item: "ramen", quantity: 3 }] }))).json();
  assert.equal(repeated.status, "confirmed");
  assert.equal(totalOf(repeated), 5 * PRICE.ramen + FEE);
  // Zero rows and seven rows are invalid (the count is step 5b, before any key of a row is read).
  await expectError(await call(submitValues({ items: [] })), 400, "invalid_field");
  await expectError(
    await call(submitValues({ items: Array.from({ length: 7 }, () => ({ item: "ramen", quantity: 1 })) })),
    400,
    "invalid_field",
  );
  await expectError(await call(submitValues({ items: "ramen:1" })), 400, "invalid_field");
  await expectError(await call(submitValues({ items: { item: "ramen", quantity: 1 } })), 400, "invalid_field");
  await expectError(await call(submitValues({ items: [5, null, [], "x"] })), 400, "invalid_field");
  // A row key outside item and quantity is unknown; a missing member is missing.
  await expectError(
    await call(submitValues({ items: [{ item: "ramen", quantity: 1, price_cents: 1 }] })),
    400,
    "unknown_field",
  );
  await expectError(await call(submitValues({ items: [{ item: "ramen" }] })), 400, "missing_field");
  await expectError(await call(submitValues({ items: [{ quantity: 1 }] })), 400, "missing_field");
  await expectError(await call(submitValues({ items: [{}] })), 400, "missing_field");
});

test("AC-DELIVERYCARD-003 D11: the old ops and shapes are refused", async () => {
  await expectError(await call({ op: "options" }), 400, "invalid_field");
  // An old order body: the old keys at the top level.
  await expectError(
    await call({
      op: "order",
      request_id: ID,
      restaurant: "Test Cafe",
      arrive_at: "2026-11-02T19:40",
      items: [{ item_id: "ramen", quantity: 2 }],
      address: "12 Test Street",
      card_id: "debit-4242",
    }),
    400,
    "unknown_field",
  );
  // Each answer-side key as a request key is unknown.
  for (const key of ["fields", "result_fields", "results", "reason", "order_id", "status", "partner", "simulated"]) {
    await expectError(await call({ ...submit(), [key]: [] }), 400, "unknown_field", key);
  }
  // `fields` beside the op that does not take it.
  await expectError(await call({ op: "fields", values: values() }), 400, "invalid_field");
  await expectError(await call({ op: "fields", field: "address" }), 400, "invalid_field");
});

test("AC-DELIVERYCARD-005 D12: the lookup request is validated in order and an invalid one makes no fetch", async () => {
  const lookupBody = (over = {}) => ({ op: "lookup", field: "address", text: "Tartine Bakery", ...over });
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    throw new Error("no outgoing request is allowed");
  };
  try {
    // (1) a stray key beside a lookup.
    await expectError(await call({ ...lookupBody(), x: 1 }), 400, "unknown_field");
    // (3) a key a lookup needs missing.
    await expectError(await call({ op: "lookup", field: "address" }), 400, "missing_field");
    await expectError(await call({ op: "lookup", text: "Tartine" }), 400, "missing_field");
    await expectError(await call({ op: "lookup" }), 400, "missing_field");
    // (4) a key of another op beside a lookup.
    await expectError(await call(lookupBody({ request_id: ID })), 400, "invalid_field");
    await expectError(await call(lookupBody({ values: values() })), 400, "invalid_field");
    // (4) the lookup keys beside the other ops.
    await expectError(await call({ op: "fields", field: "address" }), 400, "invalid_field");
    await expectError(await call(submit({ text: "Tartine" })), 400, "invalid_field");
    // (5) a field other than address: the old order keys and the other fields of this form.
    for (const field of ["restaurant", "items", "arrive_at", "card_id", "order_id", "nope", "", 5, null, true]) {
      await expectError(await call(lookupBody({ field })), 400, "invalid_field", `field ${JSON.stringify(field)}`);
    }
    // (5) the text: under 2 or over 80 code points.
    for (const text of ["", "x", "x".repeat(81), " \nx", 5, null, ["Tartine"]]) {
      await expectError(await call(lookupBody({ text })), 400, "invalid_field", `text ${JSON.stringify(text)}`);
    }
    // (5) the shape of near, (6) its keys, (7) a missing key, (8) a bad value.
    for (const near of ["x", 5, null, true, [], "1,2"]) {
      await expectError(await call(lookupBody({ near })), 400, "invalid_field", `near ${JSON.stringify(near)}`);
    }
    await expectError(await call(lookupBody({ near: { latitude: 1, longitude: 2, altitude: 3 } })), 400, "unknown_field");
    await expectError(await call(lookupBody({ near: { latitude: 1 } })), 400, "missing_field");
    await expectError(await call(lookupBody({ near: { latitude: 91, longitude: 0 } })), 400, "invalid_field");
    await expectError(await call(lookupBody({ near: { latitude: 0, longitude: 181 } })), 400, "invalid_field");
    await expectError(await call(lookupBody({ near: { latitude: "1", longitude: 2 } })), 400, "invalid_field");
    // The order: the field before the text, the text before the keys of near.
    await expectError(await call(lookupBody({ field: "restaurant", text: "" })), 400, "invalid_field");
    await expectError(await call(lookupBody({ text: "", near: { latitude: 1, longitude: 2, altitude: 3 } })), 400, "invalid_field");
    await expectError(await call(lookupBody({ field: "restaurant", request_id: ID })), 400, "invalid_field");
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-DELIVERYCARD-005 D13: one valid lookup asks Google Places once, with the Worker's own key and mask", async () => {
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push({ url: String(url), init });
    return new Response(
      JSON.stringify({ places: [{ displayName: { text: "Tartine Bakery" }, formattedAddress: "600 Guerrero St", location: { latitude: 37.76, longitude: -122.42 } }] }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };
  try {
    const hostile = { "x-goog-fieldmask": "places.id", "x-goog-api-key": "client-key", authorization: "Bearer client" };
    const res = await worker.fetch(
      new Request("https://x.test/delivery", {
        method: "POST",
        headers: { "x-besir-token": "app-test", ...hostile },
        body: JSON.stringify({ op: "lookup", field: "address", text: "  Tartine Bakery  " }),
      }),
      env,
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(Object.keys(body), ["partner", "simulated", "field", "candidates"]);
    assert.equal(body.partner, "Example Delivery");
    assert.equal(body.simulated, true);
    assert.equal(body.field, "address");
    assert.equal(body.candidates.length, 1);
    // The one outgoing request: the Worker's key, the fixed mask, no client header.
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, "https://places.googleapis.com/v1/places:searchText");
    const sent = new Headers(seen[0].init.headers);
    assert.equal(sent.get("x-goog-api-key"), "g");
    assert.equal(sent.get("x-goog-fieldmask"), "places.displayName,places.formattedAddress,places.location");
    assert.equal(sent.get("authorization"), null);
    const sentBody = JSON.parse(seen[0].init.body);
    assert.deepEqual(Object.keys(sentBody), ["textQuery", "languageCode", "regionCode", "pageSize"]);
    assert.equal(sentBody.textQuery, "Tartine Bakery");
    assert.equal(sentBody.languageCode, "en");
    assert.equal(sentBody.regionCode, "US");
    assert.equal(sentBody.pageSize, 5);
    // A bias circle only with near.
    const biased = await call({ op: "lookup", field: "address", text: "Tartine Bakery", near: { latitude: 1.5, longitude: -2.25 } });
    assert.equal(biased.status, 200);
    assert.equal(seen.length, 2);
    const biasedBody = JSON.parse(seen[1].init.body);
    assert.deepEqual(Object.keys(biasedBody), ["textQuery", "languageCode", "regionCode", "pageSize", "locationBias"]);
    assert.deepEqual(biasedBody.locationBias, { circle: { center: { latitude: 1.5, longitude: -2.25 }, radius: 50000 } });
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-DELIVERYCARD-005 D14: a bad Google result is dropped alone, no candidate is an empty list, and the failures are fixed words", async () => {
  const upstream = (places, status = 200) =>
    async () => new Response(JSON.stringify({ places, note: "SECRET-UPSTREAM-TEXT" }), { status, headers: { "content-type": "application/json" } });
  const place = (id, over = {}) => ({
    displayName: { text: `Place ${id}` },
    formattedAddress: `${id} Test Street`,
    location: { latitude: 37.7, longitude: -122.4 },
    ...over,
  });
  // A bad result is dropped alone.
  globalThis.fetch = upstream([place("1"), "x", null, 5, {}, place("2", { displayName: { text: "" } }), place("3")]);
  const mixed = await (await call({ op: "lookup", field: "address", text: "Tartine" })).json();
  assert.deepEqual(mixed.candidates.map((candidate) => candidate.name), ["Place 1", "Place 3"]);
  // At most five candidates; none is an empty list.
  globalThis.fetch = upstream([place("1"), place("2"), place("3"), place("4"), place("5"), place("6")]);
  const six = await (await call({ op: "lookup", field: "address", text: "Tartine" })).json();
  assert.equal(six.candidates.length, 5);
  for (const candidate of six.candidates) {
    assert.deepEqual(Object.keys(candidate), ["name", "address", "location"]);
  }
  globalThis.fetch = upstream([]);
  const none = await (await call({ op: "lookup", field: "address", text: "Zzzz" })).json();
  assert.deepEqual(none.candidates, []);
  // A failing upstream is 502 and a missing key 503, both with no upstream text.
  globalThis.fetch = upstream([], 500);
  const failed = await call({ op: "lookup", field: "address", text: "Tartine" });
  assert.equal(failed.status, 502);
  const failedText = await failed.text();
  assert.equal(failedText.includes("SECRET-UPSTREAM-TEXT"), false);
  assert.deepEqual(JSON.parse(failedText), { error: "upstream_failed" });
  const noKey = await call({ op: "lookup", field: "address", text: "Tartine" }, { e: envWithoutKey });
  await expectError(noKey, 503, "google_key_not_configured");
  try {
    globalThis.fetch = async () => {
      throw new Error("network down");
    };
    const thrown = await call({ op: "lookup", field: "address", text: "Tartine" });
    await expectError(thrown, 502, "upstream_failed");
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-DELIVERYCARD-005 D15: fields and submit make no fetch, and the sources hold no log, storage, clock or random call", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    throw new Error("no outgoing request is allowed");
  };
  try {
    assert.equal((await call({ op: "fields" })).status, 200);
    assert.equal((await call(submit())).status, 200);
    assert.equal((await call(submitValues({ arrive_at: "2026-11-02T23:30" }))).status, 200);
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
  for (const file of ["../src/delivery.js", "../src/lookup.js"]) {
    const source = readFileSync(new URL(file, import.meta.url), "utf8");
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\s\/\/.*$/gm, "");
    for (const word of ["console", "fetch", "env", "Date", "KV", "D1", "R2"]) {
      assert.equal(new RegExp(`\\b${word}\\b`).test(code), false, `${file} holds ${word}`);
    }
    for (const text of ["Math.random", "getRandomValues"]) {
      assert.equal(code.includes(text), false, `${file} holds ${text}`);
    }
    assert.equal(code.includes("crypto.subtle"), file === "../src/delivery.js", `${file} crypto.subtle`);
  }
  // Positive controls: the same scan finds what it looks for.
  assert.equal(/\bfetch\b/.test("await fetch(x)"), true);
  assert.equal(/\bDate\b/.test("new Date()"), true);
  assert.equal(/\benv\b/.test("handle(request, env)"), true);
  // The partner name is written once in delivery.js.
  const delivery = readFileSync(new URL("../src/delivery.js", import.meta.url), "utf8");
  assert.equal(delivery.split("Example Delivery").length - 1, 1);
});

test("AC-DELIVERYCARD-001 D16: the route sits beside the others and has no cancel route", async () => {
  // After the token check and the method check.
  await expectError(await call({ op: "fields" }, { token: "nope" }), 401, "unauthorized");
  await expectError(await call(null, { method: "GET" }), 405, "method_not_allowed");
  // No cancel route and no list of deliveries.
  for (const path of ["/delivery/cancel", "/deliveries"]) {
    const res = await worker.fetch(
      new Request(`https://x.test${path}`, { method: "POST", headers: { "x-besir-token": "app-test" }, body: "{}" }),
      env,
    );
    await expectError(res, 404, "not_found");
  }
  // Every answer names the partner and says it is simulated.
  for (const body of [
    await (await call({ op: "fields" })).json(),
    await (await call(submit())).json(),
    await (await call(submitValues({ arrive_at: "2026-11-02T23:30" }))).json(),
  ]) {
    assert.equal(body.partner, "Example Delivery");
    assert.equal(body.simulated, true);
  }
});

test("AC-DELIVERYCARD-004 D17: the order number differs from the reservation number of the booking route", async () => {
  const table = await (
    await call(
      {
        op: "submit",
        request_id: ID,
        values: { restaurant: "Test Cafe", party_size: 2, start: "2026-11-02T19:40", name: "Sam" },
      },
      { path: "/booking" },
    )
  ).json();
  const reservation = table.results.find((item) => item.name === "Reservation number");
  assert.match(reservation.value, /^EX-[A-Z0-9]{6}$/);
  const order = await (await call(submit())).json();
  assert.match(order.results[1].value, /^DL-[A-Z0-9]{6}$/);
  assert.notEqual(order.results[1].value.slice(3), reservation.value.slice(3));
  assert.equal(order.results[1].value, await expectedCode(ID));
});
