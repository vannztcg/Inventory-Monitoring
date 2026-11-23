// create-checkout : crée la session Stripe de la page de paiement intégrée à l'app (Checkout Sessions, ui_mode « elements »).
// Secret à coller dans Supabase › Edge Functions › Secrets : STRIPE_SECRET_KEY (clé restreinte rk_live_…).
// Fournis par Supabase : SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_DB_URL.
// « Verify JWT » désactivé au déploiement : la fonction vérifie elle-même le jeton auprès de Supabase Auth.
import postgres from 'npm:postgres@3.4.5';

const clean = (v?: string | null) => (v || '').trim().replace(/^['"]|['"]$/g, '');
const KEY = clean(Deno.env.get('STRIPE_SECRET_KEY'));
const SB = clean(Deno.env.get('SUPABASE_URL'));
const ANON = clean(Deno.env.get('SUPABASE_ANON_KEY'));
const SITE = clean(Deno.env.get('SITE_URL')) || 'https://inventorymonitoring.ca';
const PRICE: Record<string, string> = {
  m: clean(Deno.env.get('STRIPE_PRICE_MONTHLY')) || 'price_1UerLZAydlqp8j6mA1xm3Pak',
  y: clean(Deno.env.get('STRIPE_PRICE_YEARLY')) || 'price_1UerLaAydlqp8j6mOHMkoIQ1',
};
const STRIPE_VERSION = '2026-10-28.endive';
const TAG = 'inventory-monitoring-app-qzrwkmtb';
const MAX_PER_HOUR = 12;
const ORIGINS = new Set(['https://inventorymonitoring.ca', 'https://www.inventorymonitoring.ca']);

let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false }));

const cors = (req: Request) => {
  const o = req.headers.get('origin') || '';
  return {
    'Access-Control-Allow-Origin': ORIGINS.has(o) ? o : 'https://inventorymonitoring.ca',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
};
const out = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), 'Content-Type': 'application/json' } });

async function createSession(params: URLSearchParams, idem: string) {
  const r = await fetch('https://api.stripe.com/v1/checkout/sessions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${KEY}`,
      'Stripe-Version': STRIPE_VERSION,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Idempotency-Key': idem,
    },
    body: params,
  });
  return { ok: r.ok, status: r.status, body: await r.json().catch(() => ({})) };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(req) });
  if (req.method !== 'POST') return out(req, 405, { error: 'method' });
  if (!/^(rk|sk)_(live|test)_\w+$/.test(KEY)) return out(req, 503, { error: 'not_configured' });

  // 1) Qui paie : jeton de session vérifié par Supabase Auth (jamais un courriel envoyé par le navigateur)
  const auth = req.headers.get('authorization') || '';
  if (!/^Bearer \S+$/.test(auth)) return out(req, 401, { error: 'auth' });
  const ur = await fetch(`${SB}/auth/v1/user`, { headers: { Authorization: auth, apikey: req.headers.get('apikey') || ANON } });
  if (!ur.ok) return out(req, 401, { error: 'auth' });
  const u = await ur.json().catch(() => ({}));
  const uid = String(u.id || ''), email = String(u.email || '').toLowerCase();
  if (!/^[0-9a-f-]{36}$/.test(uid) || !email || u.is_anonymous) return out(req, 401, { error: 'auth' });

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* corps vide */ }
  const per = body.period === 'y' ? 'y' : body.period === 'm' ? 'm' : '';
  if (!per) return out(req, 400, { error: 'period' });

  try {
    const q = db();
    // 2) Pas de deuxième abonnement si un abonnement Stripe est déjà actif
    const [m] = await q`select plan, status, next_due, stripe_customer, stripe_sub from public.members where email = ${email}`;
    if (m && m.stripe_sub && m.status === 'active' && (m.plan === 'monthly' || m.plan === 'yearly') &&
        (!m.next_due || new Date(m.next_due).getTime() >= Date.now() - 86_400_000)) {
      return out(req, 409, { error: 'already' });
    }
    // 3) Limite : 12 sessions par compte et par heure
    const [{ n }] = await q`select count(*)::int as n from billing.checkout_log where uid = ${uid}::uuid and created_at > now() - interval '1 hour'`;
    if (n >= MAX_PER_HOUR) return out(req, 429, { error: 'rate' });
    await q`insert into billing.checkout_log (uid, period) values (${uid}::uuid, ${per})`;
    await q`delete from billing.checkout_log where created_at < now() - interval '2 days'`;

    // 4) Session Stripe : abonnement, méthodes de paiement dynamiques (aucun payment_method_types), pas de taxes
    const params = new URLSearchParams({
      mode: 'subscription',
      ui_mode: 'elements',
      'line_items[0][price]': PRICE[per],
      'line_items[0][quantity]': '1',
      return_url: `${SITE}/?paid=1&session_id={CHECKOUT_SESSION_ID}`,
      client_reference_id: uid,
      integration_identifier: TAG,
    });
    const minute = Math.floor(Date.now() / 60_000);
    let s;
    if (m?.stripe_customer) {
      params.set('customer', m.stripe_customer);
      s = await createSession(params, `im-${uid}-${per}-${minute}-c`);
      // Client supprimé dans Stripe : on repart du courriel
      if (!s.ok && s.body?.error?.code === 'resource_missing') {
        params.delete('customer');
        params.set('customer_email', email);
        s = await createSession(params, `im-${uid}-${per}-${minute}-e`);
      }
    } else {
      params.set('customer_email', email);
      s = await createSession(params, `im-${uid}-${per}-${minute}-e`);
    }
    if (!s.ok || !s.body?.client_secret) {
      console.error('stripe', s.status, s.body?.error?.code, s.body?.error?.message);
      return out(req, 502, { error: 'stripe', message: s.body?.error?.message || '' });
    }
    return out(req, 200, { client_secret: s.body.client_secret, amount: s.body.amount_total, currency: s.body.currency, period: per });
  } catch (e) {
    console.error('create-checkout', (e as Error)?.message);
    return out(req, 500, { error: 'server' });
  }
});
