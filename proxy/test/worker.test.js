import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const env = { META_API_KEY: "meta-test", GOOGLE_MAPS_KEY: "g-test", APP_TOKEN: "app-test" };

const call = (path, { token = "app-test", body = {}, method = "POST", headers = {}, e = env } = {}) =>
  worker.fetch(
    new Request(`https://x.test${path}`, {
      method,
      headers: { "x-besir-token": token, ...headers },
      body: method === "POST" ? JSON.stringify(body) : undefined,
    }),
    e,
  );

function mockUpstream(status = 200, payload = { ok: true }) {
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push({ url, init });
    return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
  };
  return seen;
}

test("health needs no token", async () => {
  const res = await call("/health", { method: "GET", token: "" });
  assert.equal(res.status, 200);
});

test("rejects missing or wrong token, and fails closed without APP_TOKEN", async () => {
  assert.equal((await call("/ai", { token: "" })).status, 401);
  assert.equal((await call("/ai", { token: "nope" })).status, 401);
  assert.equal((await call("/ai", { token: "", e: { ...env, APP_TOKEN: "" } })).status, 401);
});

test("/ai forwards to the Responses API with the bearer key and default model", async () => {
  const seen = mockUpstream(200, { output_text: "hi" });
  const res = await call("/ai", { body: { input: "hello" } });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).output_text, "hi");
  assert.equal(seen[0].url, "https://api.meta.ai/v1/responses");
  assert.equal(seen[0].init.headers.authorization, "Bearer meta-test");
  assert.equal(JSON.parse(seen[0].init.body).model, "muse-spark-1.3");
});

test("/ai refuses models outside the allow-list", async () => {
  const seen = mockUpstream();
  const res = await call("/ai", { body: { model: "muse-spark-1.3-contributor", input: "x" } });
  assert.equal(res.status, 400);
  assert.equal(seen.length, 0);
});

test("/ai sets store false when the client sends no store field", async () => {
  const seen = mockUpstream();
  await call("/ai", { body: { input: "hello" } });
  assert.equal(JSON.parse(seen[0].init.body).store, false);
});

test("/ai overwrites a client store true with false", async () => {
  const seen = mockUpstream();
  await call("/ai", { body: { input: "hello", store: true } });
  assert.equal(JSON.parse(seen[0].init.body).store, false);
});

test("/ai passes upstream errors through without leaking the key", async () => {
  mockUpstream(401, { error: "bad key" });
  const res = await call("/ai", { body: { input: "x" } });
  assert.equal(res.status, 401);
  assert.ok(!JSON.stringify(Object.fromEntries(res.headers)).includes("meta-test"));
});

test("/ai reports missing key and bad JSON", async () => {
  assert.equal((await call("/ai", { e: { APP_TOKEN: "app-test" } })).status, 503);
  const bad = await worker.fetch(
    new Request("https://x.test/ai", { method: "POST", headers: { "x-besir-token": "app-test" }, body: "{" }),
    env,
  );
  assert.equal(bad.status, 400);
});

test("/places and /routes need a field mask and send the Google key", async () => {
  const seen = mockUpstream();
  assert.equal((await call("/places", { body: { textQuery: "ramen" } })).status, 400);
  const res = await call("/places", {
    body: { textQuery: "ramen" },
    headers: { "x-goog-fieldmask": "places.displayName" },
  });
  assert.equal(res.status, 200);
  assert.equal(seen[0].url, "https://places.googleapis.com/v1/places:searchText");
  assert.equal(seen[0].init.headers["x-goog-api-key"], "g-test");
  await call("/routes", { body: {}, headers: { "x-goog-fieldmask": "routes.duration" } });
  assert.equal(seen[1].url, "https://routes.googleapis.com/directions/v2:computeRoutes");
});

test("/booking lookup ignores client Google headers, keeps its own key and writes no log line", async () => {
  const realFetch = globalThis.fetch;
  const levels = ["log", "info", "warn", "error", "debug"];
  const real = Object.fromEntries(levels.map((level) => [level, console[level]]));
  let logged = 0;
  for (const level of levels) console[level] = () => (logged += 1);
  try {
    // The spy counts: a deliberate call is seen.
    console.warn("deliberate");
    assert.equal(logged, 1);
    logged = 0;
    const lookup = { op: "lookup", field: "restaurant", text: "Tartine" };
    const hostile = { "x-goog-fieldmask": "places.id", "x-goog-api-key": "client-key", authorization: "Bearer client" };
    const seen = mockUpstream(200, { places: [{ displayName: { text: "Tartine" }, formattedAddress: "600 Guerrero St", location: { latitude: 37.76, longitude: -122.42 } }] });
    const ok = await call("/booking", { body: lookup, headers: hostile });
    assert.equal(ok.status, 200);
    assert.equal((await ok.json()).candidates.length, 1);
    assert.equal(seen.length, 1);
    const sent = new Headers(seen[0].init.headers);
    assert.equal(sent.get("x-goog-api-key"), "g-test");
    assert.equal(sent.get("x-goog-fieldmask"), "places.displayName,places.formattedAddress,places.location");
    assert.equal(sent.get("authorization"), null);
    // The route that does take a client mask still wants one.
    assert.equal((await call("/places", { body: { textQuery: "ramen" } })).status, 400);
    // A lookup that fails upstream is a 502 and writes nothing either.
    mockUpstream(500, { error: "down" });
    const failed = await call("/booking", { body: lookup });
    assert.equal(failed.status, 502);
    assert.equal(logged, 0);
  } finally {
    for (const level of levels) console[level] = real[level];
    globalThis.fetch = realFetch;
  }
});

test("unknown path and non-POST are refused", async () => {
  assert.equal((await call("/nope")).status, 404);
  assert.equal((await call("/ai", { method: "GET" })).status, 405);
});
