import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: "g" };
const ID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b";
const ID2 = "9a1d4c7e-2b3f-4a50-8c61-7d8e9f0a1b2c";
const values = (over = {}) => ({
  restaurant: "Test Cafe",
  party_size: 2,
  start: "2026-11-02T19:00",
  name: "Sam",
  ...over,
});
// The submit shape: `over` changes the values, `top` the keys beside them.
const valid = (over = {}, top = {}) => ({ op: "submit", request_id: ID, values: values(over), ...top });
const without = (object, key) => {
  const { [key]: dropped, ...rest } = object;
  return rest;
};

const FIELDS = [
  { key: "restaurant", kind: "place", label: "Restaurant", lookup: true },
  { key: "party_size", kind: "number", label: "Party size" },
  { key: "start", kind: "time", label: "Time" },
  { key: "name", kind: "text", label: "Name" },
  { key: "note", kind: "text", label: "Note", optional: true },
];
const RESULT_FIELDS = [
  { name: "Booking time", kind: "time" },
  { name: "Reservation number", kind: "text" },
  { name: "Estimated cost", kind: "money" },
  { name: "Partner note", kind: "text" },
];
const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

// The code, computed here from the rule and not by the route: SHA-256 of the lower-cased id, six bytes, each mod 36.
function expectedCode(id) {
  const bytes = createHash("sha256").update(id.toLowerCase()).digest().subarray(0, 6);
  return "EX-" + Array.from(bytes, (byte) => ALPHABET[byte % 36]).join("");
}

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

const itemOf = (body, name) => body.results.find((item) => item.name === name);

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

test("AC-BOOKING-002 B02: a valid submit answers exactly four keys and echoes no free text", async () => {
  const secret = {
    restaurant: "  Zq-restaurant-7731  ",
    name: "  Zq-name-4408  ",
    note: "  Zq-note-9152  ",
  };
  const res = await call(valid(secret));
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const text = await res.text();
  const body = JSON.parse(text);
  assert.deepEqual(Object.keys(body), ["status", "partner", "simulated", "results"]);
  assert.equal(body.status, "confirmed");
  assert.equal("reservation_code" in body, false);
  assert.equal(text.includes("reservation_code"), false);
  // The free text of the request is nowhere in the answer, trimmed or not.
  for (const sentinel of ["Zq-restaurant-7731", "Zq-name-4408", "Zq-note-9152"]) {
    assert.equal(text.includes(sentinel), false, `the answer holds ${sentinel}`);
  }
  // The only request values in the answer are the start in the time item and the amount from the party size.
  assert.deepEqual(body, {
    status: "confirmed",
    partner: "Example Tables",
    simulated: true,
    results: [
      { name: "Booking time", kind: "time", value: "2026-11-02T19:00" },
      { name: "Reservation number", kind: "text", value: expectedCode(ID) },
      { name: "Estimated cost", kind: "money", value: 6000 },
      { name: "Partner note", kind: "text", value: "Table held for 15 minutes" },
    ],
  });
});

test("AC-BOOKING-002 B03: the reservation number has the documented shape and depends on request_id alone", async () => {
  const a = await (await call(valid())).json();
  const b = await (await call(valid())).json();
  const code = itemOf(a, "Reservation number").value;
  assert.match(code, /^EX-[A-Z0-9]{6}$/);
  assert.equal(code, expectedCode(ID));
  assert.deepEqual(a, b);
  const other = await (await call(valid({}, { request_id: ID2 }))).json();
  assert.match(itemOf(other, "Reservation number").value, /^EX-[A-Z0-9]{6}$/);
  assert.equal(itemOf(other, "Reservation number").value, expectedCode(ID2));
  assert.notEqual(itemOf(other, "Reservation number").value, code);
  // Other fields do not change the number; the case of the id does not either.
  const changed = await (await call(valid({ restaurant: "Another", party_size: 4, start: "2027-01-05T08:30", name: "Kim", note: "Quiet" }))).json();
  assert.equal(itemOf(changed, "Reservation number").value, code);
  const upper = await (await call(valid({}, { request_id: ID.toUpperCase() }))).json();
  assert.equal(itemOf(upper, "Reservation number").value, code);
});

test("AC-BOOKING-002 B04: a party of 8 is confirmed, 9 and 12 are declined with no_table and no results", async () => {
  const eight = await (await call(valid({ party_size: 8 }))).json();
  assert.equal(eight.status, "confirmed");
  assert.equal("reason" in eight, false);
  for (const size of [9, 12]) {
    const res = await call(valid({ party_size: size }));
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(Object.keys(body), ["status", "partner", "simulated", "reason"]);
    assert.equal(body.status, "declined");
    assert.equal(body.reason, "no_table");
    assert.equal("results" in body, false);
    assert.equal("reservation_code" in body, false);
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
    ["restaurant 121 code points", valid({ restaurant: wide.repeat(121) })],
    ["restaurant not a string", valid({ restaurant: 5 })],
    ["restaurant control", valid({ restaurant: "Test\u0007Cafe" })],
    ["restaurant zero-width", valid({ restaurant: "Test​Cafe" })],
    ["restaurant U+2028", valid({ restaurant: "Test Cafe" })],
    ["restaurant trailing newline", valid({ restaurant: "Test Cafe\n" })],
    ["name empty", valid({ name: "" })],
    ["name spaces", valid({ name: "   " })],
    ["name 121 code points", valid({ name: wide.repeat(121) })],
    ["name not a string", valid({ name: 5 })],
    ["name control", valid({ name: "Sa\u0007m" })],
    ["name zero-width", valid({ name: "Sa​m" })],
    ["note empty", valid({ note: "" })],
    ["note spaces", valid({ note: "   " })],
    ["note 121 code points", valid({ note: wide.repeat(121) })],
    ["note not a string", valid({ note: 5 })],
    ["note null", valid({ note: null })],
    ["note zero-width", valid({ note: "Quiet​table" })],
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
    ["start year 1999", valid({ start: "1999-12-31T23:59" })],
    ["start year 2200", valid({ start: "2200-01-01T00:00" })],
    ["start not a string", valid({ start: 20261102 })],
    ["request_id not a UUID", valid({}, { request_id: "not-a-uuid" })],
    ["request_id with a suffix", valid({}, { request_id: `${ID}0` })],
    ["request_id not a string", valid({}, { request_id: 1 })],
  ];
  for (const [name, body] of refused) {
    const res = await call(body);
    assert.equal(res.status, 400, name);
    assert.deepEqual(await res.json(), { error: "invalid_field" }, name);
  }
  const accepted = [
    ["restaurant of 120 code points", valid({ restaurant: wide.repeat(120) })],
    ["restaurant of 81 code points", valid({ restaurant: wide.repeat(81) })],
    ["name of 120 code points", valid({ name: wide.repeat(120) })],
    ["note of 120 code points", valid({ note: wide.repeat(120) })],
    ["leap day 2028", valid({ start: "2028-02-29T19:00" })],
    ["leap day 2000", valid({ start: "2000-02-29T19:00" })],
    ["Feb 28 2100", valid({ start: "2100-02-28T19:00" })],
    ["first minute of 2000", valid({ start: "2000-01-01T00:00" })],
    ["last minute of 2199", valid({ start: "2199-12-31T23:59" })],
    ["last minute of a day", valid({ start: "2026-12-31T23:59" })],
    ["party 1", valid({ party_size: 1 })],
    ["party 8", valid({ party_size: 8 })],
    ["party 12", valid({ party_size: 12 })],
    ["a request_id in capitals", valid({}, { request_id: ID.toUpperCase() })],
    ["party 2.0", { raw: `{"op":"submit","request_id":"${ID}","values":{"restaurant":"Test Cafe","party_size":2.0,"start":"2026-11-02T19:00","name":"Sam"}}` }],
  ];
  for (const [name, input] of accepted) {
    const res = "raw" in input ? await call(null, { raw: input.raw }) : await call(input);
    assert.equal(res.status, 200, name);
  }
});

test("AC-BOOKING-001 B06: the order of the faults, step by step, with two faults at once for each adjacent pair", async () => {
  // (1) a key outside op, request_id, values: unknown_field, before every other fault.
  await expectError(await call({ ...valid(), x: 1 }), 400, "unknown_field");
  await expectError(await call(valid({}, { op: "cancel", x: 1 })), 400, "unknown_field");
  await expectError(await call({ request_id: ID, values: values(), x: 1 }), 400, "unknown_field");
  // (2) an op that is neither fields nor submit: invalid_field, before a missing key.
  await expectError(await call(valid({}, { op: "cancel" })), 400, "invalid_field");
  await expectError(await call({ op: "cancel", values: values() }), 400, "invalid_field");
  await expectError(await call({ op: 5 }), 400, "invalid_field");
  // (3) no op, or a key the op requires missing: missing_field, before a key the op does not allow.
  await expectError(await call({ request_id: ID, values: values() }), 400, "missing_field");
  await expectError(await call({ op: "submit", values: values() }), 400, "missing_field");
  await expectError(await call({ op: "submit", request_id: ID }), 400, "missing_field");
  await expectError(await call({ op: "submit", request_id: "not-a-uuid" }), 400, "missing_field");
  await expectError(await call({}), 400, "missing_field");
  // (4) a key the op does not allow: invalid_field, before the values are looked at.
  await expectError(await call({ op: "fields", request_id: ID }), 400, "invalid_field");
  await expectError(await call({ op: "fields", values: values() }), 400, "invalid_field");
  await expectError(await call({ op: "fields", values: { phone: "1" } }), 400, "invalid_field");
  await expectError(await call({ op: "fields", values: {} }), 400, "invalid_field");
  // (5) values that is not an object: invalid_field, before the keys of values are read.
  await expectError(await call(valid({}, { values: ["restaurant"] })), 400, "invalid_field");
  await expectError(await call(valid({}, { values: [] })), 400, "invalid_field");
  await expectError(await call(valid({}, { values: null })), 400, "invalid_field");
  await expectError(await call(valid({}, { values: "restaurant" })), 400, "invalid_field");
  // (6) a key of values outside the five: unknown_field, before a missing key or a wrong value.
  await expectError(await call(valid({ phone: "1" })), 400, "unknown_field");
  await expectError(await call(valid({ phone: "1", party_size: 99 })), 400, "unknown_field");
  await expectError(await call(valid({}, { values: { phone: "1" } })), 400, "unknown_field");
  // (7) a required key of values missing: missing_field, before a wrong value.
  await expectError(await call(valid({}, { values: without(values(), "name") })), 400, "missing_field");
  await expectError(await call(valid({}, { values: without(values({ party_size: 99 }), "name") })), 400, "missing_field");
  await expectError(await call(valid({}, { values: {} })), 400, "missing_field");
  await expectError(await call(valid({}, { request_id: "not-a-uuid", values: without(values(), "start") })), 400, "missing_field");
  // (8) a wrong type or range: invalid_field.
  await expectError(await call(valid({ party_size: 99 })), 400, "invalid_field");
  await expectError(await call(valid({}, { request_id: "not-a-uuid" })), 400, "invalid_field");
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

test("AC-BOOKING-001 B09: a GET is 405 and a valid submit or fields request makes no outgoing fetch", async () => {
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
    assert.equal((await res.json()).status, "confirmed");
    await call(valid({ party_size: 9 }));
    await call({ op: "fields" });
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-BOOKING-001 B10: an emoji and a non-Latin script are accepted in restaurant, name and note", async () => {
  const mixed = "Café \u{1F355} 食堂 مطعم";
  const res = await call(valid({ restaurant: mixed, name: mixed, note: mixed }));
  assert.equal(res.status, 200);
  const text = await res.text();
  assert.equal(JSON.parse(text).status, "confirmed");
  // Nothing is read back.
  assert.equal(text.includes("食堂"), false);
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

test("AC-BOOKING-001 B12: /booking and /partners are routed after the token check and the other routes still answer", async () => {
  for (const path of ["/ai", "/places", "/routes", "/vision", "/booking", "/partners"]) {
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

test("AC-BOOKING-002 B13: every answer says who the partner is and that it is simulated", async () => {
  for (const size of [2, 9]) {
    const body = await (await call(valid({ party_size: size }))).json();
    assert.equal(body.partner, "Example Tables");
    assert.equal(body.simulated, true);
  }
  const fields = await (await call({ op: "fields" })).json();
  assert.equal(fields.partner, "Example Tables");
  assert.equal(fields.simulated, true);
});

test("AC-BOOKING-003 B14: the fields request answers four keys, the five fields and the four result items, the same every time", async () => {
  const res = await call({ op: "fields" });
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const text = await res.text();
  const body = JSON.parse(text);
  assert.deepEqual(Object.keys(body), ["partner", "simulated", "fields", "result_fields"]);
  assert.equal(body.partner, "Example Tables");
  assert.equal(body.simulated, true);
  assert.deepEqual(body.fields.map((field) => field.key), ["restaurant", "party_size", "start", "name", "note"]);
  for (const field of body.fields) {
    const want =
      field.key === "note"
        ? ["key", "kind", "label", "optional"]
        : field.key === "restaurant"
          ? ["key", "kind", "label", "lookup"]
          : ["key", "kind", "label"];
    assert.deepEqual(Object.keys(field), want, field.key);
  }
  assert.deepEqual(body.fields, FIELDS);
  assert.deepEqual(body.result_fields, RESULT_FIELDS);
  for (const item of body.result_fields) assert.deepEqual(Object.keys(item), ["name", "kind"]);
  // The text pins every key order at once, and the answer is the same again.
  assert.equal(text, JSON.stringify({ partner: "Example Tables", simulated: true, fields: FIELDS, result_fields: RESULT_FIELDS }));
  assert.equal(await (await call({ op: "fields" })).text(), text);
});

// An independent reading of the grammar the app applies to a field list and a result list.
function fieldListProblems(list) {
  const problems = [];
  if (!Array.isArray(list) || list.length < 1 || list.length > 8) return ["the list is not 1 to 8 fields"];
  const keys = new Set();
  for (const field of list) {
    if (field === null || typeof field !== "object" || Array.isArray(field)) {
      problems.push("a field is not an object");
      continue;
    }
    const names = Object.keys(field);
    if (typeof field.key !== "string" || !/^[a-z_]{1,32}$/.test(field.key)) problems.push("bad key");
    if (keys.has(field.key)) problems.push("repeated key");
    keys.add(field.key);
    if (!["text", "place", "time", "pick_one", "on_off", "number"].includes(field.kind)) problems.push("bad kind");
    if (typeof field.label !== "string" || [...field.label].length < 1 || [...field.label].length > 40 || /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(field.label)) {
      problems.push("bad label");
    }
    const hasOptions = field.kind === "pick_one" || field.kind === "on_off";
    if (hasOptions !== names.includes("options")) problems.push("options do not match the kind");
    const allowed = ["key", "kind", "label", "options", "optional", "lookup"];
    if (names.some((name) => !allowed.includes(name))) problems.push("an unknown key");
    if (names.includes("optional")) {
      if (field.optional !== true) problems.push("optional is not true");
      if (field.kind === "on_off") problems.push("optional on a switch");
      if (names[names.length - 1] !== "optional") problems.push("optional is not last");
    }
    if (names.includes("lookup")) {
      if (field.lookup !== true) problems.push("lookup is not true");
      if (field.kind !== "place") problems.push("lookup on a field that is not a place");
      if (names[names.length - 1] !== "lookup") problems.push("lookup is not last");
      if (names.includes("optional")) problems.push("lookup beside optional");
    }
  }
  return problems;
}
function resultListProblems(list) {
  const problems = [];
  if (!Array.isArray(list) || list.length < 1 || list.length > 8) return ["the list is not 1 to 8 items"];
  for (const item of list) {
    if (Object.keys(item).join() !== "name,kind") problems.push("an item has other keys");
    if (typeof item.name !== "string" || !/^[\x20-\x7E]{1,40}$/.test(item.name)) problems.push("bad name");
    if (!["time", "money", "text"].includes(item.kind)) problems.push("bad kind");
  }
  if (list.filter((item) => item.kind === "time").length > 1) problems.push("two time items");
  if (list.filter((item) => item.kind === "money").length > 1) problems.push("two money items");
  return problems;
}

test("AC-BOOKING-003 B15: an independent validator accepts the fields answer and refuses planted defects", async () => {
  const body = await (await call({ op: "fields" })).json();
  assert.deepEqual(fieldListProblems(body.fields), []);
  assert.deepEqual(resultListProblems(body.result_fields), []);

  // The validator fires on each planted defect.
  const note = FIELDS[4];
  const swap = (field) => [...FIELDS.slice(0, 4), field];
  const swapFirst = (field) => [field, ...FIELDS.slice(1)];
  const planted = [
    ["optional false", swap({ ...note, optional: false })],
    ["optional as text", swap({ ...note, optional: "true" })],
    ["optional on a switch", swap({ key: "tick", kind: "on_off", label: "Tick", options: [{ id: "true", label: "Yes" }, { id: "false", label: "No" }], optional: true })],
    ["a number field with options", swap({ key: "size", kind: "number", label: "Size", options: [{ id: "a", label: "A" }] })],
    ["optional not last", swap({ key: "note", kind: "text", optional: true, label: "Note" })],
    ["a repeated key", [...FIELDS, { key: "name", kind: "text", label: "Again" }]],
    ["an unknown kind", swap({ key: "size", kind: "integer", label: "Size" })],
    ["a key with an upper-case letter", swap({ key: "Size", kind: "text", label: "Size" })],
    ["nine fields", Array.from({ length: 9 }, (_, i) => ({ key: "k".repeat(i + 1), kind: "text", label: "L" }))],
    ["no field", []],
    ["lookup false", swapFirst({ ...FIELDS[0], lookup: false })],
    ["lookup on a text field", swapFirst({ key: "restaurant", kind: "text", label: "Restaurant", lookup: true })],
    ["lookup not last", swapFirst({ key: "restaurant", kind: "place", lookup: true, label: "Restaurant" })],
    ["lookup beside optional", swapFirst({ key: "restaurant", kind: "place", label: "Restaurant", lookup: true, optional: true })],
  ];
  for (const [name, list] of planted) {
    assert.notDeepEqual(fieldListProblems(list), [], `the field validator misses ${name}`);
  }
  const plantedResults = [
    ["nine result items", Array.from({ length: 9 }, (_, i) => ({ name: `Item ${i}`, kind: "text" }))],
    ["a second time item", [...RESULT_FIELDS, { name: "Other time", kind: "time" }]],
    ["a second money item", [...RESULT_FIELDS, { name: "Other cost", kind: "money" }]],
    ["an unknown kind", [{ name: "Item", kind: "number" }]],
    ["a name of 41 characters", [{ name: "N".repeat(41), kind: "text" }]],
    ["a non-ASCII name", [{ name: "Café", kind: "text" }]],
    ["an extra key", [{ name: "Item", kind: "text", value: "x" }]],
    ["no item", []],
  ];
  for (const [name, list] of plantedResults) {
    assert.notDeepEqual(resultListProblems(list), [], `the result validator misses ${name}`);
  }
});

test("AC-BOOKING-004 B16: the results are the announced items in order with the start, the cost and the fixed note", async () => {
  const fields = await (await call({ op: "fields" })).json();
  for (const size of [1, 2, 5, 8]) {
    const body = await (await call(valid({ party_size: size, start: "2027-03-04T08:15" }))).json();
    assert.deepEqual(
      body.results.map(({ name, kind }) => ({ name, kind })),
      fields.result_fields,
    );
    for (const item of body.results) assert.deepEqual(Object.keys(item), ["name", "kind", "value"]);
    assert.equal(itemOf(body, "Booking time").value, "2027-03-04T08:15");
    const cost = itemOf(body, "Estimated cost").value;
    assert.equal(Number.isInteger(cost), true);
    assert.equal(cost, size * 3000);
    assert.equal(itemOf(body, "Partner note").value, "Table held for 15 minutes");
  }
});

test("AC-BOOKING-003 B17: the rules of values", async () => {
  // Each required key missing.
  for (const key of ["restaurant", "party_size", "start", "name"]) {
    await expectError(await call(valid({}, { values: without(values(), key) })), 400, "missing_field");
  }
  // note is optional: absent is accepted, blank is refused.
  assert.equal((await call(valid({}, { values: without(values({ note: "x" }), "note") }))).status, 200);
  assert.equal((await call(valid({ note: "Quiet table" }))).status, 200);
  await expectError(await call(valid({ note: "" })), 400, "invalid_field");
  await expectError(await call(valid({ note: "  " })), 400, "invalid_field");
  // Types and ranges.
  await expectError(await call(valid({ party_size: "2" })), 400, "invalid_field");
  await expectError(await call(valid({ party_size: 0 })), 400, "invalid_field");
  await expectError(await call(valid({ party_size: 13 })), 400, "invalid_field");
  await expectError(await call(valid({ restaurant: 7 })), 400, "invalid_field");
  await expectError(await call(valid({ start: "2026-02-30T19:00" })), 400, "invalid_field");
  // An unknown key of values, however good the rest is.
  await expectError(await call(valid({ phone: "1" })), 400, "unknown_field");
  await expectError(await call(valid({ request_id: ID })), 400, "unknown_field");
  // values that is not an object, and an empty one.
  for (const bad of [[], [1], "x", 5, null, true]) {
    await expectError(await call(valid({}, { values: bad })), 400, "invalid_field");
  }
  await expectError(await call(valid({}, { values: {} })), 400, "missing_field");
});

test("AC-BOOKING-003 B18: the old request, answer keys sent back, and the keys an op allows", async () => {
  // The old four-key request is unknown_field (its keys are outside the three).
  await expectError(
    await call({ request_id: ID, restaurant: "Test Cafe", party_size: 2, start: "2026-11-02T19:00" }),
    400,
    "unknown_field",
  );
  // Every answer-side key sent as a request key.
  for (const key of ["fields", "result_fields", "results", "reservation_code", "partner", "simulated", "status", "reason"]) {
    await expectError(await call({ op: "fields", [key]: "x" }), 400, "unknown_field");
    await expectError(await call(valid({}, { [key]: "x" })), 400, "unknown_field");
  }
  // fields takes the op alone.
  await expectError(await call({ op: "fields", request_id: ID }), 400, "invalid_field");
  await expectError(await call({ op: "fields", values: {} }), 400, "invalid_field");
  await expectError(await call({ op: "fields", request_id: ID, values: values() }), 400, "invalid_field");
  // An unknown op.
  for (const op of ["cancel", "list", "FIELDS", "Submit", "", 5, null, true, ["fields"]]) {
    await expectError(await call({ op }), 400, "invalid_field");
  }
  // submit without values or without request_id.
  await expectError(await call({ op: "submit", request_id: ID }), 400, "missing_field");
  await expectError(await call({ op: "submit", values: values() }), 400, "missing_field");
  await expectError(await call({ op: "submit" }), 400, "missing_field");
  // A key outside the three comes before every other check.
  await expectError(await call({ op: "bogus", x: 1 }), 400, "unknown_field");
  await expectError(await call({ values: 5, x: 1 }), 400, "unknown_field");
  // The answers of the two ops are the ones documented.
  assert.equal((await call({ op: "fields" })).status, 200);
  assert.equal((await call(valid())).status, 200);
});

// A Google Places stand-in: it counts the calls and keeps what the Worker sent.
function mockPlaces(respond) {
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push({ url, init });
    return respond(url, init);
  };
  return seen;
}
const placesAnswer = (payload, status = 200) =>
  new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
const lookupBody = (over = {}) => ({ op: "lookup", field: "restaurant", text: "Tartine", ...over });
const placeOf = (name, address, latitude = 37.76, longitude = -122.42) => ({
  displayName: { text: name, languageCode: "en" },
  formattedAddress: address,
  location: { latitude, longitude },
});
const candidateOf = (name, address, latitude = 37.76, longitude = -122.42) => ({
  name,
  address,
  location: { latitude, longitude },
});
const PLACES_URL = "https://places.googleapis.com/v1/places:searchText";
const PIZZA = "\u{1F355}"; // one code point, two UTF-16 units

test("AC-BOOKING-005 B19: a lookup request is validated in order and an invalid one makes no outgoing fetch", async () => {
  const seen = mockPlaces(() => placesAnswer({ places: [] }));
  const near = { latitude: 37.77, longitude: -122.42 };
  try {
    const refuse = async (name, body, error, raw) => {
      const before = seen.length;
      const res = raw === undefined ? await call(body) : await call(null, { raw });
      assert.equal(res.status, 400, name);
      assert.deepEqual(await res.json(), { error }, name);
      assert.equal(seen.length, before, `${name} made an outgoing fetch`);
    };
    const accept = async (name, body) => {
      const before = seen.length;
      const res = await call(body);
      assert.equal(res.status, 200, name);
      assert.equal(seen.length, before + 1, `${name} did not ask Google once`);
    };
    // (1) a key outside the allowed set: unknown_field, before every other fault.
    await refuse("extra key", { ...lookupBody(), x: 1 }, "unknown_field");
    await refuse("extra key with a bad op", { op: "cancel", x: 1 }, "unknown_field");
    await refuse("extra key with a missing text", { op: "lookup", field: "restaurant", x: 1 }, "unknown_field");
    await refuse("a stray key beside a lookup", { ...lookupBody(), phone: "1" }, "unknown_field");
    // (2) an op outside fields, submit, lookup: invalid_field, before a missing key.
    for (const op of ["cancel", "LOOKUP", "Lookup", "", 5, null, true, ["lookup"]]) {
      await refuse(`op ${JSON.stringify(op)}`, lookupBody({ op }), "invalid_field");
    }
    await refuse("bad op and nothing else", { op: "cancel" }, "invalid_field");
    // (3) no op, or a key lookup requires missing: missing_field, before a key the op does not allow.
    await refuse("no op", { field: "restaurant", text: "Tartine" }, "missing_field");
    await refuse("no field", without(lookupBody(), "field"), "missing_field");
    await refuse("no text", without(lookupBody(), "text"), "missing_field");
    await refuse("op alone", { op: "lookup" }, "missing_field");
    await refuse("only near", { op: "lookup", near }, "missing_field");
    await refuse("no text and a request_id", { op: "lookup", field: "restaurant", request_id: ID }, "missing_field");
    // (4) a key the op does not allow: invalid_field, before field, text and near are looked at.
    await refuse("request_id beside lookup", lookupBody({ request_id: ID }), "invalid_field");
    await refuse("values beside lookup", lookupBody({ values: values() }), "invalid_field");
    await refuse("a bad field and a request_id", lookupBody({ field: "nope", request_id: ID }), "invalid_field");
    await refuse("field beside fields", { op: "fields", field: "restaurant" }, "invalid_field");
    await refuse("text beside fields", { op: "fields", text: "Tartine" }, "invalid_field");
    await refuse("near beside fields", { op: "fields", near }, "invalid_field");
    await refuse("field beside submit", valid({}, { field: "restaurant" }), "invalid_field");
    await refuse("text beside submit", valid({}, { text: "Tartine" }), "invalid_field");
    await refuse("near beside submit", valid({}, { near }), "invalid_field");
    // (5) a field that is not a lookup field, a bad text, a near that is not an object: invalid_field, before the keys of near are read.
    for (const field of ["party_size", "start", "name", "note", "Restaurant", " restaurant", "", 5, null, true, ["restaurant"]]) {
      await refuse(`field ${JSON.stringify(field)}`, lookupBody({ field }), "invalid_field");
    }
    for (const [name, text] of [
      ["one code point", "a"],
      ["one code point and spaces", "  a  "],
      ["spaces only", "    "],
      ["empty", ""],
      ["81 emoji", PIZZA.repeat(81)],
      ["a zero-width space", "ab​"],
      ["an inner line feed", "ab\ncd"],
      ["a trailing line feed", "ab\n"],
      ["a control character", "ab\u0007"],
      ["a line separator", "ab cd"],
      ["a number", 5],
      ["null", null],
      ["a list", ["ab"]],
    ]) {
      await refuse(`text: ${name}`, lookupBody({ text }), "invalid_field");
    }
    for (const bad of [5, "x", null, [], [1, 2], true]) {
      await refuse(`near ${JSON.stringify(bad)}`, lookupBody({ near: bad }), "invalid_field");
    }
    // (6) a key of near outside latitude and longitude: unknown_field, before a missing key or a bad value.
    await refuse("near with a third key", lookupBody({ near: { ...near, altitude: 1 } }), "unknown_field");
    await refuse("near with a third key and a bad value", lookupBody({ near: { latitude: "x", longitude: 0, altitude: 1 } }), "unknown_field");
    await refuse("near with wrong keys only", lookupBody({ near: { lat: 1, lng: 2 } }), "unknown_field");
    // (7) a key of near missing: missing_field, before a bad value.
    await refuse("near without longitude", lookupBody({ near: { latitude: 37.77 } }), "missing_field");
    await refuse("near without latitude", lookupBody({ near: { longitude: -122.42 } }), "missing_field");
    await refuse("empty near", lookupBody({ near: {} }), "missing_field");
    await refuse("a bad latitude and no longitude", lookupBody({ near: { latitude: "x" } }), "missing_field");
    // (8) a bad value of near: invalid_field.
    for (const [name, bad] of [
      ["latitude as text", { latitude: "37.77", longitude: -122.42 }],
      ["longitude as text", { latitude: 37.77, longitude: "-122.42" }],
      ["latitude null", { latitude: null, longitude: -122.42 }],
      ["longitude true", { latitude: 37.77, longitude: true }],
      ["latitude above 90", { latitude: 90.01, longitude: 0 }],
      ["latitude below -90", { latitude: -90.01, longitude: 0 }],
      ["longitude above 180", { latitude: 0, longitude: 180.01 }],
      ["longitude below -180", { latitude: 0, longitude: -180.01 }],
    ]) {
      await refuse(`near: ${name}`, lookupBody({ near: bad }), "invalid_field");
    }
    await refuse(
      "near with a latitude that is not finite",
      null,
      "invalid_field",
      '{"op":"lookup","field":"restaurant","text":"Tartine","near":{"latitude":1e999,"longitude":0}}',
    );
    // Several faults at once: one answer, and still no fetch.
    await refuse("field, text and near all bad", lookupBody({ field: "nope", text: "a", near: 5 }), "invalid_field");
    await refuse("a bad text and a third key of near", lookupBody({ text: "a", near: { ...near, altitude: 1 } }), "invalid_field");
    await refuse("a bad field and a missing key of near", lookupBody({ field: "nope", near: { latitude: 1 } }), "invalid_field");
    assert.equal(seen.length, 0, "an invalid lookup reached Google");
    // Positive controls: the valid request makes exactly one fetch, and so do the edges.
    await accept("valid request", lookupBody());
    await accept("valid request with near", lookupBody({ near }));
    await accept("80 emoji", lookupBody({ text: PIZZA.repeat(80) }));
    await accept("two code points", lookupBody({ text: "ab" }));
    await accept("a padded text", lookupBody({ text: "  ab  " }));
    await accept("near at one pair of corners", lookupBody({ near: { latitude: 90, longitude: 180 } }));
    await accept("near at the other pair of corners", lookupBody({ near: { latitude: -90, longitude: -180 } }));
    await accept("near at zero", lookupBody({ near: { latitude: 0, longitude: 0 } }));
    assert.equal(seen.length, 8);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-BOOKING-005 B20: a valid lookup asks Google Places once with the Worker's own key and answers four keys", async () => {
  const keyed = { ...env, GOOGLE_MAPS_KEY: "gk-sentinel-5521" };
  const near = { latitude: 37.77, longitude: -122.42 };
  const results = Array.from({ length: 7 }, (_, i) => placeOf(`Place ${i}`, `${i} Main St, San Francisco, CA`, 37.7 + i / 100, -122.4 - i / 100));
  const seen = mockPlaces(() => placesAnswer({ places: results }));
  try {
    const res = await call(lookupBody({ text: "  Tartine  ", near }), { e: keyed });
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type"), /application\/json/);
    const text = await res.text();
    const body = JSON.parse(text);
    // Exactly one request, to Google's text search, with the Worker's key and the fixed mask and nothing else of the app.
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, PLACES_URL);
    assert.equal(seen[0].init.method, "POST");
    assert.deepEqual(Object.fromEntries(new Headers(seen[0].init.headers)), {
      "content-type": "application/json",
      "x-goog-api-key": "gk-sentinel-5521",
      "x-goog-fieldmask": "places.displayName,places.formattedAddress,places.location",
    });
    assert.deepEqual(JSON.parse(seen[0].init.body), {
      textQuery: "Tartine",
      languageCode: "en",
      regionCode: "US",
      pageSize: 5,
      locationBias: { circle: { center: { latitude: 37.77, longitude: -122.42 }, radius: 50000 } },
    });
    // The answer: four keys in this order, at most 5 candidates in Google's order, three keys each.
    assert.deepEqual(Object.keys(body), ["partner", "simulated", "field", "candidates"]);
    assert.equal(body.partner, "Example Tables");
    assert.equal(body.simulated, true);
    assert.equal(body.field, "restaurant");
    assert.deepEqual(
      body.candidates,
      results.slice(0, 5).map((place) => candidateOf(place.displayName.text, place.formattedAddress, place.location.latitude, place.location.longitude)),
    );
    for (const candidate of body.candidates) {
      assert.deepEqual(Object.keys(candidate), ["name", "address", "location"]);
      assert.deepEqual(Object.keys(candidate.location), ["latitude", "longitude"]);
    }
    // The key is in no answer body and no answer header.
    assert.equal(text.includes("gk-sentinel-5521"), false);
    assert.equal(JSON.stringify(Object.fromEntries(res.headers)).includes("gk-sentinel-5521"), false);

    // With no near there is no locationBias at all, and the text is sent trimmed.
    const plain = await call(lookupBody({ text: "  ab " }), { e: keyed });
    assert.equal(plain.status, 200);
    assert.equal(seen.length, 2);
    assert.deepEqual(JSON.parse(seen[1].init.body), { textQuery: "ab", languageCode: "en", regionCode: "US", pageSize: 5 });
    // An empty result list is a 200 with no candidates.
    mockPlaces(() => placesAnswer({ places: [] }));
    const none = await call(lookupBody(), { e: keyed });
    assert.equal(none.status, 200);
    assert.deepEqual(await none.json(), { partner: "Example Tables", simulated: true, field: "restaurant", candidates: [] });
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-BOOKING-005 B21: a bad Google result is dropped alone and a failing upstream is a 502 with no upstream text", async () => {
  const keyed = { ...env, GOOGLE_MAPS_KEY: "gk-sentinel-5521" };
  const fine = (n) => placeOf(`Fine ${n}`, `${n} Market St, San Francisco, CA`, 37.7 + n / 100, -122.4 - n / 100);
  const wanted = [1, 2, 3, 4].map((n) => candidateOf(`Fine ${n}`, `${n} Market St, San Francisco, CA`, 37.7 + n / 100, -122.4 - n / 100));
  const location = { latitude: 37.76, longitude: -122.42 };
  const bad = [
    ["no displayName", { formattedAddress: "1 Main St", location }],
    ["displayName without text", { displayName: {}, formattedAddress: "1 Main St", location }],
    ["a name that is not a string", { displayName: { text: 5 }, formattedAddress: "1 Main St", location }],
    ["an empty name", placeOf("", "1 Main St")],
    ["a name of spaces", placeOf("   ", "1 Main St")],
    ["a name of 81 emoji", placeOf(PIZZA.repeat(81), "1 Main St")],
    ["a left-to-right mark in the name", placeOf("Tar‎tine", "1 Main St")],
    ["a line feed in the name", placeOf("Tar\ntine", "1 Main St")],
    ["no address", { displayName: { text: "Tartine" }, location }],
    ["an address that is not a string", { displayName: { text: "Tartine" }, formattedAddress: 5, location }],
    ["an empty address", placeOf("Tartine", "")],
    ["an address of spaces", placeOf("Tartine", "   ")],
    ["an address of 121 emoji", placeOf("Tartine", PIZZA.repeat(121))],
    ["a control character in the address", placeOf("Tartine", "1 Main\u0007 St")],
    ["no location", { displayName: { text: "Tartine" }, formattedAddress: "1 Main St" }],
    ["a location that is not an object", { displayName: { text: "Tartine" }, formattedAddress: "1 Main St", location: "here" }],
    ["a latitude as text", placeOf("Tartine", "1 Main St", "37.76", -122.42)],
    ["a latitude of 91", placeOf("Tartine", "1 Main St", 91, -122.42)],
    ["a latitude of -91", placeOf("Tartine", "1 Main St", -91, -122.42)],
    ["a longitude of 181", placeOf("Tartine", "1 Main St", 37.76, 181)],
    ["a longitude of -181", placeOf("Tartine", "1 Main St", 37.76, -181)],
    ["a latitude that is not finite", placeOf("Tartine", "1 Main St", null, -122.42)],
    ["a null element", null],
    ["a number element", 5],
    ["a text element", "Tartine"],
    ["a list element", [1]],
  ];
  const kept = [placeOf(PIZZA.repeat(80), "80 Pizza Rd"), placeOf("Tartine", PIZZA.repeat(120))];
  const keptWanted = [candidateOf(PIZZA.repeat(80), "80 Pizza Rd"), candidateOf("Tartine", PIZZA.repeat(120))];
  const ask = async (payload) => {
    mockPlaces(() => placesAnswer(payload));
    return call(lookupBody(), { e: keyed });
  };
  try {
    // Each bad result alone, between good ones: the good ones are kept in order.
    for (const [name, one] of bad) {
      const res = await ask({ places: [fine(1), fine(2), one, fine(3), fine(4)] });
      assert.equal(res.status, 200, name);
      assert.deepEqual((await res.json()).candidates, wanted, name);
    }
    // All of them at once, mixed with the good ones.
    const mixed = bad.flatMap(([, one], i) => (i < 4 ? [one, fine(i + 1)] : [one]));
    const all = await ask({ places: mixed });
    assert.equal(all.status, 200);
    assert.deepEqual((await all.json()).candidates, wanted);
    // Positive control: the same answer with the bad results removed gives the same list.
    const clean = await ask({ places: [fine(1), fine(2), fine(3), fine(4)] });
    assert.deepEqual((await clean.json()).candidates, wanted);
    // The edges that are kept: 80 code points of name, 120 of address.
    const edges = await ask({ places: kept });
    assert.deepEqual((await edges.json()).candidates, keptWanted);
    // Bad results do not use up the five places.
    const crowded = await ask({ places: [...bad.map(([, one]) => one), ...[1, 2, 3, 4, 5, 6].map(fine)] });
    assert.deepEqual((await crowded.json()).candidates.map((c) => c.name), ["Fine 1", "Fine 2", "Fine 3", "Fine 4", "Fine 5"]);

    // An answer with nothing to list is an empty list.
    for (const [name, payload] of [
      ["an object without places", {}],
      ["places null", { places: null }],
      ["places empty", { places: [] }],
      ["only bad results", { places: bad.map(([, one]) => one) }],
    ]) {
      const res = await ask(payload);
      assert.equal(res.status, 200, name);
      assert.deepEqual(await res.json(), { partner: "Example Tables", simulated: true, field: "restaurant", candidates: [] }, name);
    }

    // A failing upstream is one fixed 502, whatever it said.
    const secret = "SECRET-UPSTREAM-TEXT-8841";
    const failures = [
      [
        "a thrown fetch",
        () => {
          throw new Error(secret);
        },
      ],
      ["a 500", () => new Response(secret, { status: 500 })],
      ["a 403 with a JSON error", () => placesAnswer({ error: { message: secret } }, 403)],
      ["a 200 that is not JSON", () => new Response(secret, { status: 200 })],
      ["a 200 null", () => placesAnswer(null)],
      ["a 200 list", () => placesAnswer([{ places: [] }])],
      ["a 200 number", () => placesAnswer(5)],
      ["places as text", () => placesAnswer({ places: secret })],
      ["places as an object", () => placesAnswer({ places: { 0: fine(1) } })],
      ["places as a number", () => placesAnswer({ places: 5 })],
    ];
    for (const [name, respond] of failures) {
      const seen = mockPlaces(respond);
      const res = await call(lookupBody(), { e: keyed });
      const text = await res.text();
      assert.equal(res.status, 502, name);
      assert.equal(text, JSON.stringify({ error: "upstream_failed" }), name);
      assert.equal(seen.length, 1, `${name}: one fetch`);
      assert.equal(text.includes(secret) || text.includes("gk-sentinel-5521"), false, name);
    }

    // No key: 503 and no fetch, an empty key too.
    for (const key of [undefined, ""]) {
      const seen = mockPlaces(() => placesAnswer({ places: [] }));
      const res = await call(lookupBody(), { e: { ...env, GOOGLE_MAPS_KEY: key } });
      await expectError(res, 503, "google_key_not_configured");
      assert.equal(seen.length, 0);
    }
    // The other two ops do not need the key.
    const noKey = { ...env, GOOGLE_MAPS_KEY: undefined };
    assert.equal((await call({ op: "fields" }, { e: noKey })).status, 200);
    assert.equal((await call(valid(), { e: noKey })).status, 200);
  } finally {
    globalThis.fetch = realFetch;
  }
});
