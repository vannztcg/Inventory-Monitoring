// Inventory Monitoring – scan IA (Supabase Edge Function « scan-card »)
// Secrets : ANTHROPIC_API_KEY (obligatoire)
// Optionnels : SCAN_MODEL (IA illimitée, défaut claude-sonnet-5-5),
//              SCAN_MODEL_FREE (IA standard, défaut claude-haiku-5-5),
//              FREE_SCANS_PER_MONTH (quota IA standard, défaut 100)
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const base = Deno.env.get("SUPABASE_URL");
    const h = {
      apikey: req.headers.get("apikey") ?? "",
      Authorization: req.headers.get("Authorization") ?? "",
      "Content-Type": "application/json",
    };
    const rpc = (fn: string) =>
      fetch(`${base}/rest/v1/rpc/${fn}`, { method: "POST", headers: h, body: "{}" })
        .then((r) => (r.ok ? r.json() : null)).catch(() => null);

    // 1) Accès : il faut être approuvé
    const acc = await rpc("my_access");
    if (!acc || !acc.approved) return json({ error: "not_allowed" }, 403);
    const premium = !!(acc.ai || acc.admin);

    // 2) Quota mensuel pour l'IA standard
    if (!premium) {
      const n = await rpc("use_scan");
      const lim = Number(Deno.env.get("FREE_SCANS_PER_MONTH") ?? 100);
      if (typeof n === "number" && n > lim) return json({ error: "quota" }, 429);
    }

    // 3) Lecture de la carte par Claude
    const { image, mediaType, prompt } = await req.json();
    if (!image) return json({ error: "no_image" }, 400);
    const model = premium
      ? (Deno.env.get("SCAN_MODEL") || "claude-sonnet-5-5")
      : (Deno.env.get("SCAN_MODEL_FREE") || "claude-haiku-5-5");
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": Deno.env.get("ANTHROPIC_API_KEY") ?? "",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        max_tokens: 500,
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mediaType || "image/jpeg", data: image } },
            { type: "text", text: String(prompt || "Lis cette carte Pokémon et réponds en JSON {name, number, set, finish, grader, grade}.").slice(0, 3000) },
          ],
        }],
      }),
    });
    const j = await r.json();
    if (!r.ok) return json({ error: j?.error?.message ?? `anthropic ${r.status}` }, 502);
    const txt: string = j?.content?.[0]?.text ?? "";
    const m = txt.match(/\{[\s\S]*\}/);
    return json({ ...(m ? JSON.parse(m[0]) : {}), model });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
