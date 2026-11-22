// Inventory Monitoring – scan IA (Supabase Edge Function « scan-card »)
//
// GRATUIT : mets seulement le secret GEMINI_API_KEY (clé gratuite de Google AI Studio).
// Optionnel (payant) : ANTHROPIC_API_KEY -> Claude pour l'admin et les « IA illimitée ».
//
// Autres secrets optionnels :
//   GEMINI_MODEL (défaut gemini-flash-latest)
//   SCAN_MODEL (Claude pour IA illimitée, défaut claude-sonnet-5-5)
//   FREE_SCANS_PER_MONTH (quota par utilisateur standard, défaut 100)
//   ALLOWED_ORIGINS (défaut https://inventorymonitoring.ca ; plusieurs séparés par des virgules)
//
// Sécurité :
//   - seul le site autorisé peut appeler la fonction depuis un navigateur (CORS) ;
//   - compte connecté ET approuvé obligatoire (my_access), quota mensuel compté en base (use_scan) ;
//   - consigne fixe côté serveur : la fonction ne sert qu'à lire des cartes, pas de texte libre ;
//   - image limitée en taille et en type ; erreurs des fournisseurs jamais renvoyées telles quelles.
const ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "https://inventorymonitoring.ca").split(",").map((s) => s.trim()).filter(Boolean);
const MAX_B64 = 6_000_000; // ~4,5 Mo d'image
const MIMES = new Set(["image/jpeg", "image/png", "image/webp"]);
const PROMPT = "Tu lis une carte Pokémon TCG. Extrais SEULEMENT ce qui est imprimé, ne devine pas (null si illisible). Si la carte est dans un boîtier gradé (slab), lis l’étiquette : société (PSA, BGS/Beckett, CGC, SGC ou TAG), note de 1 à 10 (demi-points possibles), numéro de certification et numéro de carte imprimé sur l’étiquette; compare-les à la carte visible. Sinon grader, grade, cert et labelNumber sont null. Réponds par un JSON seul, sans backticks: {\"name\":str|null,\"number\":\"025/165\"|null,\"set\":code imprimé de l’extension|null,\"setName\":\"nom complet de l’extension si tu le reconnais avec certitude\"|null,\"finish\":\"Normal\"|\"Holo\"|\"Reverse\"|null,\"grader\":\"PSA\"|\"BGS\"|\"CGC\"|\"SGC\"|\"TAG\"|null,\"labelNumber\":\"numéro de carte sur l’étiquette, ex. 025\"|null,\"grade\":\"note de l’étiquette, ex. 10 ou 9.5\"|null,\"cert\":\"numéro de certification sur l’étiquette\"|null,\"lang\":\"EN\"|\"FR\"|\"JP\"|\"autre\"|null,\"edition\":\"1st\"|null,\"rarity\":str|null}";

const corsFor = (req: Request) => {
  const o = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
};
const pick = (txt: string) => { const m = txt.match(/\{[\s\S]*\}/); if (!m) return {}; try { return JSON.parse(m[0]); } catch { return {}; } };

async function gemini(image: string, mime: string) {
  const key = Deno.env.get("GEMINI_API_KEY") ?? "";
  const model = Deno.env.get("GEMINI_MODEL") || "gemini-flash-latest";
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
    method: "POST",
    headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [{ parts: [{ inline_data: { mime_type: mime, data: image } }, { text: PROMPT }] }],
      generationConfig: { responseMimeType: "application/json", temperature: 0, maxOutputTokens: 600 },
    }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`gemini ${r.status}: ${j?.error?.message ?? ""}`);
  const txt = (j?.candidates?.[0]?.content?.parts ?? []).map((p: { text?: string }) => p.text ?? "").join("");
  return { ...pick(txt), model };
}

async function claude(image: string, mime: string) {
  const model = Deno.env.get("SCAN_MODEL") || "claude-sonnet-5-5";
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": Deno.env.get("ANTHROPIC_API_KEY") ?? "", "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model, max_tokens: 500,
      messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: mime, data: image } },
        { type: "text", text: PROMPT },
      ] }],
    }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`anthropic ${r.status}: ${j?.error?.message ?? ""}`);
  return { ...pick(j?.content?.[0]?.text ?? ""), model };
}

Deno.serve(async (req) => {
  const cors = corsFor(req);
  const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const origin = req.headers.get("Origin");
  if (origin && !ORIGINS.includes(origin)) return json({ error: "origin" }, 403);
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+\.\S+\.\S+$/.test(auth)) return json({ error: "auth" }, 401);
  if (Number(req.headers.get("Content-Length") ?? 0) > MAX_B64 + 10_000) return json({ error: "too_large" }, 413);
  try {
    const h = { apikey: req.headers.get("apikey") ?? "", Authorization: auth, "Content-Type": "application/json" };
    const rpc = (fn: string) => fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${fn}`, { method: "POST", headers: h, body: "{}" })
      .then((r) => (r.ok ? r.json() : null)).catch(() => null);

    const acc = await rpc("my_access");
    if (!acc || !acc.approved) return json({ error: "not_allowed" }, 403);
    const premium = !!(acc.ai || acc.admin);
    const hasClaude = !!Deno.env.get("ANTHROPIC_API_KEY"), hasGemini = !!Deno.env.get("GEMINI_API_KEY");
    if (!hasClaude && !hasGemini) return json({ error: "no_provider" }, 503);

    const body = await req.json().catch(() => null);
    const image = typeof body?.image === "string" ? body.image : "";
    const mime = MIMES.has(body?.mediaType) ? body.mediaType : "image/jpeg";
    if (!image) return json({ error: "no_image" }, 400);
    if (image.length > MAX_B64 || !/^[A-Za-z0-9+/=]+$/.test(image)) return json({ error: "bad_image" }, 400);

    if (!premium) {
      const n = await rpc("use_scan");
      if (typeof n !== "number") return json({ error: "quota_unavailable" }, 503);
      const lim = Number(Deno.env.get("FREE_SCANS_PER_MONTH") ?? 100);
      if (n > lim) return json({ error: "quota" }, 429);
    }

    const useClaude = hasClaude && (premium || !hasGemini);
    try {
      return json(useClaude ? await claude(image, mime) : await gemini(image, mime));
    } catch (e) {
      console.error(e);
      // Si un fournisseur échoue, essayer l'autre s'il existe
      if (useClaude && hasGemini) return json(await gemini(image, mime));
      if (!useClaude && hasClaude && premium) return json(await claude(image, mime));
      throw e;
    }
  } catch (e) {
    console.error(e);
    return json({ error: "scan_failed" }, 502);
  }
});
