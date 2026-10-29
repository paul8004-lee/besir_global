import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: "g" };
const ID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b";
const ID2 = "9a1d4c7e-2b3f-4a50-8c61-7d8e9f0a1b2c";
const LINES = [{ item_id: "ramen", quantity: 2 }];
const valid = (over = {}) => ({
  op: "order",
  request_id: ID,
  restaurant: "Test Cafe",
  arrive_at: "2026-11-02T19:40",
  items: LINES,
  address: "12 Test Street",
  card_id: "debit-4242",
  ...over,
});

const ORDER_KEYS = ["op", "request_id", "restaurant", "arrive_at", "items", "address", "card_id"];
const CONFIRMED_KEYS = [
  "address",
  "arrival_estimate",
  "arrive_at",
  "card_id",
  "estimated_total_cents",
  "items",
  "order_id",
  "partner",
  "restaurant",
  "simulated",
  "status",
];
const DECLINED_KEYS = ["address", "arrive_at", "card_id", "items", "partner", "reason", "restaurant", "simulated", "status"];

// The partner's fixed tables of L13, written out here on purpose: the route and the test do not share them.
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
const FEE = 500;

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

// The body is built from text so a number such as 2.0 reaches the Worker as written.
const rawBody = (fields) => {
  const parts = Object.entries(fields).map(([key, text]) => `${JSON.stringify(key)}:${text}`);
  return `{${parts.join(",")}}`;
};

const realFetch = globalThis.fetch;

test("AC-DELIVERY-001 D01: 401 for no token, a wrong token and no APP_TOKEN, before the body is read", async () => {
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

test("AC-DELIVERY-001 D02: a non-POST is 405 and the other routes still answer 401 to a bad token", async () => {
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

test("AC-DELIVERY-002 D03: an order at 19:40 gives exactly the eleven keys of a confirmed order", async () => {
  const items = [
    { item_id: "gyoza", quantity: 1 },
    { item_id: "ramen", quantity: 2 },
  ];
  const res = await call(valid({ restaurant: "  Test Cafe  ", address: "  12 Test Street  ", items, card_id: "credit-1881" }));
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), CONFIRMED_KEYS);
  assert.equal(body.status, "confirmed");
  assert.equal(body.partner, "Example Delivery");
  assert.equal(body.simulated, true);
  assert.equal(body.restaurant, "Test Cafe");
  assert.equal(body.arrive_at, "2026-11-02T19:40");
  assert.deepEqual(body.items, items);
  assert.equal(body.address, "12 Test Street");
  assert.equal(body.card_id, "credit-1881");
  assert.equal(body.arrival_estimate, "2026-11-02T19:40");
  assert.equal(body.estimated_total_cents, 700 + 2 * 1400 + 500);
  assert.match(body.order_id, /^DL-[A-Z0-9]{6}$/);
});

test("AC-DELIVERY-002 D04: an order at 23:30 gives exactly the nine keys of a declined order", async () => {
  const res = await call(valid({ arrive_at: "2026-11-02T23:30" }));
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), DECLINED_KEYS);
  assert.equal(body.status, "declined");
  assert.equal(body.reason, "outside_hours");
  assert.equal(body.partner, "Example Delivery");
  assert.equal(body.simulated, true);
  assert.equal(body.restaurant, "Test Cafe");
  assert.equal(body.arrive_at, "2026-11-02T23:30");
  assert.deepEqual(body.items, LINES);
  assert.equal(body.address, "12 Test Street");
  assert.equal(body.card_id, "debit-4242");
  for (const key of ["order_id", "arrival_estimate", "estimated_total_cents"]) {
    assert.equal(key in body, false, key);
  }
});

test("AC-DELIVERY-002 D05: the hours edges are 10:00 and 22:00 confirmed, 09:59 and 22:01 declined", async () => {
  for (const time of ["10:00", "22:00", "10:01", "21:59", "12:00"]) {
    const body = await (await call(valid({ arrive_at: `2026-11-02T${time}` }))).json();
    assert.equal(body.status, "confirmed", time);
    assert.deepEqual(Object.keys(body).sort(), CONFIRMED_KEYS, time);
  }
  for (const time of ["09:59", "22:01", "00:00", "23:59"]) {
    const body = await (await call(valid({ arrive_at: `2026-11-02T${time}` }))).json();
    assert.equal(body.status, "declined", time);
    assert.equal(body.reason, "outside_hours", time);
    assert.deepEqual(Object.keys(body).sort(), DECLINED_KEYS, time);
  }
});

test("AC-DELIVERY-002 D06: the estimated total is the sum of price times quantity plus 500, always an integer", async () => {
  const options = await (await call({ op: "options" })).json();
  const price = Object.fromEntries(options.menu.map((entry) => [entry.id, entry.price_cents]));
  const totalOf = async (items) => {
    const body = await (await call(valid({ items }))).json();
    assert.equal(body.status, "confirmed");
    assert.equal(Number.isInteger(body.estimated_total_cents), true);
    return body.estimated_total_cents;
  };
  for (const item of MENU) {
    assert.equal(price[item.id], item.price_cents, `the options answer prices ${item.id}`);
    assert.equal(await totalOf([{ item_id: item.id, quantity: 1 }]), item.price_cents + 500, `${item.id} once`);
    assert.equal(await totalOf([{ item_id: item.id, quantity: 9 }]), item.price_cents * 9 + 500, `${item.id} nine times`);
  }
  assert.equal(
    await totalOf([
      { item_id: "pizza", quantity: 3 },
      { item_id: "lemonade", quantity: 4 },
      { item_id: "curry", quantity: 1 },
    ]),
    3 * 2500 + 4 * 400 + 1300 + 500,
  );
  // Six lines of nine: the largest order.
  assert.equal(await totalOf(MENU.map((item) => ({ item_id: item.id, quantity: 9 }))), 65300);
  // The order of the lines does not change the total.
  assert.equal(
    await totalOf([
      { item_id: "lemonade", quantity: 2 },
      { item_id: "ramen", quantity: 1 },
    ]),
    await totalOf([
      { item_id: "ramen", quantity: 1 },
      { item_id: "lemonade", quantity: 2 },
    ]),
  );
});

test("AC-DELIVERY-002 D07: the answer depends on the request alone and the order id has its shape", async () => {
  const a = await (await call(valid())).json();
  const b = await (await call(valid())).json();
  assert.deepEqual(a, b);
  assert.match(a.order_id, /^DL-[A-Z0-9]{6}$/);
  const other = await (await call(valid({ request_id: ID2 }))).json();
  assert.match(other.order_id, /^DL-[A-Z0-9]{6}$/);
  assert.notEqual(other.order_id, a.order_id);
  // Other fields do not change the id; the case of the request id does not either.
  const changed = await (
    await call(
      valid({
        restaurant: "Another",
        arrive_at: "2027-01-05T12:30",
        items: [{ item_id: "pizza", quantity: 5 }],
        address: "99 Other Road",
        card_id: "credit-1881",
      }),
    )
  ).json();
  assert.equal(changed.order_id, a.order_id);
  const upper = await (await call(valid({ request_id: ID.toUpperCase() }))).json();
  assert.equal(upper.order_id, a.order_id);
  // The order id differs from the table code of the booking route for the same request id.
  const table = await (
    await call({ request_id: ID, restaurant: "Test Cafe", party_size: 2, start: "2026-11-02T19:40" }, { path: "/booking" })
  ).json();
  assert.match(table.reservation_code, /^EX-[A-Z0-9]{6}$/);
  assert.notEqual(table.reservation_code.slice(3), a.order_id.slice(3));
});

test("AC-DELIVERY-001 D08: the order and words of the faults", async () => {
  await expectError(await call(null, { raw: "x".repeat(4097) }), 413, "body_too_large");
  await expectError(await call(null, { raw: "x".repeat(4096) }), 400, "invalid_json");
  await expectError(await call(null, { raw: "not json" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "[1,2]" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "null" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "5" }), 400, "body_must_be_object");
  // A key outside the seven names is unknown, the old `people` among them.
  await expectError(await call({ ...valid(), people: 2 }), 400, "unknown_field");
  await expectError(await call({ ...valid(), name: "x" }), 400, "unknown_field");
  await expectError(await call({ op: "options", people: 2 }), 400, "unknown_field");
  await expectError(await call({ op: "options", extra: 1 }), 400, "unknown_field");
  // An op that is present and neither word is invalid, whatever else is missing.
  await expectError(await call({ op: "refund" }), 400, "invalid_field");
  await expectError(await call({ op: 5 }), 400, "invalid_field");
  await expectError(await call({ op: null, request_id: ID }), 400, "invalid_field");
  for (const op of ["ORDER", "Options", "", " order", "order ", "left", "spend"]) {
    await expectError(await call(valid({ op })), 400, "invalid_field");
  }
  // A missing op, or a missing key of the shape, is missing_field.
  const { op: noOp, ...withoutOp } = valid();
  await expectError(await call(withoutOp), 400, "missing_field");
  await expectError(await call({}), 400, "missing_field");
  await expectError(await call({ op: "order" }), 400, "missing_field");
  for (const key of ORDER_KEYS.filter((name) => name !== "op")) {
    const { [key]: removed, ...rest } = valid();
    await expectError(await call(rest), 400, "missing_field");
  }
  // A key that does not belong to the shape of its op is invalid_field.
  for (const key of ORDER_KEYS.filter((name) => name !== "op")) {
    await expectError(await call({ op: "options", [key]: valid()[key] }), 400, "invalid_field");
  }
  // A value outside its rule is invalid_field.
  await expectError(await call(valid({ card_id: "nope" })), 400, "invalid_field");
  await expectError(await call(valid({ items: [] })), 400, "invalid_field");
  // The order of the checks: unknown beats the op word, the op word beats missing, missing beats invalid.
  await expectError(await call({ op: "refund", people: 1 }), 400, "unknown_field");
  await expectError(await call({ op: "refund", request_id: ID }), 400, "invalid_field");
  const { arrive_at, ...noTime } = valid();
  await expectError(await call({ ...noTime, name: "x" }), 400, "unknown_field");
  await expectError(await call({ ...valid({ card_id: "nope" }), phone: "1" }), 400, "unknown_field");
  await expectError(await call({ op: "order", request_id: ID, restaurant: "", card_id: "nope" }), 400, "missing_field");
  await expectError(await call({ ...noTime, card_id: "nope" }), 400, "missing_field");
  await expectError(await call(valid({ card_id: "nope", arrive_at: "bad" })), 400, "invalid_field");
  await expectError(await call({ op: "options", items: [], people: 2 }), 400, "unknown_field");
});

test("AC-DELIVERY-001 D09: arrive_at accepts real date-times and refuses the rest", async () => {
  const accepted = [
    "2028-02-29T12:00",
    "2000-02-29T12:00",
    "2026-12-31T21:59",
    "2000-01-01T00:00",
    "2199-12-31T23:59",
    "2100-02-28T12:00",
  ];
  for (const arrive_at of accepted) {
    const res = await call(valid({ arrive_at }));
    assert.equal(res.status, 200, arrive_at);
    assert.equal((await res.json()).arrive_at, arrive_at);
  }
  const refused = [
    "2026-02-29T12:00",
    "2100-02-29T12:00",
    "2026-13-01T12:00",
    "2026-00-10T12:00",
    "2026-11-00T12:00",
    "2026-04-31T12:00",
    "2026-02-30T12:00",
    "2026-11-02T24:00",
    "2026-11-02T12:60",
    "1999-12-31T12:00",
    "2200-01-01T12:00",
    "2026-11-02 12:00",
    "2026-11-02T12:00:00",
    "2026-11-02T12:00Z",
    "2026-11-02",
    "",
  ];
  for (const arrive_at of refused) {
    await expectError(await call(valid({ arrive_at })), 400, "invalid_field");
  }
  await expectError(await call(valid({ arrive_at: 20261102 })), 400, "invalid_field");
  await expectError(await call(valid({ arrive_at: null })), 400, "invalid_field");
});

test("AC-DELIVERY-001 D10: items hold 1 to 6 lines of known items, quantity 1 to 9, no repeats", async () => {
  // The body is built from text so that 2.0 reaches the Worker as written.
  const two = await call(null, {
    raw: rawBody({
      op: '"order"',
      request_id: JSON.stringify(ID),
      restaurant: '"Test Cafe"',
      arrive_at: '"2026-11-02T19:40"',
      items: '[{"item_id":"ramen","quantity":2.0}]',
      address: '"12 Test Street"',
      card_id: '"debit-4242"',
    }),
  });
  assert.equal(two.status, 200);
  const body = await two.json();
  assert.deepEqual(body.items, [{ item_id: "ramen", quantity: 2 }]);
  assert.equal(body.estimated_total_cents, 2 * 1400 + 500);
  // One line, six lines (every menu item once), quantity 1 and 9.
  for (const items of [
    [{ item_id: "lemonade", quantity: 1 }],
    [{ item_id: "lemonade", quantity: 9 }],
    MENU.map((item) => ({ item_id: item.id, quantity: 1 })),
    MENU.map((item) => ({ item_id: item.id, quantity: 9 })),
  ]) {
    const res = await call(valid({ items }));
    assert.equal(res.status, 200, JSON.stringify(items));
    assert.deepEqual((await res.json()).items, items, "the lines are echoed as sent, in order");
  }
  const line = { item_id: "ramen", quantity: 1 };
  const refused = [
    [],
    // Seven lines: the menu holds six items, so this one also repeats or names an unknown item.
    [...MENU.map((item) => ({ item_id: item.id, quantity: 1 })), { item_id: "sushi", quantity: 1 }],
    [...MENU.map((item) => ({ item_id: item.id, quantity: 1 })), line],
    [{ item_id: "ramen", quantity: 0 }],
    [{ item_id: "ramen", quantity: 10 }],
    [{ item_id: "ramen", quantity: -1 }],
    [{ item_id: "ramen", quantity: "2" }],
    [{ item_id: "ramen", quantity: true }],
    [{ item_id: "ramen", quantity: null }],
    [{ item_id: "ramen", quantity: 2.5 }],
    [{ item_id: "ramen", quantity: [2] }],
    [{ item_id: "ramen", quantity: { n: 2 } }],
    [line, { item_id: "ramen", quantity: 2 }],
    [{ item_id: "sushi", quantity: 1 }],
    [{ item_id: "Ramen", quantity: 1 }],
    [{ item_id: "", quantity: 1 }],
    ["ramen"],
    [null],
    [5],
    [[]],
    [{ item_id: "ramen", quantity: 1, note: "x" }],
    [{ item_id: "ramen", quantity: 1, price_cents: 1 }],
    [{ item_id: "ramen" }],
    [{ quantity: 1 }],
    [{}],
    [{ item_id: 5, quantity: 1 }],
    [{ item_id: null, quantity: 1 }],
    [{ item_id: ["ramen"], quantity: 1 }],
    [line, null],
    {},
    { item_id: "ramen", quantity: 1 },
    "ramen:1",
    null,
    5,
    true,
  ];
  for (const items of refused) {
    await expectError(await call(valid({ items })), 400, "invalid_field");
  }
});

test("AC-DELIVERY-001 D11: restaurant is 1 to 80 code points, trimmed, with no hidden characters", async () => {
  const wide = "\u{1D49C}"; // one code point, two UTF-16 units
  const ok80 = await call(valid({ restaurant: wide.repeat(80) }));
  assert.equal(ok80.status, 200);
  assert.equal((await ok80.json()).restaurant, wide.repeat(80));
  await expectError(await call(valid({ restaurant: wide.repeat(81) })), 400, "invalid_field");
  const emoji = await call(valid({ restaurant: "\u{1F355}" }));
  assert.equal(emoji.status, 200);
  const padded = await (await call(valid({ restaurant: "  Test Cafe  " }))).json();
  assert.equal(padded.restaurant, "Test Cafe");
  const padded80 = await call(valid({ restaurant: `  ${"a".repeat(80)}  ` }));
  assert.equal(padded80.status, 200);
  assert.equal((await padded80.json()).restaurant, "a".repeat(80));
  const name = "Café \u{1F355} 食堂 مطعم";
  assert.equal((await (await call(valid({ restaurant: name }))).json()).restaurant, name);
  const refused = [
    "",
    "   ",
    "Test\u0007Cafe",
    "Test​Cafe",
    "Test Cafe",
    "Test Cafe",
    "Test Cafe\n",
    "Test\tCafe",
    5,
    null,
    ["Test Cafe"],
  ];
  for (const restaurant of refused) {
    await expectError(await call(valid({ restaurant })), 400, "invalid_field");
  }
});

test("AC-DELIVERY-001 D12: request_id must be a UUID in the 8-4-4-4-12 form, in either case", async () => {
  assert.equal((await call(valid({ request_id: ID.toUpperCase() }))).status, 200);
  for (const request_id of ["not-a-uuid", `${ID}0`, ` ${ID}`, ID.replaceAll("-", ""), "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6g", 1, null]) {
    await expectError(await call(valid({ request_id })), 400, "invalid_field");
  }
});

test("AC-DELIVERY-002 D13: a valid request makes no outgoing fetch and the source holds no log, storage, clock or random call", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    throw new Error("no outgoing request is allowed");
  };
  try {
    assert.equal((await call(valid())).status, 200);
    assert.equal((await call(valid({ arrive_at: "2026-11-02T23:30" }))).status, 200);
    assert.equal((await call({ op: "options" })).status, 200);
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
  const source = readFileSync(new URL("../src/delivery.js", import.meta.url), "utf8");
  const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\s\/\/.*$/gm, "");
  for (const word of ["console", "fetch", "env", "Date", "KV", "D1", "R2"]) {
    assert.equal(new RegExp(`\\b${word}\\b`).test(code), false, `the source holds ${word}`);
  }
  for (const text of ["Math.random", "getRandomValues"]) {
    assert.equal(code.includes(text), false, `the source holds ${text}`);
  }
  // Positive control: the same scan finds what the file does use.
  assert.equal(code.includes("crypto.subtle"), true);
  assert.equal(/\bfetch\b/.test("await fetch(x)"), true);
  assert.equal(/\bDate\b/.test("new Date()"), true);
  assert.equal(/\benv\b/.test("handle(request, env)"), true);
  // The partner name is written once in this file.
  assert.equal(code.split("Example Delivery").length - 1, 1);
});

test("AC-DELIVERY-002 D14: /delivery is routed next to the others and every answer names the simulated partner", async () => {
  await expectError(await call(null, { method: "GET" }), 405, "method_not_allowed");
  assert.equal((await call(valid(), { path: "/booking" })).status, 400, "the booking route keeps its own shape");
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ choices: [{ index: 0, message: { role: "assistant", content: "{}" }, finish_reason: "stop" }] }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  try {
    const image = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(60, 0x41)]).toString("base64");
    const vision = await worker.fetch(
      new Request("https://x.test/vision", {
        method: "POST",
        headers: { "x-besir-token": "app-test" },
        body: JSON.stringify({ image, mime: "image/jpeg" }),
      }),
      { ...env, BASETEN_API_KEY: "k" },
    );
    assert.notEqual(vision.status, 404);
    assert.notEqual(vision.status, 401);
    const unknown = await worker.fetch(
      new Request("https://x.test/deliveries", { method: "POST", headers: { "x-besir-token": "app-test" }, body: "{}" }),
      env,
    );
    await expectError(unknown, 404, "not_found");
  } finally {
    globalThis.fetch = realFetch;
  }
  for (const body of [valid({ arrive_at: "2026-11-02T19:40" }), valid({ arrive_at: "2026-11-02T23:30" }), { op: "options" }]) {
    const res = await call(body);
    assert.equal(res.status, 200);
    const answer = await res.json();
    assert.equal(answer.partner, "Example Delivery");
    assert.equal(answer.simulated, true);
  }
});

test("AC-DELIVERY-002 D15: the options answer holds exactly five keys and the fixed tables", async () => {
  const res = await call({ op: "options" });
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), ["cards", "delivery_fee_cents", "menu", "partner", "simulated"]);
  assert.equal(body.partner, "Example Delivery");
  assert.equal(body.simulated, true);
  assert.deepEqual(body.menu, MENU);
  assert.deepEqual(body.cards, CARDS);
  assert.equal(body.delivery_fee_cents, FEE);
  assert.equal(body.menu.length, 6);
  assert.equal(body.cards.length, 2);
  for (const entry of body.menu) {
    assert.deepEqual(Object.keys(entry).sort(), ["id", "name", "price_cents"]);
    assert.match(entry.id, /^[a-z]+$/);
    assert.match(entry.name, /^[\x20-\x7e]+$/);
    assert.equal(Number.isInteger(entry.price_cents), true);
    assert.equal(entry.price_cents >= 400 && entry.price_cents <= 2500, true);
  }
  const prices = body.menu.map((entry) => entry.price_cents);
  assert.equal(Math.min(...prices), 400);
  assert.equal(Math.max(...prices), 2500);
  for (const entry of body.cards) {
    assert.deepEqual(Object.keys(entry).sort(), ["id", "label"]);
    assert.match(entry.id, /^[a-z0-9-]+$/);
    assert.match(entry.label, /\(Simulated\)$/);
  }
  assert.equal(JSON.stringify(body).includes("\u2022\u2022"), true, "the card labels hold the bullet characters");
  const wording = /calorie|kcal|nutrition|health|diet|vitamin/i;
  for (const entry of [...body.menu.map((item) => item.name), ...body.cards.map((card) => card.label)]) {
    assert.equal(wording.test(entry), false, entry);
  }
  // The same answer every time.
  assert.deepEqual(await (await call({ op: "options" })).json(), body);
  // An options request with a key of the order shape is invalid; with the old `people` key it is unknown.
  await expectError(await call({ op: "options", items: LINES }), 400, "invalid_field");
  await expectError(await call({ op: "options", request_id: ID }), 400, "invalid_field");
  await expectError(await call({ op: "options", people: 2 }), 400, "unknown_field");
});

test("AC-DELIVERY-001 D16: address is 1 to 120 code points and card_id names one of the two cards", async () => {
  const wide = "\u{1D49C}"; // one code point, two UTF-16 units
  const ok120 = await call(valid({ address: wide.repeat(120) }));
  assert.equal(ok120.status, 200);
  assert.equal((await ok120.json()).address, wide.repeat(120));
  await expectError(await call(valid({ address: wide.repeat(121) })), 400, "invalid_field");
  assert.equal((await call(valid({ address: "a".repeat(120) }))).status, 200);
  await expectError(await call(valid({ address: "a".repeat(121) })), 400, "invalid_field");
  const padded = await (await call(valid({ address: "  12 Test Street  " }))).json();
  assert.equal(padded.address, "12 Test Street");
  const padded120 = await call(valid({ address: `  ${"a".repeat(120)}  ` }));
  assert.equal(padded120.status, 200);
  assert.equal((await padded120.json()).address, "a".repeat(120));
  const mixed = "Caf\u00e9 \u{1F355} 12, Test Street";
  assert.equal((await (await call(valid({ address: mixed }))).json()).address, mixed);
  const refused = [
    "",
    "   ",
    "12 Test\u0007Street",
    "12 Test\u200bStreet",
    "12 Test\u2028Street",
    "12 Test\u2029Street",
    "12 Test Street\n",
    "12 Test\tStreet",
    5,
    null,
    ["12 Test Street"],
  ];
  for (const address of refused) {
    await expectError(await call(valid({ address })), 400, "invalid_field");
  }
  for (const card of CARDS) {
    const body = await (await call(valid({ card_id: card.id }))).json();
    assert.equal(body.status, "confirmed");
    assert.equal(body.card_id, card.id);
  }
  for (const card_id of ["", "nope", "DEBIT-4242", "Credit-1881", " debit-4242", "debit-4242 ", "debit-4243", 5, null, ["debit-4242"]]) {
    await expectError(await call(valid({ card_id })), 400, "invalid_field");
  }
});
