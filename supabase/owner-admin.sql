-- Inventory Monitoring : espace propriétaire
-- Membres et abonnements, paiements, accès par section, statistiques d'hébergement.
-- À coller dans Supabase → SQL Editor → New query → Run. Peut être relancé sans danger.

-- Qui est le propriétaire ? On réutilise my_access() déjà en place (admin = true).
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((public.my_access()->>'admin')::boolean, false)
$$;

-- Membres et abonnements
create table if not exists public.members (
  email      text primary key,
  plan       text not null default 'free',      -- free | monthly | yearly | lifetime
  price      numeric(10,2) default 0,
  currency   text default 'CAD',
  started    date default current_date,
  next_due   date,
  status     text not null default 'active',    -- active | trial | suspended
  sections   jsonb,                             -- null = réglage par défaut du forfait
  note       text,
  updated_at timestamptz default now()
);
alter table public.members enable row level security;
drop policy if exists members_owner on public.members;
create policy members_owner on public.members for all using (public.is_owner()) with check (public.is_owner());
drop policy if exists members_self on public.members;
create policy members_self on public.members for select using (lower(email) = lower(auth.jwt()->>'email'));

-- Paiements reçus
create table if not exists public.payments (
  id         bigserial primary key,
  email      text not null,
  amount     numeric(10,2) not null,
  paid_at    date not null default current_date,
  method     text,
  note       text,
  created_at timestamptz default now()
);
alter table public.payments enable row level security;
drop policy if exists payments_owner on public.payments;
create policy payments_owner on public.payments for all using (public.is_owner()) with check (public.is_owner());

-- Réglages de l'app (sections du forfait gratuit, jours de grâce…)
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb,
  updated_at timestamptz default now()
);
alter table public.app_settings enable row level security;
drop policy if exists settings_read on public.app_settings;
create policy settings_read on public.app_settings for select using (auth.role() = 'authenticated');
drop policy if exists settings_owner on public.app_settings;
create policy settings_owner on public.app_settings for all using (public.is_owner()) with check (public.is_owner());

-- Forfait de la personne connectée (lu par l'app à chaque ouverture)
create or replace function public.my_plan() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'plan',     coalesce(m.plan, 'free'),
    'status',   coalesce(m.status, 'active'),
    'next_due', m.next_due,
    'sections', coalesce(m.sections,
                  case when coalesce(m.plan, 'free') = 'free'
                       then (select value from app_settings where key = 'free_sections') end),
    'grace',    coalesce((select (value #>> '{}')::int from app_settings where key = 'grace_days'), 5)
  )
  from (select 1) one
  left join members m on lower(m.email) = lower(auth.jwt()->>'email')
$$;

-- Statistiques pour le propriétaire seulement
create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb; sc jsonb := '[]'::jsonb;
begin
  if not public.is_owner() then raise exception 'forbidden'; end if;
  begin
    select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into sc from scan_usage s;
  exception when others then sc := '[]'::jsonb;
  end;
  select jsonb_build_object(
    'db_bytes',   pg_database_size(current_database()),
    'docs_bytes', (select coalesce(sum(pg_column_size(d.*)), 0) from cv_docs d),
    'users',      (select count(*) from auth.users),
    'active30',   (select count(*) from auth.users where last_sign_in_at > now() - interval '30 days'),
    'per_user',   (select coalesce(jsonb_agg(to_jsonb(x) order by x.bytes desc), '[]'::jsonb) from (
                     select u.id::text as id, u.email, u.created_at, u.last_sign_in_at as login,
                            count(d.user_id) as docs, coalesce(sum(pg_column_size(d.*)), 0) as bytes
                     from auth.users u left join cv_docs d on d.user_id::text = u.id::text
                     group by u.id) x),
    'scans',      sc
  ) into r;
  return r;
end $$;

-- Permissions (les nouveaux projets Supabase ne les donnent plus automatiquement).
-- La sécurité réelle reste assurée par les règles RLS ci-dessus : seul le propriétaire écrit.
grant select, insert, update, delete on public.members, public.payments, public.app_settings to authenticated;
grant usage, select on sequence public.payments_id_seq to authenticated;
grant execute on function public.is_owner()    to authenticated;
grant execute on function public.my_plan()     to authenticated;
grant execute on function public.admin_stats() to authenticated;

-- Les membres déjà approuvés reçoivent une fiche (forfait gratuit par défaut)
insert into public.members (email)
select lower(email) from public.approved_users
on conflict (email) do nothing;
