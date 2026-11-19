// Inventory Monitoring – scan IA Claude (Supabase Edge Function « scan-card »)
// Secret requis : ANTHROPIC_API_KEY (Edge Functions → Secrets). Optionnel : SCAN_MODEL.
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
    // 1) Vérifier que l'utilisateur a droit au scan IA (admin ou liste ai_users)
    const auth = req.headers.get("Authorization") ?? "";
    const apikey = req.headers.get("apikey") ?? "";
    const acc = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/my_access`, {
      method: "POST",
      headers: { apikey, Authorization: auth, "Content-Type": "application/json" },
      body: "{}",
    }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
    if (!acc || !(acc.ai || acc.admin)) return json({ error: "not_allowed" }, 403);

    // 2) Lire la carte avec Claude
    const { image, mediaType, prompt } = await req.json();
    if (!image) return json({ error: "no_image" }, 400);
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": Deno.env.get("ANTHROPIC_API_KEY") ?? "",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: Deno.env.get("SCAN_MODEL") || "claude-sonnet-5-5",
        max_tokens: 400,
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mediaType || "image/jpeg", data: image } },
            { type: "text", text: String(prompt || "Lis cette carte Pokémon et réponds en JSON {name, number, set, finish, grader, grade}.").slice(0, 2000) },
          ],
        }],
      }),
    });
    const j = await r.json();
    if (!r.ok) return json({ error: j?.error?.message ?? `anthropic ${r.status}` }, 502);
    const txt: string = j?.content?.[0]?.text ?? "";
    const m = txt.match(/\{[\s\S]*\}/);
    return json(m ? JSON.parse(m[0]) : {});
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
