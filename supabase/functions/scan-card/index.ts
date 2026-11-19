// Inventory Monitoring – scan IA (Supabase Edge Function « scan-card »)
//
// GRATUIT : mets seulement le secret GEMINI_API_KEY (clé gratuite de Google AI Studio).
// Optionnel (payant) : ANTHROPIC_API_KEY -> Claude pour l'admin et les « IA illimitée ».
//
// Autres secrets optionnels :
//   GEMINI_MODEL (défaut gemini-flash-latest)
//   SCAN_MODEL (Claude pour IA illimitée, défaut claude-sonnet-5-5)
//   FREE_SCANS_PER_MONTH (quota par utilisateur standard, défaut 100)
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const pick = (txt: string) => { const m = txt.match(/\{[\s\S]*\}/); return m ? JSON.parse(m[0]) : {}; };

async function gemini(image: string, mime: string, prompt: string) {
  const key = Deno.env.get("GEMINI_API_KEY") ?? "";
  const model = Deno.env.get("GEMINI_MODEL") || "gemini-flash-latest";
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [{ parts: [{ inline_data: { mime_type: mime, data: image } }, { text: prompt }] }],
      generationConfig: { responseMimeType: "application/json", temperature: 0 },
    }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `gemini ${r.status}`);
  const txt = (j?.candidates?.[0]?.content?.parts ?? []).map((p: { text?: string }) => p.text ?? "").join("");
  return { ...pick(txt), model };
}

async function claude(image: string, mime: string, prompt: string) {
  const model = Deno.env.get("SCAN_MODEL") || "claude-sonnet-5-5";
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": Deno.env.get("ANTHROPIC_API_KEY") ?? "", "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model, max_tokens: 500,
      messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: mime, data: image } },
        { type: "text", text: prompt },
      ] }],
    }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `anthropic ${r.status}`);
  return { ...pick(j?.content?.[0]?.text ?? ""), model };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const h = { apikey: req.headers.get("apikey") ?? "", Authorization: req.headers.get("Authorization") ?? "", "Content-Type": "application/json" };
    const rpc = (fn: string) => fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${fn}`, { method: "POST", headers: h, body: "{}" })
      .then((r) => (r.ok ? r.json() : null)).catch(() => null);

    const acc = await rpc("my_access");
    if (!acc || !acc.approved) return json({ error: "not_allowed" }, 403);
    const premium = !!(acc.ai || acc.admin);
    const hasClaude = !!Deno.env.get("ANTHROPIC_API_KEY"), hasGemini = !!Deno.env.get("GEMINI_API_KEY");
    if (!hasClaude && !hasGemini) return json({ error: "no_provider" }, 503);

    const useClaude = hasClaude && (premium || !hasGemini);
    if (!premium) {
      const n = await rpc("use_scan");
      const lim = Number(Deno.env.get("FREE_SCANS_PER_MONTH") ?? 100);
      if (typeof n === "number" && n > lim) return json({ error: "quota" }, 429);
    }

    const { image, mediaType, prompt } = await req.json();
    if (!image) return json({ error: "no_image" }, 400);
    const p = String(prompt || "Lis cette carte Pokémon et réponds en JSON {name, number, set, finish, grader, grade}.").slice(0, 3000);
    const mime = mediaType || "image/jpeg";
    try {
      return json(useClaude ? await claude(image, mime, p) : await gemini(image, mime, p));
    } catch (e) {
      // Si un fournisseur échoue, essayer l'autre s'il existe
      if (useClaude && hasGemini) return json(await gemini(image, mime, p));
      if (!useClaude && hasClaude && premium) return json(await claude(image, mime, p));
      throw e;
    }
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 502);
  }
});
