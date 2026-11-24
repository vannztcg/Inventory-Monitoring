-- Inventory Monitoring : conformité (Loi 25 sur la protection des renseignements personnels, Loi sur la protection du consommateur)
-- À coller dans Supabase → SQL Editor → New query → Run. Peut être relancé sans danger.
--
-- 1) Annulation programmée : members.cancel_at, renvoyée par my_plan() et tenue à jour par le webhook Stripe
--    (les deux fonctions existantes sont modifiées sur place ; rien ne change si c'est déjà fait).
-- 2) legal_info() : coordonnées publiques de l'entreprise pour /conditions/ et /confidentialite/.
-- 3) delete_my_account() : suppression du compte par la personne elle-même (Réglages › Confidentialité).
--    Efface l'inventaire, les compteurs, les demandes d'accès, le forfait et le compte de connexion.
--    Les paiements reçus (public.payments) sont gardés : registres comptables à conserver 6 ans.
--    Refusé tant qu'un abonnement Stripe actif n'est pas annulé, et toujours refusé pour le propriétaire.

alter table public.members add column if not exists cancel_at date;
do $do$
declare d text; n text;
begin
  d := pg_get_functiondef('public.my_plan()'::regprocedure);
  if position('cancel_at' in d) = 0 then
    n := replace(d, $q$'stripe',     r.stripe_sub is not null,$q$, $q$'stripe',     r.stripe_sub is not null,
    'cancel_at',  r.cancel_at,$q$);
    if n = d then raise exception 'my_plan : motif introuvable'; end if;
    execute n;
  end if;
  d := pg_get_functiondef('billing.stripe_apply(jsonb)'::regprocedure);
  if position('cancel_at' in d) = 0 then
    n := replace(d, $q$stripe_sub = null, updated_at = now()$q$, $q$stripe_sub = null, cancel_at = null, updated_at = now()$q$);
    if n = d then raise exception 'stripe_apply : motif 1 introuvable'; end if;
    d := n;
    n := replace(d, $q$status = 'active', next_due = coalesce(due, next_due), updated_at = now()$q$, $q$status = 'active', next_due = coalesce(due, next_due),
             cancel_at = case when coalesce((o->>'cancel_at_period_end')::boolean, false) or o->>'cancel_at' is not null
                              then coalesce((to_timestamp((o->>'cancel_at')::bigint) at time zone 'America/Toronto')::date, due) end,
             updated_at = now()$q$);
    if n = d then raise exception 'stripe_apply : motif 2 introuvable'; end if;
    execute n;
  end if;
end $do$;
create or replace function public.legal_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'legal',   (select value - 'name' - 'addr' - 'prp' from public.app_settings where key = 'legal'),
    'contact', (select value from public.app_settings where key = 'contact'))
$$;
revoke all on function public.legal_info() from public;
grant execute on function public.legal_info() to anon, authenticated;

create or replace function public.delete_my_account(confirm text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  em text;
  m  public.members%rowtype;
begin
  if me is null then raise exception 'auth' using errcode = '28000'; end if;
  if confirm is distinct from 'SUPPRIMER' then raise exception 'confirm' using errcode = '22023'; end if;
  if public.is_owner() then raise exception 'owner' using errcode = '42501'; end if;
  select lower(email) into em from auth.users where id = me;
  select * into m from public.members where lower(email) = em;
  if found and m.stripe_sub is not null and m.cancel_at is null
     and m.plan in ('monthly', 'yearly') and m.status = 'active' then
    raise exception 'active_sub' using errcode = 'P0001';
  end if;
  delete from public.cv_docs         where user_id = me;
  delete from public.scan_usage      where user_id = me;
  delete from public.access_requests where user_id = me or lower(email) = em;
  delete from public.approved_users  where lower(email) = em;
  delete from public.members         where lower(email) = em;
  delete from billing.checkout_log   where uid = me;
  delete from auth.users             where id = me;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;

select 'legal_info' as fonction, pg_get_function_result('public.legal_info'::regproc) as retour
union all select 'delete_my_account', pg_get_function_result('public.delete_my_account(text)'::regprocedure);
