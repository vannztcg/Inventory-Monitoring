-- Inventory Monitoring : sécurité de la base de données
-- À coller dans Supabase → SQL Editor → New query → Run. Peut être relancé sans danger.
--
-- Ce que ce script fait :
--   1. Les données d'inventaire (cv_docs) ne sont lisibles et modifiables QUE par leur propriétaire,
--      et seulement si son compte est approuvé (même un compte créé directement par l'API ne peut rien stocker).
--   2. Une demande d'accès ne peut pas être falsifiée : courriel et identifiant viennent toujours du jeton de connexion.
--   3. Seul le propriétaire peut approuver ou retirer un accès (approved_users).
--   4. Double authentification : un compte qui l'a activée doit l'avoir validée (session « aal2 »)
--      pour toucher à ses données ou à la console.
--   5. Les visiteurs non connectés (rôle « anon ») n'ont plus aucun droit sur les tables et fonctions.
--   6. Limites de taille pour empêcher de remplir la base.

-- ───────────── Fonctions d'accès ─────────────

-- 2FA : si le compte a un facteur vérifié, la session doit être de niveau aal2
create or replace function public.mfa_ok() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce(auth.jwt()->>'aal', 'aal1') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f
                     where f.user_id = auth.uid() and f.status = 'verified')
$$;

-- Compte approuvé par le propriétaire (s'appuie sur my_access(), déjà en place)
create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and coalesce((public.my_access()->>'approved')::boolean, false)
     and public.mfa_ok()
$$;

-- Propriétaire : la 2FA devient obligatoire pour la console dès qu'elle est activée
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and coalesce((public.my_access()->>'admin')::boolean, false)
     and public.mfa_ok()
$$;

-- Chemin de recherche fixe pour my_access() (recommandation du Security Advisor)
do $$ begin
  if to_regprocedure('public.my_access()') is not null then
    execute 'alter function public.my_access() set search_path = public, auth, extensions';
  end if;
end $$;

-- ───────────── Inventaire (cv_docs) ─────────────
alter table public.cv_docs enable row level security;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'cv_docs' loop
    execute format('drop policy %I on public.cv_docs', p.policyname);
  end loop;
end $$;
create policy cv_docs_select on public.cv_docs for select to authenticated
  using (user_id::text = (select auth.uid())::text and (select public.is_approved()));
create policy cv_docs_insert on public.cv_docs for insert to authenticated
  with check (user_id::text = (select auth.uid())::text and (select public.is_approved()));
create policy cv_docs_update on public.cv_docs for update to authenticated
  using (user_id::text = (select auth.uid())::text and (select public.is_approved()))
  with check (user_id::text = (select auth.uid())::text and (select public.is_approved()));
create policy cv_docs_delete on public.cv_docs for delete to authenticated
  using (user_id::text = (select auth.uid())::text and (select public.is_approved()));

-- Taille maximale d'un document (5 Mo) et d'un identifiant (les lignes existantes ne sont pas touchées)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'cv_docs_size') then
    alter table public.cv_docs add constraint cv_docs_size check (octet_length(data::text) <= 5000000) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cv_docs_id_len') then
    alter table public.cv_docs add constraint cv_docs_id_len check (char_length(id::text) <= 120) not valid;
  end if;
end $$;
grant select, insert, update, delete on public.cv_docs to authenticated;

-- ───────────── Demandes d'accès (access_requests) ─────────────
alter table public.access_requests add column if not exists plan text;
alter table public.access_requests enable row level security;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'access_requests' loop
    execute format('drop policy %I on public.access_requests', p.policyname);
  end loop;
end $$;
create policy ar_select_own on public.access_requests for select to authenticated
  using (user_id::text = (select auth.uid())::text);
create policy ar_insert_own on public.access_requests for insert to authenticated
  with check (user_id::text = (select auth.uid())::text);
create policy ar_update_own on public.access_requests for update to authenticated
  using (user_id::text = (select auth.uid())::text)
  with check (user_id::text = (select auth.uid())::text);
create policy ar_owner on public.access_requests for all to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));

-- Le courriel et l'identifiant viennent du jeton, jamais de ce que l'app envoie
create or replace function public.access_requests_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_owner() then return new; end if;
  new.user_id := auth.uid();
  new.email   := lower(coalesce(auth.jwt()->>'email', ''));
  new.biz     := nullif(left(btrim(coalesce(new.biz, '')), 160), '');
  if new.plan is not null and new.plan not in ('free', 'pro', 'beta') then new.plan := null; end if;
  return new;
end $$;
drop trigger if exists access_requests_guard on public.access_requests;
create trigger access_requests_guard before insert or update on public.access_requests
  for each row execute function public.access_requests_guard();
grant select, insert, update, delete on public.access_requests to authenticated;

-- ───────────── Comptes approuvés (approved_users) ─────────────
alter table public.approved_users enable row level security;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'approved_users' loop
    execute format('drop policy %I on public.approved_users', p.policyname);
  end loop;
end $$;
create policy au_owner on public.approved_users for all to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));
create policy au_self on public.approved_users for select to authenticated
  using (lower(email) = lower(coalesce((select auth.jwt())->>'email', '')));
grant select, insert, update, delete on public.approved_users to authenticated;

-- ───────────── Membres, paiements, réglages : RLS toujours active ─────────────
alter table if exists public.members      enable row level security;
alter table if exists public.payments     enable row level security;
alter table if exists public.app_settings enable row level security;

-- ───────────── Compteur de Smart Scans (quota mensuel de la fonction scan-card) ─────────────
create table if not exists public.scan_usage (
  user_id uuid not null,
  month   text not null,
  n       int  not null default 0,
  primary key (user_id, month)
);
alter table public.scan_usage enable row level security;
drop policy if exists scan_usage_owner on public.scan_usage;
create policy scan_usage_owner on public.scan_usage for select to authenticated using ((select public.is_owner()));
grant select on public.scan_usage to authenticated;

create or replace function public.use_scan() returns int
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if not public.is_approved() then raise exception 'forbidden'; end if;
  insert into scan_usage (user_id, month, n) values (auth.uid(), to_char(now(), 'YYYY-MM'), 1)
  on conflict (user_id, month) do update set n = scan_usage.n + 1
  returning n into v;
  return v;
end $$;

-- ───────────── Droits : rien pour les visiteurs non connectés ─────────────
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated, service_role;
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public grant  execute on functions to authenticated, service_role;

-- ───────────── Vérification : liste des règles en place ─────────────
select tablename as "table", policyname as "règle", cmd as "action", roles
from pg_policies where schemaname = 'public' order by 1, 2;
