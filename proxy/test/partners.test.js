import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: "g" };

const EXPECTED_DIRECTORY = {
  partners: [
    {
      id: "booking",
      name: "Example Tables",
      title: "Reserve a table",
      summary: "Reserves a table at a restaurant.",
      route: "/booking",
    },
  ],
};

// A body object is JSON-encoded; `raw` sends the string as it is.
const call = (body, { path = "/partners", token = "app-test", raw, method = "POST", e = env } = {}) =>
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

// An independent reading of the directory rules (spec REQ-BOOKCARD-001), written without the Worker's code.
const HIDDEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const codePoints = (text) => [...text].length;
function directoryProblems(answer) {
  const problems = [];
  if (answer === null || typeof answer !== "object" || Array.isArray(answer)) return ["not an object"];
  if (Object.keys(answer).join() !== "partners") problems.push("the keys are not exactly partners");
  const list = answer.partners;
  if (!Array.isArray(list) || list.length < 1 || list.length > 8) return [...problems, "the list is not 1 to 8 entries"];
  const ids = new Set();
  const routes = new Set();
  for (const entry of list) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
      problems.push("an entry is not an object");
      continue;
    }
    if (Object.keys(entry).join() !== "id,name,title,summary,route") problems.push("an entry has other keys");
    if (typeof entry.id !== "string" || !/^[a-z][a-z0-9_]{0,23}$/.test(entry.id)) problems.push("bad id");
    if (typeof entry.route !== "string" || !/^\/[a-z][a-z0-9-]{0,31}$/.test(entry.route) || entry.route === "/partners") {
      problems.push("bad route");
    }
    if (typeof entry.name !== "string" || !/^[\x20-\x7E]{1,40}$/.test(entry.name)) problems.push("bad name");
    if (typeof entry.title !== "string" || codePoints(entry.title) < 1 || codePoints(entry.title) > 40 || HIDDEN.test(entry.title)) {
      problems.push("bad title");
    }
    if (typeof entry.summary !== "string" || codePoints(entry.summary) < 1 || codePoints(entry.summary) > 120 || HIDDEN.test(entry.summary)) {
      problems.push("bad summary");
    }
    if (ids.has(entry.id)) problems.push("repeated id");
    if (routes.has(entry.route)) problems.push("repeated route");
    ids.add(entry.id);
    routes.add(entry.route);
  }
  return problems;
}

test("AC-PARTNERS-001 N01: the directory answers the one-key list with the one entry, the same every time", async () => {
  const first = await call({ op: "list" });
  assert.equal(first.status, 200);
  assert.match(first.headers.get("content-type"), /application\/json/);
  const text = await first.text();
  assert.deepEqual(JSON.parse(text), EXPECTED_DIRECTORY);
  // The text pins the key order as well.
  assert.equal(text, JSON.stringify(EXPECTED_DIRECTORY));
  const second = await (await call({ op: "list" })).text();
  assert.equal(second, text);
});

test("AC-PARTNERS-001 N02: an independent validator accepts the directory and every route answers its fields", async () => {
  const answer = await (await call({ op: "list" })).json();
  assert.deepEqual(directoryProblems(answer), []);

  // The validator fires: each planted defect is found.
  const entry = EXPECTED_DIRECTORY.partners[0];
  const with1 = (over) => ({ partners: [{ ...entry, ...over }] });
  const edge33 = "/" + "a".repeat(32);
  const planted = [
    ["a second top-level key", { ...EXPECTED_DIRECTORY, extra: 1 }],
    ["no entry", { partners: [] }],
    ["nine entries", { partners: Array.from({ length: 9 }, (_, i) => ({ ...entry, id: `p${i}`, route: `/r${i}` })) }],
    ["a repeated id", { partners: [entry, { ...entry, route: "/other" }] }],
    ["a repeated route", { partners: [entry, { ...entry, id: "other" }] }],
    ["an upper-case id", with1({ id: "Booking" })],
    ["an id of 25 characters", with1({ id: "a".repeat(25) })],
    ["the route /partners", with1({ route: "/partners" })],
    ["a route with an upper-case letter", with1({ route: "/Booking" })],
    ["a route without the slash", with1({ route: "booking" })],
    ["a route of 34 characters", with1({ route: "/" + "a".repeat(33) })],
    ["a name of 41 characters", with1({ name: "N".repeat(41) })],
    ["a non-ASCII name", with1({ name: "Café Tables" })],
    ["an empty title", with1({ title: "" })],
    ["a title of 41 characters", with1({ title: "T".repeat(41) })],
    ["a summary of 121 characters", with1({ summary: "S".repeat(121) })],
    ["a control character in the summary", with1({ summary: "Reserves\u0007 a table." })],
    ["a line separator in the title", with1({ title: "Reserve a table" })],
    ["a zero-width character in the summary", with1({ summary: "Reserves​ a table." })],
    ["an extra entry key", with1({ extra: 1 })],
    ["a missing entry key", { partners: [{ id: "booking", name: "Example Tables", title: "Reserve a table", route: "/booking" }] }],
  ];
  for (const [name, bad] of planted) {
    assert.notDeepEqual(directoryProblems(bad), [], `the validator misses ${name}`);
  }
  // The edges are accepted: a route of 33 characters in all.
  assert.deepEqual(directoryProblems(with1({ route: edge33 })), []);
  assert.deepEqual(directoryProblems(with1({ id: "a".repeat(24), name: "N".repeat(40), title: "T".repeat(40), summary: "S".repeat(120) })), []);

  // Every listed route answers the fields request and names the partner as the entry does.
  for (const listed of answer.partners) {
    const res = await call({ op: "fields" }, { path: listed.route });
    assert.equal(res.status, 200, listed.route);
    const fields = await res.json();
    assert.equal(fields.partner, listed.name, listed.route);
  }
});

test("AC-PARTNERS-001 N03: the plumbing of the directory route", async () => {
  // A bad token is 401 before the body is read.
  const unreadable = (token) => ({
    method: "POST",
    url: "https://x.test/partners",
    headers: new Headers(token === null ? {} : { "x-besir-token": token }),
    text: async () => {
      throw new Error("the body must not be read");
    },
  });
  await expectError(await worker.fetch(unreadable(null), env), 401, "unauthorized");
  await expectError(await worker.fetch(unreadable("nope"), env), 401, "unauthorized");
  await expectError(await worker.fetch(unreadable("app-test"), { ...env, APP_TOKEN: undefined }), 401, "unauthorized");
  await assert.rejects(worker.fetch(unreadable("app-test"), env), /must not be read/);

  // A non-POST is 405 and nothing goes out.
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return new Response("{}");
  };
  try {
    for (const method of ["GET", "PUT", "DELETE"]) {
      await expectError(await call(null, { method }), 405, "method_not_allowed");
    }
    assert.equal((await call({ op: "list" })).status, 200);
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }

  // The body faults.
  await expectError(await call(null, { raw: "x".repeat(4097) }), 413, "body_too_large");
  await expectError(await call(null, { raw: "x".repeat(4096) }), 400, "invalid_json");
  await expectError(await call(null, { raw: "not json" }), 400, "invalid_json");
  await expectError(await call(null, { raw: "[1,2]" }), 400, "body_must_be_object");
  await expectError(await call(null, { raw: "null" }), 400, "body_must_be_object");

  // The ladder: a key outside op first, then no op, then the value of op.
  await expectError(await call({ op: "list", x: 1 }), 400, "unknown_field");
  await expectError(await call({ x: 1 }), 400, "unknown_field");
  await expectError(await call({}), 400, "missing_field");
  await expectError(await call({ op: "fields" }), 400, "invalid_field");
  await expectError(await call({ op: "submit" }), 400, "invalid_field");
  await expectError(await call({ op: 5 }), 400, "invalid_field");
  await expectError(await call({ op: "LIST" }), 400, "invalid_field");

  // Routing: after the token check; the other names are not routes.
  await expectError(await call({ op: "list" }, { token: "nope" }), 401, "unauthorized");
  await expectError(await call({ op: "list" }, { path: "/partner" }), 404, "not_found");
  await expectError(await call({ op: "list" }, { path: "/partners/" }), 404, "not_found");

  // The source holds no log, storage, fetch, clock or random call.
  const source = readFileSync(new URL("../src/partners.js", import.meta.url), "utf8");
  const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\s\/\/.*$/gm, "");
  for (const word of ["console", "fetch", "env", "Date", "KV", "D1", "R2"]) {
    assert.equal(new RegExp(`\\b${word}\\b`).test(code), false, `the source holds ${word}`);
  }
  for (const text of ["Math.random", "getRandomValues"]) {
    assert.equal(code.includes(text), false, `the source holds ${text}`);
  }
  // Positive controls: the same scan finds what it looks for, and the file is the one that answers.
  assert.equal(/\bfetch\b/.test("await fetch(x)"), true);
  assert.equal(/\bDate\b/.test("new Date()"), true);
  assert.equal(/\benv\b/.test("handle(request, env)"), true);
  assert.equal(code.includes("handlePartners"), true);
  assert.equal(code.includes("Math.random"), false);
  assert.equal("x = Math.random()".includes("Math.random"), true);
  // The partner name is written once in this file.
  assert.equal(code.split("Example Tables").length - 1, 1);
});
