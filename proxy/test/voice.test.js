import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import worker from "../src/index.js";

const KEY = "meta-test-KEY-123";
const env = { META_API_KEY: KEY, APP_TOKEN: "app-test", GOOGLE_MAPS_KEY: "g", BASETEN_API_KEY: "b" };
const UPSTREAM = "https://api.meta.ai/v1/asr/transcribe";
const REQUEST_JSON = '{"mode":"PUSH_TO_TALK","model":"muse-voice-transcribe-1.0","audioEncoding":"WAV"}';
const MAX_BODY_CHARS = 1_400_000;

// A body object is JSON-encoded; `raw` sends the string as it is.
const call = (path, { token = "app-test", body = {}, raw, method = "POST", e = env, headers = {} } = {}) =>
  worker.fetch(
    new Request(`https://x.test${path}`, {
      method,
      headers: { "x-besir-token": token, ...headers },
      body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
    }),
    e,
  );

const reply = (payload, status = 200, headers = {}) =>
  new Response(typeof payload === "string" ? payload : JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });

function mockUpstream(handler) {
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push({ url, init });
    return handler(url, init);
  };
  return seen;
}
const mockText = (transcript = "move dinner thirty minutes later") => mockUpstream(() => reply({ transcript }));

async function expectError(res, status, error) {
  assert.equal(res.status, status);
  assert.deepEqual(await res.json(), { error });
}

// A WAV builder. `before` and `between` hold extra chunks placed before "fmt " and between "fmt " and "data".
const u16 = (n) => {
  const b = Buffer.alloc(2);
  b.writeUInt16LE(n);
  return b;
};
const u32 = (n) => {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n);
  return b;
};
const chunk = (id, payload) =>
  Buffer.concat([Buffer.from(id, "latin1"), u32(payload.length), payload, payload.length % 2 ? Buffer.alloc(1) : Buffer.alloc(0)]);
const samples = (n, fill = 0x41) => Buffer.alloc(n, fill);
const fmtChunk = ({ tag = 1, channels = 1, rate = 16000, bits = 16 } = {}) =>
  chunk("fmt ", Buffer.concat([u16(tag), u16(channels), u32(rate), u32((rate * channels * bits) / 8), u16((channels * bits) / 8), u16(bits)]));

function wav({
  data = samples(32000),
  before = [],
  between = [],
  omitFmt = false,
  omitData = false,
  dataFirst = false,
  declared,
  riff = "RIFF",
  wave = "WAVE",
  ...format
} = {}) {
  const dataChunk = declared === undefined ? chunk("data", data) : Buffer.concat([Buffer.from("data", "latin1"), u32(declared), data]);
  const fmt = omitFmt ? [] : [fmtChunk(format)];
  const parts = dataFirst ? [...before, dataChunk, ...fmt] : [...before, ...fmt, ...between, ...(omitData ? [] : [dataChunk])];
  const body = Buffer.concat([Buffer.from(wave, "latin1"), ...parts]);
  return Buffer.concat([Buffer.from(riff, "latin1"), u32(body.length), body]);
}
const clip = (opts) => ({ body: { audio: wav(opts).toString("base64") } });
const okClip = () => clip();

async function audioOf(seen, i = 0) {
  return Buffer.from(await seen[i].init.body.get("audio").arrayBuffer());
}

test("AC-VOICE-002/004: V01 a valid clip answers {text}; the one upstream call is exactly the fixed multipart request", async () => {
  const seen = mockText("move dinner thirty minutes later");
  const res = await call("/voice", okClip());
  assert.equal(res.status, 200);
  const answer = await res.json();
  assert.deepEqual(Object.keys(answer), ["text"]);
  assert.equal(answer.text, "move dinner thirty minutes later");
  assert.equal(seen.length, 1);
  const { url, init } = seen[0];
  assert.equal(String(url), UPSTREAM);
  assert.equal(new URL(String(url)).search, "");
  assert.equal(init.method, "POST");
  assert.deepEqual(Object.keys(init.headers).sort(), ["accept", "authorization"]);
  assert.equal(init.headers.authorization, `Bearer ${KEY}`);
  assert.equal(init.headers.accept, "application/json");
  assert.ok(init.signal instanceof AbortSignal);
  assert.equal(init.redirect, "manual");
  assert.ok(init.body instanceof FormData);
  assert.deepEqual([...init.body.keys()], ["request", "audio"]);
  const request = init.body.get("request");
  assert.equal(request.type, "application/json");
  assert.equal(await request.text(), REQUEST_JSON);
  const audio = init.body.get("audio");
  assert.equal(audio.type, "audio/wav");
  assert.equal(audio.name, "audio.wav");
});

test("AC-VOICE-002: V02 token, method and key gates answer before the route reads the body, with zero upstream calls", async () => {
  const seen = mockText();
  assert.equal((await call("/voice", okClip())).status, 200);
  const before = seen.length;
  assert.equal(before, 1);
  for (const opts of [
    { token: "" },
    { token: "nope" },
    { e: { ...env, APP_TOKEN: "" } },
    { e: { META_API_KEY: KEY } },
  ]) {
    await expectError(await call("/voice", { ...okClip(), ...opts }), 401, "unauthorized");
  }
  await expectError(await call("/voice", { method: "GET" }), 405, "method_not_allowed");
  const { META_API_KEY, ...unset } = env;
  for (const e of [unset, { ...env, META_API_KEY: "" }]) {
    await expectError(await call("/voice", { raw: "{", e }), 503, "meta_key_not_configured");
    await expectError(await call("/voice", { ...okClip(), e }), 503, "meta_key_not_configured");
  }
  assert.equal(seen.length, before);
});

test("AC-VOICE-003: V03 every invalid body, base64, header, format and size is a typed 4xx with zero upstream calls", async () => {
  const seen = mockText();
  assert.equal((await call("/voice", okClip())).status, 200);
  assert.equal(seen.length, 1);
  const before = seen.length;

  const b64 = (buf) => buf.toString("base64");
  const rows = [
    [{ raw: "{" }, 400, "invalid_json"],
    [{ raw: "[]" }, 400, "body_must_be_object"],
    [{ raw: '"x"' }, 400, "body_must_be_object"],
    [{ raw: "null" }, 400, "body_must_be_object"],
    [{ raw: "x".repeat(MAX_BODY_CHARS + 1) }, 413, "body_too_large"],
    [{ body: {} }, 400, "audio_required"],
    [{ body: { audio: "" } }, 400, "audio_required"],
    [{ body: { audio: 5 } }, 400, "audio_required"],
    [{ body: { audio: null } }, 400, "audio_required"],
    [{ body: { audio: "abc" } }, 400, "audio_not_base64"],
    [{ body: { audio: "ab!d" } }, 400, "audio_not_base64"],
    [{ body: { audio: "a===" } }, 400, "audio_not_base64"],
    [{ body: { audio: "=AAA" } }, 400, "audio_not_base64"],
    [{ body: { audio: "AA=A" } }, 400, "audio_not_base64"],
    [{ body: { audio: b64(samples(1_000_001, 0)) } }, 413, "audio_too_large"],
    [{ body: { audio: b64(Buffer.concat([Buffer.from("RIFX"), wav().subarray(4)])) } }, 400, "audio_not_wav"],
    [clip({ wave: "WAVX" }), 400, "audio_not_wav"],
    [{ body: { audio: b64(Buffer.from("RIFF\0\0\0\0WAV")) } }, 400, "audio_not_wav"],
    [clip({ omitData: true }), 400, "audio_not_wav"],
    [clip({ omitFmt: true }), 400, "audio_not_wav"],
    [clip({ dataFirst: true }), 400, "audio_not_wav"],
    [clip({ declared: 40000 }), 400, "audio_not_wav"],
    [clip({ data: samples(3201) }), 400, "audio_not_wav"],
    [clip({ channels: 2 }), 400, "audio_format_unsupported"],
    [clip({ bits: 8 }), 400, "audio_format_unsupported"],
    [clip({ bits: 24 }), 400, "audio_format_unsupported"],
    [clip({ rate: 24000 }), 400, "audio_format_unsupported"],
    [clip({ rate: 44100 }), 400, "audio_format_unsupported"],
    [clip({ tag: 3 }), 400, "audio_format_unsupported"],
    [clip({ tag: 0xfffe }), 400, "audio_format_unsupported"],
    [clip({ data: samples(3198) }), 400, "audio_empty"],
    [clip({ data: samples(960002) }), 400, "audio_too_long"],
  ];
  for (const [opts, status, error] of rows) {
    await expectError(await call("/voice", opts), status, error);
  }
  assert.equal(seen.length, before, "no invalid request reached the upstream");

  for (const n of [3200, 960000]) {
    assert.equal((await call("/voice", clip({ data: samples(n) }))).status, 200, `${n} data bytes are accepted`);
  }
  assert.equal(seen.length, before + 2);
});

test("AC-VOICE-003: V04 padding chunks anywhere before data are skipped and the upstream gets a rebuilt plain 44-byte-header WAV", async () => {
  const seen = mockText();
  const pcm = (n, offset) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 7 + offset) & 0xff));
  const cases = [
    { data: pcm(32000, 1), between: [chunk("FLLR", Buffer.alloc(4044)), chunk("LIST", Buffer.from("abcde"))] },
    { data: pcm(16000, 2), before: [chunk("JUNK", Buffer.alloc(28))], between: [chunk("FLLR", Buffer.alloc(4008))] },
    { data: pcm(6400, 3), before: [chunk("LIST", Buffer.from("1234567"))] },
  ];
  for (const [i, opts] of cases.entries()) {
    assert.equal((await call("/voice", clip(opts))).status, 200, `case ${i} answers 200`);
  }
  assert.equal(seen.length, 3);
  for (const [i, opts] of cases.entries()) {
    const sent = await audioOf(seen, i);
    const n = opts.data.length;
    assert.equal(sent.length, 44 + n);
    assert.equal(sent.toString("latin1", 0, 4), "RIFF");
    assert.equal(sent.readUInt32LE(4), 36 + n);
    assert.equal(sent.toString("latin1", 8, 12), "WAVE");
    assert.equal(sent.toString("latin1", 12, 16), "fmt ");
    assert.equal(sent.readUInt32LE(16), 16);
    assert.deepEqual(
      [sent.readUInt16LE(20), sent.readUInt16LE(22), sent.readUInt32LE(24), sent.readUInt32LE(28), sent.readUInt16LE(32), sent.readUInt16LE(34)],
      [1, 1, 16000, 32000, 2, 16],
    );
    assert.equal(sent.toString("latin1", 36, 40), "data");
    assert.equal(sent.readUInt32LE(40), n);
    assert.ok(sent.subarray(44).equals(opts.data), `case ${i} sample bytes are unchanged`);
  }
});

test("AC-VOICE-004: V05 the client steers nothing: body keys, query string and headers leave the upstream request as in V01", async () => {
  const seen = mockText();
  const plain = await call("/voice", okClip());
  assert.equal(plain.status, 200);
  assert.equal(seen.length, 1);
  const steered = await call("/voice?model=x&sessionId=y&mode=z", {
    body: {
      audio: okClip().body.audio,
      model: "other-model",
      mode: "DIARIZATION",
      languageBias: "ko",
      keywords: ["a"],
      audioEncoding: "PCM_16KHZ",
      sessionId: "s1",
    },
    headers: {
      accept: "text/html",
      authorization: "Bearer evil",
      "content-type": "text/plain",
      "x-forwarded-for": "1.2.3.4",
      "x-goog-api-key": "evil",
    },
  });
  assert.equal(steered.status, 200);
  assert.equal(seen.length, 2);
  assert.equal(String(seen[1].url), UPSTREAM);
  assert.equal(String(seen[1].url), String(seen[0].url));
  assert.deepEqual(seen[1].init.headers, seen[0].init.headers);
  assert.equal(await seen[1].init.body.get("request").text(), REQUEST_JSON);
  assert.deepEqual([...seen[1].init.body.keys()], ["request", "audio"]);
  assert.ok((await audioOf(seen, 1)).equals(await audioOf(seen, 0)));
});

test("AC-VOICE-005: V06 upstream failures map to small typed errors, never upstream text", async () => {
  const good = mockText();
  assert.equal((await call("/voice", okClip())).status, 200);
  assert.equal(good.length, 1);

  const UPSTREAM_TEXT = "secret upstream words";
  const statusRows = [
    [429, 429, "voice_rate_limited"],
    [401, 502, "voice_upstream_auth"],
    [403, 502, "voice_upstream_auth"],
    [404, 502, "voice_upstream_not_found"],
    [400, 502, "voice_upstream_rejected"],
    [406, 502, "voice_upstream_error"],
    [413, 502, "voice_upstream_error"],
    [418, 502, "voice_upstream_error"],
    [500, 502, "voice_upstream_unavailable"],
    [503, 502, "voice_upstream_unavailable"],
  ];
  for (const [upstreamStatus, status, error] of statusRows) {
    const seen = mockUpstream(() =>
      reply(upstreamStatus === 404 ? { error: { code: "model_not_found", message: UPSTREAM_TEXT } } : { error: UPSTREAM_TEXT }, upstreamStatus),
    );
    const res = await call("/voice", okClip());
    assert.equal(res.status, status, `upstream ${upstreamStatus}`);
    const body = await res.json();
    assert.deepEqual(body, { error, upstream_status: upstreamStatus }, `upstream ${upstreamStatus}`);
    assert.equal(seen.length, 1);
  }

  const redirects = [
    () => reply({ transcript: "x" }, 201),
    () => new Response("", { status: 302, headers: { location: "https://evil.test/next" } }),
    () => new Response("", { status: 308, headers: { location: "https://evil.test/next" } }),
  ];
  for (const make of redirects) {
    const seen = mockUpstream(make);
    const res = await call("/voice", okClip());
    const status = make().status;
    assert.equal(res.status, 502, `returned ${status}`);
    assert.deepEqual(await res.json(), { error: "voice_unparseable", upstream_status: status });
    assert.equal(seen.length, 1, `the redirect target of ${status} is never fetched`);
  }

  mockUpstream(() => {
    throw new TypeError("fetch failed");
  });
  await expectError(await call("/voice", okClip()), 502, "upstream_unreachable");
  mockUpstream(() => {
    throw new DOMException("The operation timed out", "TimeoutError");
  });
  await expectError(await call("/voice", okClip()), 504, "voice_timeout");
});

test("AC-VOICE-005: V07 the reply is {text} only, collapsed, trimmed and cut to 1000 code points; anything else is voice_unparseable", async () => {
  mockText();
  assert.equal((await call("/voice", okClip())).status, 200);

  mockUpstream(() =>
    reply({ sessionId: "s", audioDurationMs: 1200, turns: [{ t: 1 }], transcript: "  move   dinner\n30 minutes later " }),
  );
  const shaped = await call("/voice", okClip());
  assert.equal(shaped.status, 200);
  assert.equal(await shaped.text(), '{"text":"move dinner 30 minutes later"}');

  mockUpstream(() => reply({ transcript: "a".repeat(1100) }));
  const long = await (await call("/voice", okClip())).json();
  assert.equal([...long.text].length, 1000);
  mockUpstream(() => reply({ transcript: "\u{1F600}".repeat(1100) }));
  assert.equal([...(await (await call("/voice", okClip())).json()).text].length, 1000);

  mockUpstream(() => reply({ transcript: "" }));
  const empty = await call("/voice", okClip());
  assert.equal(empty.status, 200);
  assert.deepEqual(await empty.json(), { text: "" });

  const bad = [
    () => reply({ sessionId: "s" }),
    () => reply({ transcript: 5 }),
    () => reply({ transcript: null }),
    () => reply([{ transcript: "x" }]),
    () => reply("not json at all"),
    () => new Response(null, { status: 204 }),
  ];
  for (const make of bad) {
    mockUpstream(make);
    const res = await call("/voice", okClip());
    assert.equal(res.status, 502);
    assert.equal((await res.json()).error, "voice_unparseable");
  }
});

test("AC-VOICE-006: V08 no trace: the key is in no answer, nothing is logged, nothing is kept between requests, nothing is stored", async () => {
  const seen = mockText();
  const first = clip({ data: samples(32000, 0x11) });
  const second = clip({ data: samples(32000, 0x22) });
  assert.equal((await call("/voice", first)).status, 200);
  assert.equal((await call("/voice", second)).status, 200);
  assert.equal(seen.length, 2);
  const secondAudio = await audioOf(seen, 1);
  assert.ok(!secondAudio.includes(samples(64, 0x11)), "the second body holds none of the first clip's bytes");
  assert.ok(secondAudio.includes(samples(64, 0x22)));

  const names = ["log", "error", "warn", "info"];
  const original = Object.fromEntries(names.map((n) => [n, console[n]]));
  let logged = 0;
  for (const n of names) console[n] = () => logged++;
  const seenAnswers = [];
  try {
    const echo = (status) => () => reply({ error: `the key is ${KEY}` }, status);
    for (const make of [() => reply({ transcript: "ok" }), echo(200), echo(401), echo(429), echo(500), echo(404), () => reply("nope", 200)]) {
      mockUpstream(make);
      seenAnswers.push(await call("/voice", okClip()));
    }
    mockUpstream(() => {
      throw new TypeError(`fetch failed for ${KEY}`);
    });
    seenAnswers.push(await call("/voice", okClip()));
    mockUpstream(() => {
      throw new DOMException(`timeout ${KEY}`, "TimeoutError");
    });
    seenAnswers.push(await call("/voice", okClip()));
    mockText();
    seenAnswers.push(await call("/voice", { token: "" }));
    seenAnswers.push(await call("/voice", { raw: "{" }));
    seenAnswers.push(await call("/voice", { body: {} }));
    seenAnswers.push(await call("/voice", { ...okClip(), e: { ...env, META_API_KEY: "" } }));
  } finally {
    for (const n of names) console[n] = original[n];
  }
  assert.equal(logged, 0, "no console call during a request");
  assert.ok(seenAnswers.length >= 12);
  for (const res of seenAnswers) {
    const text = (await res.text()) + JSON.stringify([...res.headers.entries()]);
    assert.ok(!text.includes(KEY), "the key is in no body and no header value");
  }

  const sourceUrl = new URL("../src/voice.js", import.meta.url);
  assert.ok(existsSync(sourceUrl), "positive control: voice.js exists");
  const source = readFileSync(sourceUrl, "utf8");
  assert.ok(source.includes("AbortSignal"), "positive control: the source was read");
  assert.ok(!source.includes("console"));
  assert.ok(!/^(let|var)\s/m.test(source));
  for (const word of ["caches", "KV", "waitUntil"]) assert.ok(!source.includes(word), word);
  const keyNames = new Set(source.match(/\b[A-Z][A-Z0-9_]*_(?:KEY|TOKEN|SECRET)\b/g));
  assert.deepEqual([...keyNames], ["META_API_KEY"]);

  const BINDINGS = ["kv_namespaces", "d1_databases", "r2_buckets", "durable_objects", "queues", "services", "vars", "analytics_engine"];
  const stripComments = (text) => text.split("\n").filter((line) => !line.trimStart().startsWith("#")).join("\n");
  const bindingsIn = (text) => BINDINGS.filter((name) => stripComments(text).includes(name));
  const toml = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
  assert.ok(stripComments(toml).includes("[placement]"), "positive control: the stripped text was read");
  assert.deepEqual(bindingsIn(toml), []);
  assert.deepEqual(bindingsIn(toml + '\n[vars]\nX = "1"\n'), ["vars"], "positive control: the scan sees a [vars] table");
  assert.ok(!/voice/i.test(toml), "wrangler.toml names no voice setting or secret");
});

test("AC-VOICE-002: V09 /voice is exactly one route; the neighbours still answer their own shapes", async () => {
  const seen = mockText();
  assert.equal((await call("/voice", okClip())).status, 200);
  assert.equal(seen.length, 1);
  await expectError(await call("/voicex", okClip()), 404, "not_found");
  await expectError(await call("/voice/", okClip()), 404, "not_found");
  assert.equal(seen.length, 1);

  await expectError(await call("/snap", { token: "" }), 401, "unauthorized");
  await expectError(await call("/vision", { token: "" }), 401, "unauthorized");
  await expectError(await call("/snap", { method: "GET" }), 405, "method_not_allowed");
  await expectError(await call("/vision", { method: "GET" }), 405, "method_not_allowed");
  const { BASETEN_API_KEY, ...noBaseten } = env;
  await expectError(await call("/snap", { raw: "{", e: noBaseten }), 503, "baseten_key_not_configured");

  const index = readFileSync(new URL("../src/index.js", import.meta.url), "utf8");
  assert.ok(index.includes("POST /snap"), "positive control: index.js was read");
  assert.ok(/^\/\/   POST \/voice  -> /m.test(index), "the header comment lists POST /voice");
  assert.equal(index.split('import { handleVoice } from "./voice.js";').length - 1, 1);
});
