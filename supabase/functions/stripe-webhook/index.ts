// Inventory Monitoring – paiements Stripe (Supabase Edge Function « stripe-webhook »)
//
// Stripe envoie ici les événements de paiement ; la fonction vérifie la signature,
// puis passe l'événement à billing.stripe_apply() (supabase/plans.sql) qui met à jour
// le forfait du membre (members) et enregistre le paiement (payments).
//
// Réglages :
//   - Déployer avec « Verify JWT » DÉSACTIVÉ (Stripe n'envoie pas de jeton Supabase ;
//     la sécurité vient de la signature Stripe vérifiée ci-dessous).
//   - Secret à ajouter soi-même dans Supabase → Edge Functions → Secrets :
//       STRIPE_WEBHOOK_SECRET = whsec_… (Stripe → Developers → Webhooks → ton endpoint → Signing secret)
//   - SUPABASE_DB_URL est fourni automatiquement par Supabase.
//
// Événements à cocher dans Stripe : checkout.session.completed, invoice.paid,
// customer.subscription.updated, customer.subscription.deleted.
import postgres from "npm:postgres@3.4.5";

// Espaces ou guillemets collés par erreur autour du secret : on les retire
const SECRET = (Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "").trim().replace(/^["']+|["']+$/g, "").trim();
const TOLERANCE = 300; // secondes
const enc = new TextEncoder();
let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 20 }));

const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const same = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
};

// Renvoie "" si la signature est bonne, sinon la raison (jamais le secret)
export async function check(body: string, header: string, secret: string, now = Date.now() / 1000) {
  if (!secret.startsWith("whsec_")) return "secret_format";
  let t = "";
  const v1: string[] = [];
  for (const part of header.split(",")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    const k = part.slice(0, i).trim(), v = part.slice(i + 1).trim();
    if (k === "t") t = v;
    else if (k === "v1") v1.push(v);
  }
  if (!/^\d+$/.test(t) || !v1.length) return "no_signature_header";
  if (Math.abs(now - Number(t)) > TOLERANCE) return "timestamp_too_old";
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${body}`)));
  return v1.some((s) => same(s, sig)) ? "" : "mismatch";
}
export const verify = async (body: string, header: string, secret: string, now?: number) => (await check(body, header, secret, now)) === "";

const reply = (s: number, b: unknown) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method" });
  if (!SECRET) return reply(503, { error: "STRIPE_WEBHOOK_SECRET manquant" });
  if (Number(req.headers.get("Content-Length") ?? 0) > 512_000) return reply(413, { error: "too_large" });
  const body = await req.text();
  if (body.length > 512_000) return reply(413, { error: "too_large" });
  const why = await check(body, req.headers.get("Stripe-Signature") ?? "", SECRET);
  if (why) {
    console.warn("signature refusée :", why, "· longueur du secret :", SECRET.length);
    return reply(400, { error: "signature", why });
  }
  try {
    JSON.parse(body);
  } catch {
    return reply(400, { error: "json" });
  }
  try {
    const [row] = await db()`select billing.stripe_apply(${body}::jsonb) as r`;
    return reply(200, { ok: true, result: row?.r ?? null });
  } catch (e) {
    // Erreur passagère ou événement arrivé trop tôt : code 500 pour que Stripe réessaie plus tard
    console.error(e);
    return reply(500, { error: "retry" });
  }
});
