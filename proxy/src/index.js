// besir-global-proxy: keeps the Meta and Google keys off the device.
//   POST /ai      -> Meta Model API Responses API (muse-spark-1.3)
//   POST /places  -> Google Places API (New) Text Search
//   POST /routes  -> Google Routes API computeRoutes

const META_RESPONSES_URL = "https://api.meta.ai/v1/responses";
const PLACES_URL = "https://places.googleapis.com/v1/places:searchText";
const ROUTES_URL = "https://routes.googleapis.com/directions/v2:computeRoutes";

// Only models whose inputs Meta does not use for product improvement.
const ALLOWED_MODELS = new Set(["muse-spark-1.3"]);
const DEFAULT_MODEL = "muse-spark-1.3";
const MAX_BODY_BYTES = 8 * 1024 * 1024;

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function readJson(request) {
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return { error: json(413, { error: "body_too_large" }) };
  try {
    const value = JSON.parse(text);
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      return { error: json(400, { error: "body_must_be_object" }) };
    }
    return { value };
  } catch {
    return { error: json(400, { error: "invalid_json" }) };
  }
}

// Passes the upstream status and body through; the key never appears in either direction.
async function forward(url, headers, body) {
  let upstream;
  try {
    upstream = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(body),
    });
  } catch {
    return json(502, { error: "upstream_unreachable" });
  }
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
  });
}

async function handleAI(request, env) {
  if (!env.META_API_KEY) return json(503, { error: "meta_key_not_configured" });
  const { value, error } = await readJson(request);
  if (error) return error;
  const model = value.model ?? DEFAULT_MODEL;
  if (!ALLOWED_MODELS.has(model)) return json(400, { error: "model_not_allowed" });
  // Responses must not be stored by Meta: overwrite whatever the client sent.
  return forward(META_RESPONSES_URL, { authorization: `Bearer ${env.META_API_KEY}` }, { ...value, model, store: false });
}

async function handleGoogle(request, env, url) {
  if (!env.GOOGLE_MAPS_KEY) return json(503, { error: "google_key_not_configured" });
  const { value, error } = await readJson(request);
  if (error) return error;
  // The caller picks the fields it needs; the Google API requires a field mask.
  const fieldMask = request.headers.get("x-goog-fieldmask");
  if (!fieldMask) return json(400, { error: "x-goog-fieldmask_required" });
  return forward(url, { "x-goog-api-key": env.GOOGLE_MAPS_KEY, "x-goog-fieldmask": fieldMask }, value);
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/health") return json(200, { ok: true });
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

    // Fail closed: with no APP_TOKEN configured nothing is served.
    const token = request.headers.get("x-besir-token") ?? "";
    if (!env.APP_TOKEN || !timingSafeEqual(token, env.APP_TOKEN)) {
      return json(401, { error: "unauthorized" });
    }

    switch (pathname) {
      case "/ai":
        return handleAI(request, env);
      case "/places":
        return handleGoogle(request, env, PLACES_URL);
      case "/routes":
        return handleGoogle(request, env, ROUTES_URL);
      default:
        return json(404, { error: "not_found" });
    }
  },
};
