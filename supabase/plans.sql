-- Inventory Monitoring : inscription ouverte, essai Pro de 7 jours et paiement Stripe
-- À coller dans Supabase → SQL Editor → New query → Run, APRÈS security.sql. Peut être relancé sans danger.
--
-- Ce que ce script fait :
--   1. Inscription ouverte : tout compte connecté (courriel confirmé) peut utiliser l'app sur le forfait Free,
--      sans attendre d'approbation. Le propriétaire peut toujours suspendre un membre (members.status = 'suspended').
--   2. Essai Pro : un membre en statut « trial » a le Pro jusqu'à sa date de fin (members.next_due),
--      puis redevient automatiquement Free (rien à faire à la main).
--   3. Paiement Stripe : la fonction billing.stripe_apply() reçoit les événements Stripe (appelée seulement
--      par la fonction Edge « stripe-webhook », jamais par l'app) et met à jour le forfait et les paiements.
--   4. Limite de 20 000 documents par compte pour empêcher de remplir la base.

-- ───────────── Colonnes Stripe ─────────────
alter table public.members  add column if not exists stripe_customer text;
alter table public.members  add column if not exists stripe_sub      text;
alter table public.payments add column if not exists ref             text;
create unique index if not exists payments_ref_key on public.payments (ref);

-- ───────────── 1. Inscription ouverte ─────────────
-- Approuvé = connecté avec un vrai courriel (pas anonyme) et pas suspendu
create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and coalesce(auth.jwt()->>'email', '') <> ''
     and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
     and not exists (select 1 from public.members m
                     where lower(m.email) = lower(auth.jwt()->>'email') and m.status = 'suspended')
$$;

create or replace function public.my_access() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'approved',  public.is_approved(),
    'admin',     public.is_admin(),
    'suspended', exists (select 1 from public.members m
                         where lower(m.email) = lower(auth.jwt()->>'email') and m.status = 'suspended'))
$$;

-- ───────────── 2. Forfait de la personne connectée (essai compris) ─────────────
create or replace function public.my_plan() returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select lower(coalesce(auth.jwt()->>'email', '')) as em),
  m as (select x.* from public.members x, me where lower(x.email) = me.em limit 1),
  r as (
    select m.*,
           (m.status = 'trial' and m.next_due is not null and m.next_due < (now() at time zone 'America/Toronto')::date) as over,
           case when m.plan is null or m.plan = 'free' then 'free' when m.plan = 'beta' then 'beta' else 'pro' end as tier
    from (select 1) one left join m on true
  )
  select jsonb_build_object(
    'plan',       case when r.over then 'free' else coalesce(r.plan, 'free') end,
    'status',     case when r.over then 'active' else coalesce(r.status, 'active') end,
    'next_due',   case when r.status = 'trial' then null else r.next_due end,
    'trial_end',  case when r.status = 'trial' then r.next_due end,
    'trial_over', coalesce(r.over, false),
    'sections',   case when r.over then (select value from public.app_settings where key = 'free_sections')
                       else coalesce(r.sections, (select value from public.app_settings
                                                  where key = r.tier || '_sections')) end,
    'grace',      coalesce((select (value #>> '{}')::int from public.app_settings where key = 'grace_days'), 5),
    'stripe',     r.stripe_sub is not null,
    'known',      r.email is not null
                  or exists (select 1 from public.access_requests a where a.user_id::text = auth.uid()::text)
                  or exists (select 1 from public.approved_users u, me where lower(u.email) = me.em)
  )
  from r
$$;

-- ───────────── 4. Limite de documents par compte ─────────────
create or replace function public.cv_docs_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.cv_docs where user_id = new.user_id and id = new.id)
     and (select count(*) from public.cv_docs where user_id = new.user_id) >= 20000 then
    raise exception 'quota_docs' using hint = 'Limite de 20 000 documents par compte';
  end if;
  return new;
end $$;
drop trigger if exists cv_docs_cap on public.cv_docs;
create trigger cv_docs_cap before insert on public.cv_docs
  for each row execute function public.cv_docs_cap();
revoke execute on function public.cv_docs_cap() from public, anon, authenticated;

-- ───────────── 3. Stripe (schéma « billing », jamais exposé à l'API) ─────────────
create schema if not exists billing;
revoke all on schema billing from public, anon, authenticated;
create table if not exists billing.events (
  id     text primary key,
  type   text not null,
  result text,
  at     timestamptz not null default now()
);
alter table billing.events enable row level security;
revoke all on billing.events from public, anon, authenticated;

create or replace function billing.stripe_apply(ev jsonb) returns text
language plpgsql security definer set search_path = public, billing, auth, pg_temp as $$
declare
  t    text;
  o    jsonb;
  em   text;
  uid  uuid;
  cust text;
  sub  text;
  inv  text;
  due  date;
  amt  numeric;
  tax  numeric;
  pay  date;
  n    int;
  per  text;
  iv   text;
  ps   bigint;
  pe   bigint;
  res  text  := 'ignored';
  today date := (now() at time zone 'America/Toronto')::date;
begin
  -- Événement reçu comme texte JSON (double encodage) : on le relit
  if jsonb_typeof(ev) = 'string' then ev := (ev #>> '{}')::jsonb; end if;
  t := ev->>'type';
  o := ev->'data'->'object';
  if coalesce(ev->>'id', '') = '' or o is null then return 'bad_event'; end if;
  if exists (select 1 from billing.events where id = ev->>'id') then return 'dup'; end if;

  -- Paiement réussi depuis le lien de paiement : le membre passe au Pro
  if t = 'checkout.session.completed' then
    if o->>'mode' = 'subscription' and o->>'payment_status' in ('paid', 'no_payment_required') then
      begin uid := nullif(o->>'client_reference_id', '')::uuid; exception when others then uid := null; end;
      if uid is not null then select lower(u.email) into em from auth.users u where u.id = uid; end if;
      em   := coalesce(em, lower(nullif(o->'customer_details'->>'email', '')), lower(nullif(o->>'customer_email', '')));
      cust := o->>'customer';
      sub  := o->>'subscription';
      inv  := o->>'invoice';
      if em is null then raise exception 'stripe: courriel introuvable pour %', o->>'id'; end if;
      amt := round(coalesce((o->>'amount_subtotal')::numeric, 799) / 100, 2);
      tax := round(coalesce((o->'total_details'->>'amount_tax')::numeric, 0) / 100, 2);
      -- Forfait annuel si le montant dépasse 30 $ (79,90 $/an contre 7,99 $/mois) ; la facture corrige au besoin
      per := case when amt >= 30 then 'yearly' else 'monthly' end;
      insert into public.members as m (email, plan, price, currency, started, next_due, status, stripe_customer, stripe_sub, updated_at)
      values (em, per, amt, upper(coalesce(o->>'currency', 'cad')), today,
              (today + case when per = 'yearly' then interval '1 year' else interval '1 month' end)::date, 'active', cust, sub, now())
      on conflict (email) do update set
        plan = excluded.plan, price = excluded.price, currency = excluded.currency, status = 'active',
        started  = case when m.stripe_sub is not distinct from excluded.stripe_sub then coalesce(m.started, excluded.started) else excluded.started end,
        next_due = case when m.stripe_sub is not distinct from excluded.stripe_sub and m.next_due is not null then m.next_due else excluded.next_due end,
        stripe_customer = excluded.stripe_customer, stripe_sub = excluded.stripe_sub, updated_at = now();
      if coalesce((o->>'amount_total')::numeric, 0) > 0 then
        insert into public.payments (email, amount, paid_at, method, note, ref)
        values (em, amt, today, 'Stripe', 'Stripe · taxes ' || replace(to_char(tax, 'FM999990.00'), '.', ',') || ' $', coalesce(inv, o->>'id'))
        on conflict (ref) do nothing;
      end if;
      res := 'pro ' || em;
    end if;

  -- Facture payée (premier paiement ou renouvellement) : prochaine échéance + paiement enregistré
  elsif t in ('invoice.paid', 'invoice.payment_succeeded') then
    cust := o->>'customer';
    sub  := coalesce(o->>'subscription', o->'parent'->'subscription_details'->>'subscription');
    inv  := o->>'id';
    if sub is not null then
      select m.email into em from public.members m
       where (cust is not null and m.stripe_customer = cust) or m.stripe_sub = sub limit 1;
      if em is null then
        select lower(u.email) into em from auth.users u where lower(u.email) = lower(o->>'customer_email') limit 1;
        -- Premier paiement arrivé avant l'événement du lien de paiement : Stripe réessaiera plus tard
        if em is null and o->>'billing_reason' = 'subscription_create' then
          raise exception 'stripe: en attente de checkout.session.completed pour %', inv;
        end if;
      end if;
      if em is null then
        res := 'unmatched';
      else
        ps  := nullif(o->'lines'->'data'->0->'period'->>'start', '')::bigint;
        pe  := nullif(o->'lines'->'data'->0->'period'->>'end', '')::bigint;
        due := (to_timestamp(pe) at time zone 'America/Toronto')::date;
        per := case when pe - ps > 40 * 86400 then 'yearly' when pe - ps > 0 then 'monthly' end;
        amt := round(coalesce((o->>'total_excluding_tax')::numeric, (o->>'subtotal')::numeric, 0) / 100, 2);
        tax := round(greatest(coalesce((o->>'total')::numeric, 0) - coalesce((o->>'total_excluding_tax')::numeric, (o->>'total')::numeric, 0), 0) / 100, 2);
        pay := coalesce((to_timestamp(nullif(o->'status_transitions'->>'paid_at', '')::bigint) at time zone 'America/Toronto')::date, today);
        insert into public.members as m (email, plan, price, currency, started, next_due, status, stripe_customer, stripe_sub, updated_at)
        values (em, coalesce(per, 'monthly'), amt, upper(coalesce(o->>'currency', 'cad')), today, coalesce(due, (today + interval '1 month')::date),
                'active', cust, sub, now())
        on conflict (email) do update set
          plan = coalesce(per, case when m.plan in ('monthly', 'yearly') then m.plan else 'monthly' end), status = 'active',
          price = case when excluded.price > 0 then excluded.price else m.price end,
          next_due = coalesce(due, m.next_due),
          stripe_customer = coalesce(excluded.stripe_customer, m.stripe_customer),
          stripe_sub = excluded.stripe_sub, updated_at = now();
        if coalesce((o->>'amount_paid')::numeric, 0) > 0 then
          insert into public.payments (email, amount, paid_at, method, note, ref)
          values (em, amt, pay, 'Stripe', 'Stripe · taxes ' || replace(to_char(tax, 'FM999990.00'), '.', ',') || ' $', inv)
          on conflict (ref) do nothing;
        end if;
        res := 'paid ' || em || ' → ' || coalesce(due::text, '?');
      end if;
    end if;

  -- Abonnement annulé ou impayé : retour au Free (les données restent)
  elsif t in ('customer.subscription.deleted', 'customer.subscription.updated') then
    sub := o->>'id';
    if t = 'customer.subscription.deleted' or o->>'status' in ('canceled', 'unpaid', 'incomplete_expired') then
      update public.members set plan = 'free', price = 0, next_due = null, status = 'active', stripe_sub = null, updated_at = now()
       where stripe_sub = sub;
      get diagnostics n = row_count;
      res := 'free ' || n;
    elsif o->>'status' in ('active', 'trialing') then
      due := (to_timestamp(coalesce(o->>'current_period_end', o->'items'->'data'->0->>'current_period_end')::bigint)
              at time zone 'America/Toronto')::date;
      iv := coalesce(o->'items'->'data'->0->'price'->'recurring'->>'interval', o->'plan'->>'interval');
      update public.members
         set plan = case iv when 'year' then 'yearly' when 'month' then 'monthly'
                            else case when plan in ('monthly', 'yearly') then plan else 'monthly' end end,
             price = coalesce(round((o->'items'->'data'->0->'price'->>'unit_amount')::numeric / 100, 2), price),
             status = 'active', next_due = coalesce(due, next_due), updated_at = now()
       where stripe_sub = sub;
      get diagnostics n = row_count;
      res := 'sync ' || n;
    end if;
  end if;

  insert into billing.events (id, type, result) values (ev->>'id', coalesce(t, '?'), res);
  return res;
end $$;
revoke all on function billing.stripe_apply(jsonb) from public, anon, authenticated;

-- ───────────── Vérification ─────────────
select 'is_approved' as fonction, pg_get_function_result('public.is_approved'::regproc) as retour
union all select 'my_plan', pg_get_function_result('public.my_plan'::regproc)
union all select 'billing.stripe_apply', pg_get_function_result('billing.stripe_apply'::regproc);
