// POST /partners: the directory of the simulated partners the app can ask. It has no upstream, no storage and no log line:
// the answer is a constant, so nothing personal can be kept. A partner is added by adding an entry here and a route in index.js.
const MAX_BODY_CHARS = 4096;
const ALL_KEYS = ["op"];

// Each entry holds exactly id, name, title, summary and route, in this order. The route is `/` and 1 to 32 characters
// (a lowercase letter first, then lowercase letters, digits or `-`) and never `/partners`.
const PARTNERS = [
  {
    id: "booking",
    name: "Example Tables",
    title: "Reserve a table",
    summary: "Reserves a table at a restaurant.",
    route: "/booking",
  },
];

const directoryAnswer = () => ({
  partners: PARTNERS.map(({ id, name, title, summary, route }) => ({ id, name, title, summary, route })),
});

export async function handlePartners(request, { json }) {
  const text = await request.text();
  if (text.length > MAX_BODY_CHARS) return json(413, { error: "body_too_large" });
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return json(400, { error: "body_must_be_object" });
  }
  if (Object.keys(value).some((key) => !ALL_KEYS.includes(key))) return json(400, { error: "unknown_field" });
  if (!Object.prototype.hasOwnProperty.call(value, "op")) return json(400, { error: "missing_field" });
  if (value.op !== "list") return json(400, { error: "invalid_field" });
  return json(200, directoryAnswer());
}
