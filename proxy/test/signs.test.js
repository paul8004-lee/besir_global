import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const KEY = "meta-test-KEY-456";
const env = { META_API_KEY: KEY, BASETEN_API_KEY: "bt-test", APP_TOKEN: "app-test", GOOGLE_MAPS_KEY: "g" };
const MAX_BODY = 6 * 1024 * 1024;
const META_URL = "https://api.meta.ai/v1/responses";
const BASETEN_URL = "https://inference.baseten.co/v1/chat/completions";

// Every answer of the tests below is kept so that S10 can look for the key in all of them.
const answers = [];

const call = async (path, { token = "app-test", body = {}, raw, method = "POST", e = env } = {}) => {
  const res = await worker.fetch(
    new Request(`https://x.test${path}`, {
      method,
      headers: { "x-besir-token": token },
      body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
    }),
    e,
  );
  answers.push(await res.clone().text());
  return res;
};

const pad = (n, head) => {
  const b = Buffer.alloc(n, 0x41);
  Buffer.from(head).copy(b);
  return b;
};
const jpeg = (n = 64) => pad(n, [0xff, 0xd8, 0xff, 0xe0]);
const png = (n = 64) => pad(n, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const b64 = (buf) => buf.toString("base64");
const img = (image = b64(jpeg()), mime = "image/jpeg", extra = {}) => ({ body: { image, mime, ...extra } });

const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");

// A synthetic answer in the shape of the real stream: the full text once in the deltas, again in the closing events.
function stream(text, { deltas = [text], completed = true, failed = false } = {}) {
  const ev = (type, body) => `event: ${type}\ndata: ${JSON.stringify({ ...body, type })}\n\n`;
  let out = ev("response.created", { response: { status: "in_progress", store: false } });
  for (const delta of deltas) out += ev("response.output_text.delta", { delta });
  out += ev("response.output_text.done", { text });
  out += ev("response.content_part.done", { part: { text } });
  out += ev("response.output_item.done", { item: { content: [{ text }] } });
  if (failed) out += ev("response.failed", { response: { status: "failed", error: { message: "x" } } });
  if (completed) out += ev("response.completed", { response: { status: "completed", output: [{ content: [{ text }] }] } });
  return out + "data: [DONE]\n\n";
}

const token = (i, [x1, y1, x2, y2, c], w = 2048, h = 1536) =>
  `${i}<|box;x1=${x1};y1=${y1};x2=${x2};y2=${y2};w=${w};h=${h};c=${c}|><|mask;x=0;y=0;c=${c};data=71,70,~!!!1!#K|>`;
const textOf = (boxes, w, h) => "<0f>" + boxes.map((b, i) => token(i, b, w, h)).join(",");
const streamOf = (boxes, w, h, options) => stream(textOf(boxes, w, h), options);

const sseReply = (text, status = 200) => new Response(text, { status, headers: { "content-type": "text/event-stream" } });

function mockUpstream(handler) {
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push({ url, init });
    return handler(url, init);
  };
  return seen;
}
const mockSse = (text) => mockUpstream(() => sseReply(text));

async function expectError(res, status, error) {
  assert.equal(res.status, status);
  assert.deepEqual(await res.json(), { error });
}

const out = (w, h, boxes) =>
  JSON.stringify({ width: w, height: h, boxes: boxes.map(([x1, y1, x2, y2, confidence]) => ({ x1, y1, x2, y2, confidence })) });

test("AC-SIGNPICK-001: S01 a missing token, GET and an unset key answer before any body is read or upstream call", async () => {
  const seen = mockSse(fixture("signs-img2.sse"));
  await expectError(await call("/signs", { token: "", ...img() }), 401, "unauthorized");
  await expectError(await call("/signs", { token: "nope", ...img() }), 401, "unauthorized");
  assert.equal((await call("/signs", { method: "GET" })).status, 405);
  // The body is invalid JSON: reading it first would answer 400 invalid_json.
  await expectError(await call("/signs", { raw: "{", e: { ...env, META_API_KEY: undefined } }), 503, "meta_key_not_configured");
  await expectError(await call("/signs", { raw: "{", e: { ...env, META_API_KEY: "" } }), 503, "meta_key_not_configured");
  assert.equal(seen.length, 0);
  // Positive control: the same request with a key reads the body.
  await expectError(await call("/signs", { raw: "{" }), 400, "invalid_json");
});

test("AC-SIGNPICK-001: S02 the validation order, the error names and the size bounds, with no upstream call for a refusal", async () => {
  const seen = mockSse(fixture("signs-img2.sse"));
  await expectError(await call("/signs", { raw: "{" }), 400, "invalid_json");
  await expectError(await call("/signs", { raw: "[]" }), 400, "body_must_be_object");
  await expectError(await call("/signs", { raw: "null" }), 400, "body_must_be_object");
  await expectError(await call("/signs", { body: {} }), 400, "image_required");
  await expectError(await call("/signs", { body: { image: "", mime: "image/jpeg" } }), 400, "image_required");
  await expectError(await call("/signs", { body: { mime: "image/gif" } }), 400, "image_required");
  await expectError(await call("/signs", { body: { image: "!!!!", mime: "image/gif" } }), 400, "mime_not_allowed");
  await expectError(await call("/signs", { body: { image: "!!!!", mime: "image/jpeg" } }), 400, "image_not_base64");
  await expectError(await call("/signs", { body: { image: "abc", mime: "image/jpeg" } }), 400, "image_not_base64");
  await expectError(await call("/signs", img(b64(png()), "image/jpeg")), 400, "image_mime_mismatch");
  await expectError(await call("/signs", img(b64(jpeg()), "image/png")), 400, "image_mime_mismatch");
  const over = `{"image":"","mime":"image/jpeg","pad":"${"x".repeat(MAX_BODY)}"}`;
  await expectError(await call("/signs", { raw: over }), 413, "body_too_large");
  // 4 MiB of image is refused one byte over; the body text stays far below 6 MiB.
  await expectError(await call("/signs", img(b64(jpeg(4 * 1024 * 1024 + 1)))), 413, "image_too_large");
  assert.equal(seen.length, 0);

  // At the bounds the request is accepted.
  assert.equal((await call("/signs", img(b64(jpeg(4 * 1024 * 1024))))).status, 200);
  const head = '{"image":"';
  const tail = `","mime":"image/jpeg","pad":"`;
  const small = b64(jpeg());
  const fixed = head.length + small.length + tail.length + 2;
  const exact = `${head}${small}${tail}${"x".repeat(MAX_BODY - fixed)}"}`;
  assert.equal(exact.length, MAX_BODY);
  assert.equal((await call("/signs", { raw: exact })).status, 200);
  assert.equal(seen.length, 2);
});

test("AC-SIGNPICK-001: S03 one fixed request goes to Meta, whatever else the client sends", async () => {
  const seen = mockSse(fixture("signs-img2.sse"));
  const image = b64(jpeg(300));
  const expected = {
    model: "sam-3.1",
    stream: true,
    store: false,
    metadata: { include_confidence: "true" },
    input: [
      {
        type: "message",
        role: "user",
        content: [
          { type: "input_text", text: "storefront sign" },
          { type: "input_image", image_url: `data:image/jpeg;base64,${image}` },
        ],
      },
    ],
  };
  assert.equal((await call("/signs", img(image))).status, 200);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, META_URL);
  assert.equal(seen[0].init.method, "POST");
  const headers = new Headers(seen[0].init.headers);
  assert.equal(headers.get("authorization"), `Bearer ${KEY}`);
  assert.equal(headers.get("content-type"), "application/json");
  assert.deepEqual(JSON.parse(seen[0].init.body), expected);

  const extra = { concept: "menu board", model: "other", store: true, stream: false, metadata: { x: 1 }, input: [], location: { lat: 1, lng: 2 } };
  assert.equal((await call("/signs", img(image, "image/jpeg", extra))).status, 200);
  assert.equal(seen.length, 2);
  assert.deepEqual(JSON.parse(seen[1].init.body), expected);
});

test("AC-SIGNPICK-002: S04 photo 1 gives the awning and the street sign, the inner sign and three small boxes dropped", async () => {
  mockSse(fixture("signs-img1.sse"));
  const res = await call("/signs", img());
  assert.equal(res.status, 200);
  const text = await res.text();
  assert.equal(text, out(2048, 1356, [[1152, 538, 1668, 639, 0.597484290599823], [1122, 441, 1203, 482, 0.5586]]));
  assert.ok(!text.includes("mask") && !text.includes("data="));
});

test("AC-SIGNPICK-002: S05 photo 2 gives the sign then the banner, the small notice dropped", async () => {
  mockSse(fixture("signs-img2.sse"));
  const res = await call("/signs", img());
  assert.equal(res.status, 200);
  assert.equal(await res.text(), out(2048, 1536, [[636, 774, 766, 837, 0.6683937907218933], [518, 786, 587, 856, 0.5114504098892212]]));
});

test("AC-SIGNPICK-002: S06 thirteen boxes give the first five by confidence, the 40 by 40 box dropped by size", async () => {
  mockSse(fixture("signs-many.sse"));
  const res = await call("/signs", img());
  assert.equal(res.status, 200);
  assert.equal(
    await res.text(),
    out(2048, 1536, [
      [900, 40, 1600, 600, 0.86],
      [1800, 1000, 1870, 1070, 0.78],
      [640, 750, 750, 920, 0.75],
      [340, 1040, 560, 1130, 0.67],
      [1980, 940, 2045, 1040, 0.668],
    ]),
  );
});

async function answerFor(boxes, w, h, options) {
  mockSse(streamOf(boxes, w, h, options));
  const res = await call("/signs", img());
  assert.equal(res.status, 200);
  return res.text();
}

test("AC-SIGNPICK-002: S07 the reduction bounds, the order and the cap, each at its edge", async () => {
  // Short side: 24 kept, 23 dropped. Long side: 60 kept, 59 dropped.
  assert.equal(await answerFor([[100, 100, 184, 124, 0.9]]), out(2048, 1536, [[100, 100, 184, 124, 0.9]]));
  assert.equal(await answerFor([[100, 100, 184, 123, 0.9]]), out(2048, 1536, []));
  assert.equal(await answerFor([[100, 100, 160, 150, 0.9]]), out(2048, 1536, [[100, 100, 160, 150, 0.9]]));
  assert.equal(await answerFor([[100, 100, 159, 150, 0.9]]), out(2048, 1536, []));

  // Inside rule: exactly 80 % of the inner box inside the container is dropped, 79 % is kept.
  const container = [100, 100, 300, 300, 0.9];
  assert.equal(await answerFor([container, [220, 120, 320, 220, 0.8]]), out(2048, 1536, [container]));
  assert.equal(await answerFor([container, [221, 120, 321, 220, 0.8]]), out(2048, 1536, [container, [221, 120, 321, 220, 0.8]]));

  // A container of exactly 25 % of the image drops its inner box, one a column wider does not.
  const quarter = [0, 0, 1024, 768, 0.9];
  const wide = [0, 0, 1025, 768, 0.9];
  const inner = [100, 100, 300, 300, 0.8];
  assert.equal(await answerFor([quarter, inner]), out(2048, 1536, [quarter]));
  assert.equal(await answerFor([wide, inner]), out(2048, 1536, [wide, inner]));

  // Equal confidences: larger area first, then smaller y1, then smaller x1.
  const A = [10, 500, 110, 600, 0.7];
  const B = [300, 100, 420, 200, 0.7];
  const C = [600, 50, 700, 150, 0.7];
  const D = [500, 50, 600, 150, 0.7];
  const E = [700, 400, 800, 500, 0.7];
  assert.equal(await answerFor([A, C, E, D, B]), out(2048, 1536, [B, D, C, E, A]));

  // Seven boxes give five.
  const seven = [0, 1, 2, 3, 4, 5, 6].map((i) => [100 + i * 200, 100, 200 + i * 200, 200, 0.5 + i / 100]);
  assert.equal(await answerFor(seven), out(2048, 1536, seven.slice(2).reverse()));

  // A completed stream with no box.
  assert.equal(await answerFor([]), out(0, 0, []));

  // A box token split across two deltas.
  const whole = textOf([[900, 40, 1600, 600, 0.86]]);
  const cut = whole.indexOf("x2=") + 2;
  assert.equal(
    await answerFor([[900, 40, 1600, 600, 0.86]], 2048, 1536, { deltas: [whole.slice(0, cut), whole.slice(cut)] }),
    out(2048, 1536, [[900, 40, 1600, 600, 0.86]]),
  );
});

test("AC-SIGNPICK-003: S08 a stream that is not whole and well formed gives 502 signs_unparseable, a huge one signs_too_large", async () => {
  const good = [900, 40, 1600, 600, 0.86];
  const bad = async (text) => {
    const seen = mockSse(text);
    await expectError(await call("/signs", img()), 502, "signs_unparseable");
    assert.equal(seen.length, 1);
  };
  await bad(streamOf([good], 2048, 1536, { completed: false }));
  await bad(streamOf([[900, 40, 900, 600, 0.86]]));
  await bad(streamOf([[900, 40, 800, 600, 0.86]]));
  await bad(streamOf([[900, 40, 2049, 600, 0.86]]));
  await bad(streamOf([[900, 40, 1600, 1537, 0.86]]));
  await bad(streamOf([[900.5, 40, 1600, 600, 0.86]]));
  await bad(stream("<0f>" + token(0, good) + "," + token(1, [100, 100, 300, 300, 0.8], 2047, 1536)));
  await bad(streamOf([[900, 40, 1600, 600, ""]]));
  await bad(streamOf([[900, 40, 1600, 600, "abc"]]));
  await bad(streamOf([good], 2048, 1536, { failed: true }));
  await bad(stream("<0f>" + token(0, good).replace("x1=900", "x1=-1")));

  // 2 MiB of text is the bound.
  mockSse(stream("<0f>" + "x".repeat(2 * 1024 * 1024)));
  await expectError(await call("/signs", img()), 502, "signs_too_large");
});

test("AC-SIGNPICK-003: S09 every upstream failure gives a fixed answer with nothing of the upstream, one call each", async () => {
  const cases = [
    [429, 429, "signs_rate_limited"],
    [401, 502, "signs_upstream_auth"],
    [403, 502, "signs_upstream_auth"],
    [400, 502, "signs_upstream_rejected"],
    [404, 502, "signs_upstream_error"],
    [500, 502, "signs_upstream_unavailable"],
    [503, 502, "signs_upstream_unavailable"],
    [201, 502, "signs_upstream_error"],
    [204, 502, "signs_upstream_error"],
    [299, 502, "signs_upstream_error"],
  ];
  for (const [upstream, status, error] of cases) {
    const seen = mockUpstream(
      () => new Response(upstream === 204 ? null : "SECRET-UPSTREAM-BODY", { status: upstream, headers: { "x-secret": "SECRET-UPSTREAM-HEADER" } }),
    );
    const res = await call("/signs", img());
    assert.equal(res.status, status, `upstream ${upstream}`);
    const text = await res.text();
    assert.equal(text, JSON.stringify({ error }), `upstream ${upstream}`);
    assert.ok(!text.includes("SECRET"));
    assert.equal(res.headers.get("x-secret"), null);
    assert.equal(seen.length, 1);
  }

  let seen = mockUpstream(() => {
    throw new TypeError("network down SECRET-UPSTREAM-BODY");
  });
  await expectError(await call("/signs", img()), 502, "upstream_unreachable");
  assert.equal(seen.length, 1);

  seen = mockUpstream(() => {
    throw new DOMException("timed out", "TimeoutError");
  });
  await expectError(await call("/signs", img()), 504, "signs_timeout");
  assert.equal(seen.length, 1);

  // A 200 whose stream delivers a first piece and then stalls until the timer fires.
  let pulls = 0;
  seen = mockUpstream(
    () =>
      new Response(
        new ReadableStream({
          pull(controller) {
            if (pulls++ === 0) controller.enqueue(new TextEncoder().encode("event: response.created\n"));
            else controller.error(new DOMException("timed out", "TimeoutError"));
          },
        }),
        { status: 200, headers: { "content-type": "text/event-stream" } },
      ),
  );
  await expectError(await call("/signs", img()), 504, "signs_timeout");
  assert.equal(seen.length, 1);
  assert.ok(seen[0].init.signal instanceof AbortSignal, "the timer covers the body");
});

test("AC-SIGNPICK-003: S10 the key is in no answer, signs.js keeps no state or log, /signs and /snap reach their own upstreams", async () => {
  assert.ok(answers.length > 20, "positive control: answers were collected");
  assert.ok(answers.some((text) => text.includes("signs_unparseable")), "positive control: an error answer was collected");
  assert.deepEqual(answers.filter((text) => text.includes(KEY)), []);
  assert.ok(["x" + KEY].filter((text) => text.includes(KEY)).length === 1, "positive control: the check finds a planted key");

  const source = readFileSync(new URL("../src/signs.js", import.meta.url), "utf8");
  const bad = (text) =>
    [
      text.includes("console."),
      /^(let|var)\s/m.test(text),
      /^(const|let|var)\s+\w+\s*=\s*new Map\(/m.test(text),
      /^const\s+\w+\s*=\s*(\{\s*\}|\[\s*\]|new Set\()/m.test(text),
    ].some(Boolean);
  assert.ok(source.includes("AbortSignal"), "positive control: the source was read");
  assert.equal(bad(source), false);
  for (const planted of ["console.log(1)", "\nlet a = 1", "\nvar a = 1", "\nconst a = new Map()", "\nconst a = {}", "\nconst a = []", "\nconst a = new Set()"]) {
    assert.equal(bad(planted), true, `positive control: ${planted.trim()}`);
  }

  let seen = mockSse(fixture("signs-img2.sse"));
  assert.equal((await call("/signs", img())).status, 200);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, META_URL);

  seen = mockUpstream(
    () =>
      new Response(
        JSON.stringify({ choices: [{ message: { content: JSON.stringify({ kind: "unknown", name: null, place_type: null, text: null, title: null, time: null, confidence: 0.5 }) }, finish_reason: "stop" }] }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
  );
  assert.equal((await call("/snap", img())).status, 200);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, BASETEN_URL);
});
