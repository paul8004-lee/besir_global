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
  party_size: 2,
  start: "2026-11-02T19:00",
  ...over,
});

// A body object is JSON-encoded; `raw` sends the string as it is.
const call = (body, { token = "app-test", raw, method = "POST", e = env } = {}) =>
  worker.fetch(
    new Request("https://x.test/booking", {
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

test("AC-BOOKING-001 B01: 401 for no token, a wrong token and no APP_TOKEN, before the body is read", async () => {
  const unreadable = (token) => ({
    method: "POST",
    url: "https://x.test/booking",
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

test("AC-BOOKING-002 B02: a valid request answers exactly the documented keys with the trimmed echoes", async () => {
  const res = await call(valid({ restaurant: "  Test Cafe  " }));
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), [
    "partner",
    "party_size",
    "reservation_code",
    "restaurant",
    "simulated",
    "start",
    "status",
  ]);
  assert.equal(body.status, "confirmed");
  assert.equal(body.restaurant, "Test Cafe");
  assert.equal(body.party_size, 2);
  assert.equal(body.start, "2026-11-02T19:00");
});

test("AC-BOOKING-002 B03: the code has the documented shape and depends on request_id alone", async () => {
  const a = await (await call(valid())).json();
  const b = await (await call(valid())).json();
  assert.match(a.reservation_code, /^EX-[A-Z0-9]{6}$/);
  assert.deepEqual(a, b);
  const other = await (await call(valid({ request_id: ID2 }))).json();
  assert.match(other.reservation_code, /^EX-[A-Z0-9]{6}$/);
  assert.notEqual(other.reservation_code, a.reservation_code);
  // Other fields do not change the code; the case of the id does not either.
  const changed = await (await call(valid({ restaurant: "Another", party_size: 4, start: "2027-01-05T08:30" }))).json();
  assert.equal(changed.reservation_code, a.reservation_code);
  const upper = await (await call(valid({ request_id: ID.toUpperCase() }))).json();
  assert.equal(upper.reservation_code, a.reservation_code);
});

test("AC-BOOKING-002 B04: a party of 8 is confirmed, 9 and 12 are declined with no_table and no code", async () => {
  const eight = await (await call(valid({ party_size: 8 }))).json();
  assert.equal(eight.status, "confirmed");
  assert.equal("reason" in eight, false);
  for (const size of [9, 12]) {
    const res = await call(valid({ party_size: size }));
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, "declined");
    assert.equal(body.reason, "no_table");
    assert.equal("reservation_code" in body, false);
    assert.deepEqual(Object.keys(body).sort(), ["partner", "party_size", "reason", "restaurant", "simulated", "start", "status"]);
  }
});

test("AC-BOOKING-001 B05: every invalid value is 400 invalid_field and the edges are accepted", async () => {
  const wide = "\u{1D49C}"; // one code point, two UTF-16 units
  const refused = [
    ["party 0", valid({ party_size: 0 })],
    ["party 13", valid({ party_size: 13 })],
    ["party 2.5", valid({ party_size: 2.5 })],
    ["party string", valid({ party_size: "2" })],
    ["party true", valid({ party_size: true })],
    ["party null", valid({ party_size: null })],
    ["restaurant empty", valid({ restaurant: "" })],
    ["restaurant spaces", valid({ restaurant: "   " })],
    ["restaurant 81 code points", valid({ restaurant: wide.repeat(81) })],
    ["restaurant not a string", valid({ restaurant: 5 })],
    ["restaurant control", valid({ restaurant: "Test\u0007Cafe" })],
    ["restaurant zero-width", valid({ restaurant: "Test​Cafe" })],
    ["restaurant U+2028", valid({ restaurant: "Test Cafe" })],
    ["restaurant trailing newline", valid({ restaurant: "Test Cafe\n" })],
    ["start Feb 29 2026", valid({ start: "2026-02-29T19:00" })],
    ["start Feb 30", valid({ start: "2026-02-30T19:00" })],
    ["start with a space", valid({ start: "2026-11-02 19:00" })],
    ["start hour 24", valid({ start: "2026-11-02T24:00" })],
    ["start with seconds", valid({ start: "2026-11-02T19:00:00" })],
    ["start month 13", valid({ start: "2026-13-02T19:00" })],
    ["start month 0", valid({ start: "2026-00-02T19:00" })],
    ["start day 0", valid({ start: "2026-11-00T19:00" })],
    ["start minute 60", valid({ start: "2026-11-02T19:60" })],
    ["start April 31", valid({ start: "2026-04-31T19:00" })],
    ["start Feb 29 2100", valid({ start: "2100-02-29T19:00" })],
    ["start not a string", valid({ start: 20261102 })],
    ["request_id not a UUID", valid({ request_id: "not-a-uuid" })],
    ["request_id with a suffix", valid({ request_id: `${ID}0` })],
    ["request_id not a string", valid({ request_id: 1 })],
  ];
  for (const [name, body] of refused) {
    const res = await call(body);
    assert.equal(res.status, 400, name);
    assert.deepEqual(await res.json(), { error: "invalid_field" }, name);
  }
  const accepted = [
    ["restaurant of 80 code points", valid({ restaurant: wide.repeat(80) })],
    ["party 2.0", { raw: `{"request_id":"${ID}","restaurant":"Test Cafe","party_size":2.0,"start":"2026-11-02T19:00"}` }],
    ["leap day 2028", valid({ start: "2028-02-29T19:00" })],
    ["leap day 2000", valid({ start: "2000-02-29T19:00" })],
    ["Feb 28 2100", valid({ start: "2100-02-28T19:00" })],
    ["last minute of a day", valid({ start: "2026-12-31T23:59" })],
    ["party 1", valid({ party_size: 1 })],
  ];
  for (const [name, input] of accepted) {
    const res = "raw" in input ? await call(null, { raw: input.raw }) : await call(input);
    assert.equal(res.status, 200, name);
  }
});

test("AC-BOOKING-001 B06: the order of the faults is extra key, missing key, then values", async () => {
  await expectError(await call({ ...valid(), name: "x" }), 400, "unknown_field");
  const { start, ...noStart } = valid();
  await expectError(await call(noStart), 400, "missing_field");
  await expectError(await call({ ...valid({ party_size: 99 }), phone: "1" }), 400, "unknown_field");
  await expectError(await call({ request_id: ID, restaurant: "", party_size: 99 }), 400, "missing_field");
  await expectError(await call({}), 400, "missing_field");
});

test("AC-BOOKING-001 B07: not JSON, an array and an over-long body", async () => {
  await expectError(await call(null, { raw: "not json" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "[1,2]" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "null" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "5" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "x".repeat(4097) }), 413, "body_too_large");
  await expectError(await call(null, { raw: "x".repeat(4096) }), 400, "invalid_json");
});

test("AC-BOOKING-002 B08: the restaurant is trimmed in the answer", async () => {
  const body = await (await call(valid({ restaurant: "  Test Cafe  " }))).json();
  assert.equal(body.restaurant, "Test Cafe");
});

test("AC-BOOKING-001 B09: a GET is 405 and a valid request makes no outgoing fetch", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return new Response("{}");
  };
  try {
    const get = await call(null, { method: "GET" });
    await expectError(get, 405, "method_not_allowed");
    const res = await call(valid());
    assert.equal(res.status, 200);
    await call(valid({ party_size: 9 }));
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-BOOKING-001 B10: an emoji and a non-Latin script are accepted and echoed", async () => {
  const name = "Café \u{1F355} 食堂 مطعم";
  const body = await (await call(valid({ restaurant: name }))).json();
  assert.equal(body.status, "confirmed");
  assert.equal(body.restaurant, name);
});

test("AC-BOOKING-002 B11: the route source holds no log, storage, fetch, clock or random call", async () => {
  const source = readFileSync(new URL("../src/booking.js", import.meta.url), "utf8");
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
  assert.equal(code.split("Example Tables").length - 1, 1);
});

test("AC-BOOKING-001 B12: /booking is routed after the token check and the other routes still answer", async () => {
  for (const path of ["/ai", "/places", "/routes", "/vision", "/booking"]) {
    const res = await worker.fetch(
      new Request(`https://x.test${path}`, { method: "POST", headers: { "x-besir-token": "nope" }, body: "{}" }),
      env,
    );
    await expectError(res, 401, "unauthorized");
  }
  assert.equal((await call(valid())).status, 200, "a valid token reaches the booking route");
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
      new Request("https://x.test/bookings", { method: "POST", headers: { "x-besir-token": "app-test" }, body: "{}" }),
      env,
    );
    await expectError(unknown, 404, "not_found");
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-BOOKING-002 B13: a confirmation and a decline both say who the partner is and that it is simulated", async () => {
  for (const size of [2, 9]) {
    const body = await (await call(valid({ party_size: size }))).json();
    assert.equal(body.partner, "Example Tables");
    assert.equal(body.simulated, true);
  }
});
