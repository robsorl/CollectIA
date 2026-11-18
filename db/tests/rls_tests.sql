-- ============================================================
-- Tests RLS croisés à deux utilisateurs — CollectIA
-- Prérequis : migration 0001_init.sql appliquée, projet Supabase créé.
--
-- 1) Dashboard : Authentication → Users → ajouter deux utilisateurs de test
--    (test-a@test.local et test-b@test.local), confirmer leurs emails.
-- 2) Exécuter ce script dans le SQL Editor : chaque scénario affiche un OK ;
--    la moindre assertion échouée aborte le script en nommant le scénario fautif.
--
-- Préparation (profils, données) exécutée SANS session utilisateur (postgres
-- contourne la RLS en tant que propriétaire) ; les scénarios s'exécutent
-- ensuite SOUS LE RÔLE authenticated avec les claims JWT réels.
-- ============================================================
do $$
declare
  v_a uuid;
  v_b uuid;
  v_updated int;
  v_guard_triggered boolean := false;
begin
  -- Utilisateurs de test
  select u.id into v_a from auth.users u where u.email = 'test-a@test.local';
  select u.id into v_b from auth.users u where u.email = 'test-b@test.local';
  if v_a is null or v_b is null then
    raise exception 'Créez test-a@test.local et test-b@test.local dans Authentication > Users';
  end if;

  -- Préparation en tant que postgres (owner : bypass RLS) : profils + état imposé
  update profiles set visibility = 'private', username = 'test-b' where id = v_b;
  update profiles set visibility = 'public', username = 'test-a' where id = v_a;
  insert into profiles (id, username, visibility) values (v_a, 'test-a', 'public') on conflict (id) do nothing;
  insert into profiles (id, username, visibility) values (v_b, 'test-b', 'private') on conflict (id) do nothing;
  -- forcer l'état attendu du profil de B, quel que soit son historique (cf. revue S6)
  update profiles set visibility = 'private' where id = v_b;
  delete from collection_items where user_id in (v_a, v_b);
  delete from trades where from_user = v_b and to_user = v_a;

  if not exists (select 1 from cards limit 1) then
    raise exception 'Table cards vide : lancez d''abord la synchronisation du catalogue (S1)';
  end if;

  -- Contexte utilisateur : A (claims JWT réels + rôle authenticated)
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';

  -- S1 : A écrit dans SA collection → doit réussir
  insert into collection_items (user_id, card_id, language, quantity_owned, quantity_wanted)
  values (v_a, (select id from cards limit 1), 'fr', 2, 1);
  raise notice 'S1 OK : A a écrit sa collection';

  -- S2 : A lit SA collection → exactement 1 ligne
  assert (
    select count(*) from collection_items where user_id = v_a
  ) = 1, 'S2 échoué : A ne voit pas exactement sa ligne';
  raise notice 'S2 OK : A lit sa collection (1 ligne)';

  -- S3 : A tente de lire la collection de B → 0 ligne
  assert (
    select count(*) from collection_items where user_id = v_b
  ) = 0, 'S3 échoué : A voit la collection de B !';
  raise notice 'S3 OK : la collection de B est invisible pour A';

  -- S4 : A tente de modifier la collection de B → 0 ligne modifiée
  update collection_items set quantity_owned = 999 where user_id = v_b;
  get diagnostics v_updated = row_count;
  assert v_updated = 0, format('S4 échoué : %s lignes modifiées chez B !', v_updated);
  raise notice 'S4 OK : modification croisée impossible';

  -- S5 : A tente d'insérer au nom de B (usurpation) → 42501 attendu ;
  --      toute autre erreur remonte (ne pas masquer un échec inattendu)
  begin
    insert into collection_items (user_id, card_id, language, quantity_owned, quantity_wanted)
    values (v_b, (select id from cards limit 1), 'fr', 1, 0);
    raise exception 'S5 échoué : insertion usurpée acceptée !';
  exception
    when insufficient_privilege then
      raise notice 'S5 OK : usurpation bloquée par RLS (WITH CHECK, 42501)';
  end;
  assert (select count(*) from collection_items where user_id = v_b) = 0,
    'S5 échoué : une ligne a malgré tout été insérée au nom de B !';
  raise notice 'S5 bis OK : aucune ligne créée au nom de B';

  -- S6 : Le profil PRIVÉ de B est invisible pour A (état forcé en préparation)
  assert not exists (select 1 from profiles where id = v_b),
    'S6 échoué : A voit le profil privé de B !';
  raise notice 'S6 OK : profil privé de B invisible';

  -- S7 : Catalogue public lisible et cohérent sous le rôle authenticated
  assert exists (select 1 from cards limit 1), 'S7 échoué : cards illisible';
  assert exists (select 1 from sets limit 1), 'S7 échoué : sets illisible';
  assert exists (select 1 from games limit 1), 'S7 échoué : games illisible';
  raise notice 'S7 OK : catalogue lisible';

  -- S8 : échange "declined" visible mais non modifiable par A
  perform set_config('request.jwt.claims', '', false);
  execute 'set local role postgres';
  insert into trades (from_user, to_user, status) values (v_b, v_a, 'declined');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';

  assert exists (
    select 1 from trades
    where from_user = v_b and to_user = v_a and status = 'declined'
  ), 'S8 échoué : A ne voit pas l''échange concerné (contexte JWT faux?)';
  raise notice 'S8 OK : l''échange décliné est visible de A (destinataire)';

  update trades set status = 'accepted'
  where from_user = v_b and to_user = v_a and status = 'declined';
  get diagnostics v_updated = row_count;
  assert v_updated = 0, 'S8 échoué : un échange décliné a pu être accepté !';
  raise notice 'S8 bis OK : échange décliné non modifiable';

  -- S9 (nouveau) : le trigger interdit de modifier autre chose que le statut —
  --      A (destinataire d'un échange proposed) tente de s'attribuer un autre message
  execute 'set local role postgres';
  -- vider le contexte JWT AVANT la préparation : le trigger ne bypass qu'en
  -- l'absence de JWT, sinon la réinitialisation declined -> proposed serait
  -- rejetée comme transition interdite (le statut declined est terminal).
  perform set_config('request.jwt.claims', '', false);
  update trades set status = 'proposed' where from_user = v_b and to_user = v_a;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';

  -- Pré-contrôle : l'échange proposed doit être visible de A (sinon contexte JWT faux
  -- et le résultat du scénario serait sans valeur).
  assert exists (
    select 1 from trades
    where from_user = v_b and to_user = v_a and status = 'proposed'
  ), 'S9 échoué : A ne voit pas l''échange proposed (contexte JWT faux ?)';
  raise notice 'S9 OK : échange proposed visible de A (destinataire)';

  -- Tentative : modifier message EN MÊME TEMPS que le statut. Le garde-fou attendu
  -- est l'exception du trigger (raise_exception) — la policy WITH CHECK renverrait
  -- elle insufficient_privilege. L'assertion finale est HORS du bloc EXCEPTION :
  -- un update réussi laisserait v_guard_triggered = false et ferait échouer le test.
  begin
    update trades
    set message = 'piraté', status = 'accepted'
    where from_user = v_b and to_user = v_a and status = 'proposed';
    get diagnostics v_updated = row_count;
    if v_updated = 0 then
      v_guard_triggered := true;
    end if;
  exception
    when raise_exception or insufficient_privilege then
      v_guard_triggered := true;
      raise notice 'S9 : garde-fou déclenché (%)', sqlerrm;
  end;

  -- Assertions hors du bloc EXCEPTION : aucun gestionnaire ne peut les masquer.
  assert v_guard_triggered, 'S9 échoué : garde-fou non déclenché !';
  assert exists (
    select 1 from trades
    where from_user = v_b and to_user = v_a and status = 'proposed'
      and coalesce(message, '') <> 'piraté'
  ), 'S9 échoué : le message ou le statut a été modifié !';
  raise notice 'S9 OK : colonnes protégées par la machine à états';

  -- Nettoyage (retour postgres, bypass RLS)
  perform set_config('request.jwt.claims', '', false);
  execute 'set local role postgres';
  delete from trades where from_user = v_b and to_user = v_a;
  delete from collection_items where user_id in (v_a, v_b);
  delete from profiles where id in (v_a, v_b);

  raise notice '=== TOUS LES TESTS RLS SONT PASSÉS ===';
end $$;
