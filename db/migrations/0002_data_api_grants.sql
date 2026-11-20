-- ============================================================================
-- 0002 — Privilèges Data API minimaux + convergent l'instance déjà migrée
--
-- S'applique aussi bien aux installations NEUVES (après 0001_init.sql) qu'à
-- l'instance existante : il révoque d'abord tout grant trop large
-- (dont le bloc « grant all » posé manuellement en urgence pour le 42501),
-- puis accorde objet par objet. La RLS reste la frontière métier.
--
-- Principe (audit v6) :
--   anon          : lecture seule du catalogue public
--   authenticated : catalogue + opérations sur SES données (via les policies)
--   service_role  : serveur uniquement (job de synchronisation), bypass RLS
-- La matview trade_matches ne supporte PAS la RLS (limitation PostgreSQL) :
-- elle n'est jamais lisible directement ; accès unique via la fonction
-- SECURITY DEFINER get_trade_matches() qui ne retourne que me = auth.uid().
-- ============================================================================

-- 1) Révocation des grants trop larges éventuels (convergence instance existante)
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
revoke all on all functions in schema public from public;

-- 2) anon : catalogue public, lecture seule
grant usage on schema public to anon;
grant select on games, sets, cards, card_prices to anon;

-- 3) authenticated : catalogue + données utilisateur (RLS = frontière)
grant usage on schema public to authenticated;
grant select on games, sets, cards, card_prices to authenticated;
grant select, insert, update, delete on profiles, collection_items, themes, theme_cards
  to authenticated;
grant select, insert, update on trades to authenticated;
grant select, insert on trade_cards, trade_feedback to authenticated;

-- 4) trade_matches : jamais d'accès direct, y compris pour les connectés
--    (le grant service_role est posé par le bloc conditionnel en fin de script)
revoke all on trade_matches from public, anon, authenticated;

-- 5) Accès aux matches : fonction cloisonnée (ne retourne que me = auth.uid(),
--    et masque les profils privés des autres collectionneurs).
create or replace function get_trade_matches()
returns table (me uuid, other uuid, score bigint)
language sql
stable
security definer
set search_path = public
as $$
  select tm.me, tm.other, tm.score
  from trade_matches tm
  join profiles p on p.id = tm.other
  where tm.me = auth.uid()
    and p.visibility in ('public', 'matches_only');
$$;
revoke all on function get_trade_matches() from public, anon, authenticated;
grant execute on function get_trade_matches() to authenticated;

-- trades_guard_transition : exécutée par le trigger, jamais appelée directement
revoke all on function trades_guard_transition() from public, anon, authenticated;

-- f_unaccent : utilisée dans les requêtes de recherche de l'application
grant execute on function f_unaccent(text) to anon, authenticated;

-- 6) service_role (serveur uniquement) : passage complet pour le job de sync.
--     Conditionnel à l'existence du rôle (n'existe que chez Supabase).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema public to service_role;
    grant all on all tables in schema public to service_role;
    grant all on all functions in schema public to service_role;
    grant select on trade_matches to service_role;
  end if;
end $$;

-- 7) Futurs objets : pas d'EXECUTE public par défaut
alter default privileges in schema public revoke execute on functions from public;
