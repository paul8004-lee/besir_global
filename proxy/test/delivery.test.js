import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: "g" };
const ID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b";
const ID2 = "9a1d4c7e-2b3f-4a50-8c61-7d8e9f0a1b2c";
const valid = (over = {}) => ({
  request_id: ID,
  restaurant: "Test Cafe",
  people: 2,
  arrive_at: "2026-11-02T19:40",
  ...over,
});

const CONFIRMED_KEYS = [
  "arrival_estimate",
  "arrive_at",
  "estimated_total_cents",
  "order_id",
  "partner",
  "people",
  "restaurant",
  "simulated",
  "status",
];
const DECLINED_KEYS = ["arrive_at", "partner", "people", "reason", "restaurant", "simulated", "status"];

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

test("AC-DELIVERY-002 D03: a request at 19:40 gives exactly the nine keys of a confirmed order", async () => {
  const res = await call(valid({ restaurant: "  Test Cafe  " }));
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), CONFIRMED_KEYS);
  assert.equal(body.status, "confirmed");
  assert.equal(body.partner, "Example Delivery");
  assert.equal(body.simulated, true);
  assert.equal(body.restaurant, "Test Cafe");
  assert.equal(body.people, 2);
  assert.equal(body.arrive_at, "2026-11-02T19:40");
  assert.equal(body.arrival_estimate, "2026-11-02T19:40");
  assert.equal(body.estimated_total_cents, 4900);
  assert.match(body.order_id, /^DL-[A-Z0-9]{6}$/);
});

test("AC-DELIVERY-002 D04: a request at 23:30 gives exactly the seven keys of a declined order", async () => {
  const res = await call(valid({ arrive_at: "2026-11-02T23:30" }));
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), DECLINED_KEYS);
  assert.equal(body.status, "declined");
  assert.equal(body.reason, "outside_hours");
  assert.equal(body.partner, "Example Delivery");
  assert.equal(body.simulated, true);
  assert.equal(body.restaurant, "Test Cafe");
  assert.equal(body.people, 2);
  assert.equal(body.arrive_at, "2026-11-02T23:30");
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

test("AC-DELIVERY-002 D06: the estimated total is people x 2200 + 500 cents, always an integer", async () => {
  for (const [people, cents] of [
    [1, 2700],
    [2, 4900],
    [12, 26900],
  ]) {
    const body = await (await call(valid({ people }))).json();
    assert.equal(body.estimated_total_cents, cents, `people ${people}`);
    assert.equal(Number.isInteger(body.estimated_total_cents), true);
    assert.equal(body.estimated_total_cents, people * 2200 + 500);
  }
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
  const changed = await (await call(valid({ restaurant: "Another", people: 4, arrive_at: "2027-01-05T12:30" }))).json();
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
  await expectError(await call({ ...valid(), address: "x" }), 400, "unknown_field");
  for (const key of ["request_id", "restaurant", "people", "arrive_at"]) {
    const { [key]: removed, ...rest } = valid();
    await expectError(await call(rest), 400, "missing_field");
  }
  await expectError(await call({}), 400, "missing_field");
  await expectError(await call(valid({ people: 13 })), 400, "invalid_field");
  // Unknown beats missing, and missing beats invalid.
  const { arrive_at, ...noTime } = valid();
  await expectError(await call({ ...noTime, name: "x" }), 400, "unknown_field");
  await expectError(await call({ ...valid({ people: 99 }), phone: "1" }), 400, "unknown_field");
  await expectError(await call({ request_id: ID, restaurant: "", people: 99 }), 400, "missing_field");
  await expectError(await call(valid({ people: 99, arrive_at: "bad" })), 400, "invalid_field");
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

test("AC-DELIVERY-001 D10: people accepts whole numbers from 1 to 12 and refuses the rest", async () => {
  const two = await call(null, {
    raw: rawBody({ request_id: JSON.stringify(ID), restaurant: '"Test Cafe"', people: "2.0", arrive_at: '"2026-11-02T19:40"' }),
  });
  assert.equal(two.status, 200);
  const body = await two.json();
  assert.equal(body.people, 2);
  assert.equal(body.estimated_total_cents, 4900);
  for (const people of [1, 12]) {
    assert.equal((await call(valid({ people }))).status, 200, `people ${people}`);
  }
  for (const people of [0, 13, -1, "2", true, null, 2.5, [2], { n: 2 }]) {
    await expectError(await call(valid({ people })), 400, "invalid_field");
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
  for (const arrive_at of ["2026-11-02T19:40", "2026-11-02T23:30"]) {
    const res = await call(valid({ arrive_at }));
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.partner, "Example Delivery");
    assert.equal(body.simulated, true);
  }
});
