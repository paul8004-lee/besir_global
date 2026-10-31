import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: "g" };
const ID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b";
const ID2 = "9A1D4C7E-2B3F-4A50-8C61-7D8E9F0A1B2C";
const valid = (over = {}) => ({ op: "cancel", request_id: ID, ...over });

// A body object is JSON-encoded; `raw` sends the string as it is.
const call = (body, { path = "/booking/cancel", token = "app-test", raw, method = "POST", e = env } = {}) =>
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

test("AC-LATESWITCH-001 X01: 401 for no token, a wrong token and no APP_TOKEN, before the body is read", async () => {
  // A body that is not JSON would be a 400 if it were read.
  await expectError(await call(valid(), { token: "" , raw: "not json" }), 401, "unauthorized");
  await expectError(await call(valid(), { token: "nope", raw: "not json" }), 401, "unauthorized");
  await expectError(await call(valid(), { e: { ...env, APP_TOKEN: undefined } }), 401, "unauthorized");
  await expectError(await call(valid(), { e: { ...env, APP_TOKEN: "" } }), 401, "unauthorized");
  assert.equal((await call(valid())).status, 200, "a valid token reaches the route");
});

test("AC-LATESWITCH-001 X02: a non-POST is 405 and the other routes still answer 401 to a bad token", async () => {
  for (const method of ["GET", "PUT", "DELETE"]) {
    await expectError(await call(null, { method }), 405, "method_not_allowed");
    // The 405 comes before the token is read.
    await expectError(await call(null, { method, token: "nope" }), 405, "method_not_allowed");
  }
  for (const path of ["/ai", "/places", "/routes", "/vision", "/snap", "/partners", "/booking", "/budget", "/delivery"]) {
    await expectError(await call({}, { path, token: "nope" }), 401, "unauthorized");
  }
  await expectError(await call({}, { token: "nope" }), 401, "unauthorized");
});

test("AC-LATESWITCH-001 X03: a valid body gives 200 with exactly status, partner and simulated", async () => {
  const res = await call(valid());
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "application/json");
  const body = await res.json();
  assert.deepEqual(Object.keys(body), ["status", "partner", "simulated"]);
  assert.deepEqual(body, { status: "cancelled", partner: "Example Tables", simulated: true });
});

test("AC-LATESWITCH-001 X04: the same request gives the same answer and any well-formed id is cancelled", async () => {
  const first = await (await call(valid())).text();
  const second = await (await call(valid())).text();
  assert.equal(first, second);
  const other = await (await call(valid({ request_id: ID2 }))).json();
  assert.deepEqual(other, JSON.parse(first));
  assert.equal(first.includes(ID), false, "the request id is not echoed");
});

test("AC-LATESWITCH-001 X05: the order of the faults, step by step", async () => {
  await expectError(await call(null, { raw: "x".repeat(4097) }), 413, "body_too_large");
  await expectError(await call(null, { raw: "{not json" }), 400, "invalid_json");
  for (const raw of ["null", "[]", "7", '"text"', "true"]) {
    await expectError(await call(null, { raw }), 400, "body_must_be_object");
  }
  // A key outside the two comes before a missing key and before a bad value.
  await expectError(await call({ extra: 1 }), 400, "unknown_field");
  await expectError(await call({ op: "submit", extra: 1 }), 400, "unknown_field");
  await expectError(await call({ op: "cancel", request_id: "not-a-uuid", extra: 1 }), 400, "unknown_field");
  // A missing key comes before a bad value.
  await expectError(await call({}), 400, "missing_field");
  await expectError(await call({ op: "submit" }), 400, "missing_field");
  await expectError(await call({ request_id: "not-a-uuid" }), 400, "missing_field");
  await expectError(await call({ op: "cancel" }), 400, "missing_field");
  await expectError(await call({ request_id: ID }), 400, "missing_field");
  // Then the values.
  await expectError(await call({ op: "submit", request_id: ID }), 400, "invalid_field");
  await expectError(await call({ op: "cancel", request_id: "not-a-uuid" }), 400, "invalid_field");
  await expectError(await call({ op: "submit", request_id: "not-a-uuid" }), 400, "invalid_field");
});

test("AC-LATESWITCH-001 X06: boundary values of op, request_id and the keys", async () => {
  // The UUID form is the 8-4-4-4-12 hexadecimal form, in either case.
  assert.equal((await call(valid({ request_id: ID2 }))).status, 200);
  assert.equal((await call(valid({ request_id: ID.toUpperCase() }))).status, 200);
  for (const request_id of [`{${ID}}`, ID.slice(1), ID + "0", ID.replaceAll("-", ""), "", " " + ID, ID + " ", 7, null, ID.replace("3f", "zz")]) {
    await expectError(await call(valid({ request_id })), 400, "invalid_field");
  }
  for (const op of ["Cancel", "CANCEL", "submit", "fields", "lookup", "", 1, null, true, ["cancel"]]) {
    await expectError(await call(valid({ op })), 400, "invalid_field");
  }
  // A key of the booking route, or a reservation code, is not allowed here.
  for (const extra of [{ reservation_code: "EX-U7T0K3" }, { values: {} }, { note: "x" }, { Op: "cancel" }]) {
    await expectError(await call({ ...valid(), ...extra }), 400, "unknown_field");
  }
});

test("AC-LATESWITCH-001 X07: 4096 characters pass the length check and 4097 give 413", async () => {
  const body = JSON.stringify(valid());
  const exact = body + " ".repeat(4096 - body.length);
  assert.equal(exact.length, 4096);
  assert.equal((await call(null, { raw: exact })).status, 200);
  const over = body + " ".repeat(4097 - body.length);
  assert.equal(over.length, 4097);
  await expectError(await call(null, { raw: over }), 413, "body_too_large");
});

test("AC-LATESWITCH-002 X08: the route source holds no log, storage, fetch, clock or random call (whole file)", async () => {
  const source = readFileSync(new URL("../src/booking.js", import.meta.url), "utf8");
  const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\s\/\/.*$/gm, "");
  for (const word of ["console", "fetch", "env", "Date", "KV", "D1", "R2"]) {
    assert.equal(new RegExp(`\\b${word}\\b`).test(code), false, `the source holds ${word}`);
  }
  for (const text of ["Math.random", "getRandomValues"]) {
    assert.equal(code.includes(text), false, `the source holds ${text}`);
  }
  // Positive control: the scan sees the new function and the file's own digest call.
  assert.equal(code.includes("export async function handleBookingCancel(request, { json })"), true);
  assert.equal(code.includes("crypto.subtle"), true);
  // The cancel takes `{ json }` only: no lookup is handed to it.
  const cancel = code.slice(code.indexOf("export async function handleBookingCancel"));
  assert.equal(/\blookup\b/.test(cancel), false);
  // The partner name is still written once in the file.
  assert.equal(code.split("Example Tables").length - 1, 1);
});

test("AC-LATESWITCH-001 X09: /booking/cancel reaches the cancel and /booking the booking; near paths are 404", async () => {
  assert.deepEqual(await (await call(valid())).json(), { status: "cancelled", partner: "Example Tables", simulated: true });
  // /booking is unchanged: its op `cancel` is still an unknown op.
  await expectError(await call(valid(), { path: "/booking" }), 400, "invalid_field");
  const booking = await call(
    { op: "submit", request_id: ID, values: { restaurant: "Test Cafe", party_size: 2, start: "2026-11-02T19:00", name: "Sam" } },
    { path: "/booking" },
  );
  assert.equal((await booking.json()).status, "confirmed");
  for (const path of ["/booking/", "/booking/cancel/", "/booking/cancel/x", "/booking/Cancel", "/booking/cancel2", "/cancel"]) {
    await expectError(await call(valid(), { path }), 404, "not_found");
  }
});
