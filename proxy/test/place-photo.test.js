import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const KEY = "g-secret-key";
const env = { APP_TOKEN: "app-test", META_API_KEY: "m", GOOGLE_MAPS_KEY: KEY };
const NAME = "places/ChIJTest_123-abc/photos/AUc7tXtest_token-9";
const BYTES = new Uint8Array([255, 216, 255, 224, 1, 2, 3, 4]);
const realFetch = globalThis.fetch;

// A body object is JSON-encoded; `raw` sends the string as it is. A null token sends no token header.
const call = (body, { path = "/place-photo", token = "app-test", raw, method = "POST", e = env, headers = {} } = {}) =>
  worker.fetch(
    new Request(`https://x.test${path}`, {
      method,
      headers: { ...(token === null ? {} : { "x-besir-token": token }), ...headers },
      body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
    }),
    e,
  );

const image = () => new Response(BYTES, { status: 200, headers: { "content-type": "image/jpeg" } });

// Runs `fn` with a counting upstream stub; the stub answers with `responder` (default: an image).
async function withFetch(responder, fn) {
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push({ url: String(url), init: init ?? {} });
    return responder(String(url), init ?? {});
  };
  try {
    return await fn(seen);
  } finally {
    globalThis.fetch = realFetch;
  }
}

async function expectError(res, status, error) {
  assert.equal(res.status, status);
  assert.deepEqual(await res.json(), { error });
}

const valid = { name: NAME, max_width: 800 };

test("AC-FULLHAND-007 P01: the route is registered at exactly /place-photo, behind the token and method checks", async () => {
  await withFetch(image, async (seen) => {
    const res = await call(valid);
    assert.equal(res.status, 200);
    assert.equal(seen.length, 1);
  });
  await withFetch(image, async (seen) => {
    await expectError(await call(valid, { path: "/place-photos" }), 404, "not_found");
    await expectError(await call(valid, { path: "/place-photo/x" }), 404, "not_found");
    assert.equal(seen.length, 0);
  });
  // No token: 401 before the body is read.
  const unreadable = {
    method: "POST",
    url: "https://x.test/place-photo",
    headers: new Headers(),
    text: async () => {
      throw new Error("the body must not be read");
    },
  };
  await expectError(await worker.fetch(unreadable, env), 401, "unauthorized");
  await expectError(await call(valid, { token: "nope" }), 401, "unauthorized");
  await expectError(await call(null, { method: "GET" }), 405, "method_not_allowed");
});

test("AC-FULLHAND-007 P02: a valid body makes one upstream GET and the answer is the image with no-store", async () => {
  await withFetch(image, async (seen) => {
    const res = await call(valid);
    assert.equal(res.status, 200);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, `https://places.googleapis.com/v1/${NAME}/media?maxWidthPx=800&key=${KEY}`);
    assert.equal(seen[0].init.method, "GET");
    assert.equal(seen[0].init.redirect, "follow");
    assert.deepEqual([...new Uint8Array(await res.arrayBuffer())], [...BYTES]);
    assert.equal(res.headers.get("content-type"), "image/jpeg");
    assert.equal(res.headers.get("cache-control"), "no-store");
    const headerText = [...res.headers.entries()].flat().join("\n");
    assert.equal(headerText.includes(KEY), false);
    assert.equal(headerText.includes("places.googleapis.com"), false);
  });
});

test("AC-FULLHAND-007 P03: the ladder runs in order and an invalid request makes no upstream call", async () => {
  await withFetch(image, async (seen) => {
    await expectError(await call(null, { raw: "x".repeat(4097) }), 413, "body_too_large");
    await expectError(await call(null, { raw: "x".repeat(4096) }), 400, "invalid_json");
    await expectError(await call(null, { raw: "not json" }), 400, "invalid_json");
    await expectError(await call(null, { raw: "[1,2]" }), 400, "body_must_be_object");
    await expectError(await call(null, { raw: "null" }), 400, "body_must_be_object");
    // unknown_field before missing_field: an unknown key and no max_width.
    await expectError(await call({ name: NAME, x: 1 }), 400, "unknown_field");
    await expectError(await call({ x: 1 }), 400, "unknown_field");
    await expectError(await call({ name: NAME, max_width: 800, x: 1 }), 400, "unknown_field");
    // missing_field before invalid_field.
    await expectError(await call({ name: NAME }), 400, "missing_field");
    await expectError(await call({ max_width: 800 }), 400, "missing_field");
    await expectError(await call({ name: 5 }), 400, "missing_field");
    await expectError(await call({}), 400, "missing_field");
    await expectError(await call({ name: 5, max_width: 50 }), 400, "invalid_field");
    assert.equal(seen.length, 0);
  });
});

test("AC-FULLHAND-007 P04: the name rule accepts its edges and refuses everything else", async () => {
  const accepted = [
    "places/a/photos/b",
    `places/${"a".repeat(300)}/photos/b`,
    `places/a/photos/${"b".repeat(2000)}`,
    "places/A-z_9/photos/Z-a_0",
  ];
  for (const name of accepted) {
    await withFetch(image, async (seen) => {
      const res = await call({ name, max_width: 800 });
      assert.equal(res.status, 200, name.slice(0, 40));
      assert.equal(seen.length, 1);
    });
  }
  const refused = [
    5,
    null,
    "places/x/photos/",
    "places//photos/y",
    "places/x/photos/y/media",
    "places/x/photo/y",
    "../",
    "places/x/photos/y?",
    "places/x/photos/y&key=1",
    "places/x/photos/%2F",
    "places/x/photos/y z",
    "places/é/photos/y",
    "places/x/photos/y\n",
    `places/${"a".repeat(301)}/photos/b`,
    `places/a/photos/${"b".repeat(2001)}`,
  ];
  for (const name of refused) {
    await withFetch(image, async (seen) => {
      await expectError(await call({ name, max_width: 800 }), 400, "invalid_field");
      assert.equal(seen.length, 0);
    });
  }
});

test("AC-FULLHAND-007 P05: max_width is a whole number from 100 to 1600", async () => {
  for (const width of [100, 1600, 800]) {
    await withFetch(image, async (seen) => {
      assert.equal((await call({ name: NAME, max_width: width })).status, 200);
      assert.ok(seen[0].url.includes(`maxWidthPx=${width}&`));
    });
  }
  await withFetch(image, async (seen) => {
    const res = await call(null, { raw: `{"name":"${NAME}","max_width":800.0}` });
    assert.equal(res.status, 200);
    assert.ok(seen[0].url.includes("maxWidthPx=800&"));
  });
  for (const width of [99, 1601, 2.5, "800", true, null, [800]]) {
    await withFetch(image, async (seen) => {
      await expectError(await call({ name: NAME, max_width: width }), 400, "invalid_field");
      assert.equal(seen.length, 0);
    });
  }
});

test("AC-FULLHAND-007 P06: every other upstream outcome is 502 upstream_failed with no upstream text", async () => {
  const outcomes = [
    ["403", () => new Response("secret upstream text", { status: 403 })],
    ["404", () => new Response("secret upstream text", { status: 404 })],
    ["500", () => new Response("secret upstream text", { status: 500 })],
    ["200 text/html", () => new Response("<html>secret</html>", { status: 200, headers: { "content-type": "text/html" } })],
    [
      "declared length 5000001",
      () => new Response(BYTES, { status: 200, headers: { "content-type": "image/jpeg", "content-length": "5000001" } }),
    ],
    [
      "thrown fetch",
      () => {
        throw new Error("secret network text");
      },
    ],
  ];
  for (const [label, responder] of outcomes) {
    await withFetch(responder, async (seen) => {
      const res = await call(valid);
      assert.equal(res.status, 502, label);
      assert.equal(await res.text(), '{"error":"upstream_failed"}', label);
      assert.equal(seen.length, 1, label);
    });
  }
});

test("AC-FULLHAND-007 P07: no Worker key is 503 after a valid body, and an invalid body keeps its own error", async () => {
  const noKey = { APP_TOKEN: "app-test", META_API_KEY: "m" };
  await withFetch(image, async (seen) => {
    await expectError(await call(valid, { e: noKey }), 503, "google_key_not_configured");
    await expectError(await call(valid, { e: { ...noKey, GOOGLE_MAPS_KEY: "" } }), 503, "google_key_not_configured");
    await expectError(await call({ name: NAME }, { e: noKey }), 400, "missing_field");
    await expectError(await call({ name: "bad", max_width: 800 }, { e: noKey }), 400, "invalid_field");
    await expectError(await call(null, { raw: "nope", e: noKey }), 400, "invalid_json");
    assert.equal(seen.length, 0);
  });
});

test("AC-FULLHAND-007 P08: placephoto.js holds no fetch, env, clock, storage or random call", async () => {
  const strip = (source) => source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/\s\/\/.*$/gm, "");
  const code = strip(readFileSync(new URL("../src/placephoto.js", import.meta.url), "utf8"));
  for (const word of ["console", "fetch", "env", "Date", "KV", "D1", "R2"]) {
    assert.equal(new RegExp(`\\b${word}\\b`).test(code), false, `the source holds ${word}`);
  }
  for (const text of ["Math.random", "getRandomValues"]) {
    assert.equal(code.includes(text), false, `the source holds ${text}`);
  }
  // Positive controls: the same scan finds what it looks for, and the other files hold them.
  const indexSource = readFileSync(new URL("../src/index.js", import.meta.url), "utf8");
  assert.equal(/\bfetch\b/.test(strip(indexSource)), true);
  assert.equal(/\bfetch\b/.test("await fetch(x)"), true);
  assert.equal(/\bDate\b/.test("new Date()"), true);
  assert.equal(/\benv\b/.test("handle(request, env)"), true);
  assert.equal(code.includes("handlePlacePhoto"), true);
  // The route is named in the header comment of index.js.
  assert.match(indexSource.split("\n").slice(0, 14).join("\n"), /POST \/place-photo /);
});

test("AC-FULLHAND-007 P09: client Google headers are not forwarded and do not change the key used", async () => {
  await withFetch(image, async (seen) => {
    const res = await call(valid, {
      headers: { "x-goog-api-key": "evil-key", "x-goog-fieldmask": "places.id", authorization: "Bearer evil" },
    });
    assert.equal(res.status, 200);
    assert.equal(seen.length, 1);
    assert.ok(seen[0].url.endsWith(`&key=${KEY}`));
    assert.equal(seen[0].url.includes("evil"), false);
    const sent = new Headers(seen[0].init.headers ?? {});
    for (const name of ["x-goog-api-key", "x-goog-fieldmask", "authorization", "x-besir-token"]) {
      assert.equal(sent.has(name), false, name);
    }
  });
});

test("AC-FULLHAND-007 P10: nothing is kept between requests", async () => {
  await withFetch(image, async (seen) => {
    const first = await call(valid);
    const second = await call(valid);
    assert.equal(seen.length, 2);
    assert.deepEqual([...new Uint8Array(await first.arrayBuffer())], [...BYTES]);
    assert.deepEqual([...new Uint8Array(await second.arrayBuffer())], [...BYTES]);
  });
});
