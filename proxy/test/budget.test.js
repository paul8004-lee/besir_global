import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: "g" };
const ID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b";
const left = (over = {}) => ({ op: "left", week_start: "2026-11-02", spent_cents: 12000, ...over });
const spend = (over = {}) => ({
  op: "spend",
  week_start: "2026-11-02",
  spent_cents: 12000,
  amount_cents: 3500,
  request_id: ID,
  ...over,
});

// A body object is JSON-encoded; `raw` sends the string as it is.
const call = (body, { token = "app-test", raw, method = "POST", e = env, path = "/budget" } = {}) =>
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

test("AC-BUDGET-001 B01: 401 for no token, a wrong token and no APP_TOKEN, before the body is read", async () => {
  const unreadable = (token) => ({
    method: "POST",
    url: "https://x.test/budget",
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

test("AC-BUDGET-001 B02: a non-POST is 405 and the other routes still answer 401 to a bad token", async () => {
  for (const method of ["GET", "PUT", "DELETE"]) {
    const res = await worker.fetch(
      new Request("https://x.test/budget", { method, headers: { "x-besir-token": "app-test" } }),
      env,
    );
    await expectError(res, 405, "method_not_allowed");
  }
  for (const path of ["/ai", "/places", "/routes", "/vision", "/booking", "/budget"]) {
    const res = await call({}, { token: "nope", path });
    await expectError(res, 401, "unauthorized");
  }
});

test("AC-BUDGET-002 B03: a left request answers exactly the 8 keys with the documented values", async () => {
  const res = await call(left());
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), [
    "budget_cents",
    "left_cents",
    "op",
    "partner",
    "simulated",
    "spent_cents",
    "status",
    "week_start",
  ]);
  assert.deepEqual(body, {
    partner: "Example Budget",
    simulated: true,
    op: "left",
    week_start: "2026-11-02",
    spent_cents: 12000,
    budget_cents: 20000,
    left_cents: 8000,
    status: "within",
  });
});

test("AC-BUDGET-002 B04: a spend request answers exactly the 9 keys and spent_cents is before plus amount", async () => {
  const res = await call(spend());
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), [
    "amount_cents",
    "budget_cents",
    "left_cents",
    "op",
    "partner",
    "simulated",
    "spent_cents",
    "status",
    "week_start",
  ]);
  assert.equal(body.op, "spend");
  assert.equal(body.amount_cents, 3500);
  assert.equal(body.spent_cents, 15500);
  assert.equal(body.left_cents, 4500);
  assert.equal(body.status, "within");
});

test("AC-BUDGET-002 B05: left_cents 0 is within, -1 is over, and a spend that crosses the budget is over", async () => {
  const exact = await (await call(left({ spent_cents: 20000 }))).json();
  assert.equal(exact.left_cents, 0);
  assert.equal(exact.status, "within");
  const one = await (await call(left({ spent_cents: 20001 }))).json();
  assert.equal(one.left_cents, -1);
  assert.equal(one.status, "over");
  const none = await (await call(left({ spent_cents: 0 }))).json();
  assert.equal(none.left_cents, 20000);
  assert.equal(none.status, "within");
  const lands = await (await call(spend({ spent_cents: 19000, amount_cents: 1000 }))).json();
  assert.equal(lands.left_cents, 0);
  assert.equal(lands.status, "within");
  const crosses = await (await call(spend({ spent_cents: 19000, amount_cents: 1001 }))).json();
  assert.equal(crosses.spent_cents, 20001);
  assert.equal(crosses.left_cents, -1);
  assert.equal(crosses.status, "over");
});

test("AC-BUDGET-002 B06: the same request twice gives equal answers and request_id is not in the answer", async () => {
  const a = await (await call(spend())).json();
  const b = await (await call(spend())).json();
  assert.deepEqual(a, b);
  const other = await (await call(spend({ request_id: "9a1d4c7e-2b3f-4a50-8c61-7d8e9f0a1b2c" }))).json();
  assert.deepEqual(other, a);
  assert.equal("request_id" in a, false);
  assert.equal(JSON.stringify(a).includes(ID), false);
  const first = await (await call(left())).json();
  const second = await (await call(left())).json();
  assert.deepEqual(first, second);
});

test("AC-BUDGET-001 B07: the order and words of the faults", async () => {
  await expectError(await call(null, { raw: "x".repeat(4097) }), 413, "body_too_large");
  await expectError(await call(null, { raw: "x".repeat(4096) }), 400, "invalid_json");
  await expectError(await call(null, { raw: "not json" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "[1,2]" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "null" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "5" }), 400, "body_must_be_object");
  // A key outside the five names comes before everything else.
  await expectError(await call({ ...left(), name: "x" }), 400, "unknown_field");
  await expectError(await call({ op: "refund", name: "x" }), 400, "unknown_field");
  await expectError(await call({ week_start: "2026-11-02", note: "x" }), 400, "unknown_field");
  // An op that is present and not one of the two words is invalid whatever else is missing.
  await expectError(await call({ op: "refund" }), 400, "invalid_field");
  await expectError(await call({ op: 5 }), 400, "invalid_field");
  await expectError(await call({ op: null, week_start: "2026-11-02" }), 400, "invalid_field");
  // Then a missing key.
  await expectError(await call({}), 400, "missing_field");
  await expectError(await call({ week_start: "2026-11-02", spent_cents: 1 }), 400, "missing_field");
  const { amount_cents, ...noAmount } = spend();
  await expectError(await call(noAmount), 400, "missing_field");
  const { request_id, ...noId } = spend();
  await expectError(await call(noId), 400, "missing_field");
  const { week_start, ...noWeek } = left();
  await expectError(await call(noWeek), 400, "missing_field");
  const { spent_cents, ...noSpent } = left();
  await expectError(await call(noSpent), 400, "missing_field");
  // A missing key comes before a bad value.
  await expectError(await call({ op: "left", week_start: "nope" }), 400, "missing_field");
  // Last, a key of the other shape or a value outside its rule.
  await expectError(await call({ ...left(), amount_cents: 5 }), 400, "invalid_field");
  await expectError(await call({ ...left(), request_id: ID }), 400, "invalid_field");
  await expectError(await call(left({ week_start: "nope" })), 400, "invalid_field");
});

test("AC-BUDGET-001 B08: week_start must be a real calendar date from 2000 to 2199", async () => {
  const accepted = ["2028-02-29", "2026-12-31", "2000-01-01", "2199-12-31", "2000-02-29", "2100-02-28"];
  for (const day of accepted) {
    const res = await call(left({ week_start: day }));
    assert.equal(res.status, 200, day);
    assert.equal((await res.json()).week_start, day);
  }
  const refused = [
    "2026-02-29",
    "2100-02-29",
    "2026-13-01",
    "2026-00-10",
    "2026-04-31",
    "2026-11-00",
    "2026-11-32",
    "1999-12-31",
    "2200-01-01",
    "2026-1-5",
    "2026-11-02T00:00",
    "2026-11-02 ",
    " 2026-11-02",
    "20261102",
    "",
  ];
  for (const day of refused) {
    await expectError(await call(left({ week_start: day })), 400, "invalid_field");
  }
  await expectError(await call(left({ week_start: 20261102 })), 400, "invalid_field");
  await expectError(await call(left({ week_start: null })), 400, "invalid_field");
});

test("AC-BUDGET-001 B09: the number rules", async () => {
  const twoPointZero = `{"op":"spend","week_start":"2026-11-02","spent_cents":2.0,"amount_cents":3.0,"request_id":"${ID}"}`;
  const ok = await call(null, { raw: twoPointZero });
  assert.equal(ok.status, 200);
  const okBody = await ok.json();
  assert.equal(okBody.spent_cents, 5);
  assert.equal(okBody.amount_cents, 3);
  const badSpent = ["12000", true, null, 1.5, -1, 1000000001, [], {}];
  for (const value of badSpent) {
    await expectError(await call(left({ spent_cents: value })), 400, "invalid_field");
  }
  const badAmount = ["3500", false, null, 0.5, 0, -5, 100000001, [], {}];
  for (const value of badAmount) {
    await expectError(await call(spend({ amount_cents: value })), 400, "invalid_field");
  }
  assert.equal((await call(left({ spent_cents: 0 }))).status, 200);
  const top = await (await call(left({ spent_cents: 1000000000 }))).json();
  assert.equal(top.left_cents, 20000 - 1000000000);
  assert.equal(top.status, "over");
  assert.equal((await call(spend({ amount_cents: 1 }))).status, 200);
  const big = await (await call(spend({ spent_cents: 0, amount_cents: 100000000 }))).json();
  assert.equal(big.spent_cents, 100000000);
  assert.equal(big.status, "over");
});

test("AC-BUDGET-001 B10: the shape per op, and op words are exact", async () => {
  await expectError(await call({ ...left(), amount_cents: 5, request_id: ID }), 400, "invalid_field");
  await expectError(await call({ ...left(), amount_cents: 5 }), 400, "invalid_field");
  await expectError(await call({ ...left(), request_id: ID }), 400, "invalid_field");
  const { amount_cents, ...noAmount } = spend();
  await expectError(await call(noAmount), 400, "missing_field");
  const { amount_cents: a, request_id: r, ...neither } = spend();
  await expectError(await call(neither), 400, "missing_field");
  for (const op of ["refund", "LEFT", "Spend", "", " left", "left "]) {
    await expectError(await call(left({ op })), 400, "invalid_field");
  }
});

test("AC-BUDGET-001 B11: request_id must be a UUID in the 8-4-4-4-12 form, upper-case hex is accepted", async () => {
  for (const bad of ["not-a-uuid", `${ID}0`, ` ${ID}`, ID.replaceAll("-", ""), "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6g", "", 7, null]) {
    await expectError(await call(spend({ request_id: bad })), 400, "invalid_field");
  }
  const upper = await call(spend({ request_id: ID.toUpperCase() }));
  assert.equal(upper.status, 200);
  assert.deepEqual(await upper.json(), await (await call(spend())).json());
});

test("AC-BUDGET-002 B12: a valid request reaches no fetch and the route source holds no log, storage, fetch, clock or random call", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    throw new Error("no outgoing request is allowed");
  };
  try {
    assert.equal((await call(left())).status, 200);
    assert.equal((await call(spend())).status, 200);
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
  const source = readFileSync(new URL("../src/budget.js", import.meta.url), "utf8");
  const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\s\/\/.*$/gm, "");
  for (const word of ["console", "fetch", "env", "Date", "KV", "D1", "R2"]) {
    assert.equal(new RegExp(`\\b${word}\\b`).test(code), false, `the source holds ${word}`);
  }
  for (const text of ["Math.random", "getRandomValues"]) {
    assert.equal(code.includes(text), false, `the source holds ${text}`);
  }
  // Positive control: the same scan finds what the file does use.
  assert.equal(code.includes("WEEKLY_BUDGET_CENTS"), true);
  assert.equal(/\bfetch\b/.test("await fetch(x)"), true);
  assert.equal(/\bDate\b/.test("new Date()"), true);
  assert.equal(/\benv\b/.test("handle(request, env)"), true);
  // The partner name is written once in this file.
  assert.equal(code.split("Example Budget").length - 1, 1);
});

test("AC-BUDGET-001 B13: /budget is served next to the five other routes and a GET of /budget is 405", async () => {
  assert.equal((await call(left())).status, 200, "a valid token reaches the budget route");
  await expectError(await call(null, { method: "GET" }), 405, "method_not_allowed");
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ choices: [{ index: 0, message: { role: "assistant", content: "{}" }, finish_reason: "stop" }] }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  try {
    const known = ["/ai", "/places", "/routes", "/vision", "/booking"];
    for (const path of known) {
      const res = await call({}, { path });
      assert.notEqual(res.status, 404, `${path} is still routed`);
      assert.notEqual(res.status, 401, `${path} accepts the token`);
    }
    await expectError(await call({}, { path: "/budgets" }), 404, "not_found");
    await expectError(await call({}, { path: "/budget/" }), 404, "not_found");
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("AC-BUDGET-002 B14: the partner and budget literals", async () => {
  for (const body of [left(), spend()]) {
    const answer = await (await call(body)).json();
    assert.equal(answer.partner, "Example Budget");
    assert.strictEqual(answer.simulated, true);
    assert.strictEqual(answer.budget_cents, 20000);
    assert.equal(typeof answer.left_cents, "number");
  }
});
