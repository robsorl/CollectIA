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

  -- S10 : JWT service_role -> bypass du trigger ; une transition autorisée doit
  --       réussir même sans sub (claims sans utilisateur). Portée : la branche du
  --       trigger conditionnée au CLAIM est testée (pas une intégration de bout
  --       en bout du rôle DB service_role de Supabase — celle-ci sera couverte à
  --       l'exécution sur le projet réel).
  perform set_config('request.jwt.claims',
    json_build_object('role', 'service_role')::text, false);
  execute 'set local role postgres';  -- comme le service_role Supabase (bypass RLS)
  update trades set status = 'accepted'
  where from_user = v_b and to_user = v_a and status = 'proposed';
  get diagnostics v_updated = row_count;
  assert v_updated = 1, 'S10 échoué : le bypass JWT service_role ne fonctionne pas';
  raise notice 'S10 OK : bypass JWT service_role (transition autorisée réussie)';
  update trades set status = 'proposed' where from_user = v_b and to_user = v_a;

  -- S11 : immuabilité NULL -> valeur. L'ancienne comparaison <> renvoyait NULL
  --       (pas TRUE) face à old.created_at NULL : la modification passait. Avec
  --       IS DISTINCT FROM, le garde-fou doit déclencher ; booléen + assertion
  --       finale HORS du bloc EXCEPTION (même schéma que S9).
  insert into trades (from_user, to_user, status, created_at, message)
  values (v_b, v_a, 'proposed', null, null);  -- service_role toujours en contexte
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';
  v_guard_triggered := false;
  begin
    update trades
    set status = 'accepted', created_at = '2000-01-01', message = 'piraté'
    where from_user = v_b and to_user = v_a and status = 'proposed'
      and created_at is null;
    get diagnostics v_updated = row_count;
    if v_updated = 0 then
      v_guard_triggered := true;
    end if;
  exception
    when raise_exception or insufficient_privilege then
      v_guard_triggered := true;
      raise notice 'S11 : garde-fou déclenché (%)', sqlerrm;
  end;
  assert v_guard_triggered, 'S11 échoué : traversée NULL -> valeur acceptée !';
  assert exists (
    select 1 from trades
    where from_user = v_b and to_user = v_a and status = 'proposed'
      and created_at is null and message is null
  ), 'S11 échoué : la traversée NULL -> valeur a été appliquée !';
  raise notice 'S11 OK : immuabilité NULL -> valeur (IS DISTINCT FROM)';

  -- S12 : l'historique des cartes d'un échange est figé dès la décision —
  --       pas d'ajout dans trade_cards après clôture, et quantité > 0 imposée.
  execute 'set local role postgres';
  perform set_config('request.jwt.claims', '', false);
  -- clôture du second échange (created_at non NULL) via service (bypass trigger)
  update trades set status = 'accepted'
  where from_user = v_b and to_user = v_a and created_at is not null;
  update trades set status = 'completed'
  where from_user = v_b and to_user = v_a and created_at is not null;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';

  v_guard_triggered := false;
  begin
    insert into trade_cards (trade_id, card_id, direction, quantity)
    select t.id, (select id from cards limit 1), 'offered', 1 from trades t
    where t.from_user = v_b and t.to_user = v_a and t.status = 'completed';
    get diagnostics v_updated = row_count;
    if v_updated = 0 then
      v_guard_triggered := true;
    end if;
  exception
    when insufficient_privilege or raise_exception then
      v_guard_triggered := true;
      raise notice 'S12 : garde-fou déclenché (%)', sqlerrm;
  end;
  assert v_guard_triggered, 'S12 échoué : carte ajoutée à un échange clos !';

  v_guard_triggered := false;
  begin
    insert into trade_cards (trade_id, card_id, direction, quantity)
    select t.id, (select id from cards limit 1), 'offered', 0 from trades t
    where t.from_user = v_b and t.to_user = v_a and t.status = 'proposed'
      and t.created_at is null;
  exception
    when check_violation or insufficient_privilege or raise_exception then
      v_guard_triggered := true;
      raise notice 'S12 : quantité invalide bloquée (%)', sqlerrm;
  end;
  assert v_guard_triggered, 'S12 échoué : quantité 0 acceptée sur une carte !';

  assert not exists (select 1 from trade_cards),
    'S12 échoué : trade_cards n''est plus vide après les blocages !';
  raise notice 'S12 OK : historique figé après clôture + quantité > 0';

  -- S13 : anon = lecture seule du catalogue ; trade_matches jamais lisible
  --       en direct (matview sans RLS :Granted passage technique refusé) ;
  --       aucune écriture utilisateur sans contexte authentifié.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'anon')::text, false);
  execute 'set local role anon';
  assert exists (select 1 from cards limit 1), 'S13 échoué : catalogue illisible pour anon';
  v_guard_triggered := false;
  begin
    perform count(*) from trade_matches;
  exception
    when insufficient_privilege then
      v_guard_triggered := true;
  end;
  assert v_guard_triggered, 'S13 échoué : anon lit trade_matches !';
  v_guard_triggered := false;
  begin
    insert into collection_items (user_id, card_id, language, quantity_owned, quantity_wanted)
    values (v_a, (select id from cards limit 1), 'fr', 1, 0);
    get diagnostics v_updated = row_count;
    if v_updated = 0 then
      v_guard_triggered := true;
    end if;
  exception
    when insufficient_privilege then
      v_guard_triggered := true;
  end;
  assert v_guard_triggered, 'S13 échoué : anon écrit dans une collection !';
  raise notice 'S13 OK : anon = catalogue lecture seule, matches et écritures bloqués';

  -- S13 bis : un connecté non plus — la matview n'est lisible QUE par sa
  --           fenêtre personnelle (fonction S14).
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';
  v_guard_triggered := false;
  begin
    perform count(*) from trade_matches;
  exception
    when insufficient_privilege then
      v_guard_triggered := true;
  end;
  assert v_guard_triggered, 'S13 échoué : trade_matches lisible par un authentifié !';
  raise notice 'S13 bis OK : trade_matches inaccessible en direct pour un connecté';

  -- S14 : fenêtre de matching get_trade_matches() : seulement ME = auth.uid(),
  --       et profils privés des autres collectionneurs masqués.
  execute 'set local role postgres';
  perform set_config('request.jwt.claims', '', false);
  -- B est encore 'private' (état imposé par le setup du scénario S6) : le test
  -- DOIT d'abord démontrer que son match n'est PAS exposé (audit v7, point 3).
  insert into collection_items (user_id, card_id, language, quantity_owned, quantity_wanted)
  select v_b, id, 'fr', 0, 2 from cards limit 1;  -- B veut la carte doublonée par A
  refresh materialized view trade_matches;

  -- Non-vacuité (audit v8) : le jeu de test doit PROUVER qu'il produit le
  -- match attendu dans la matview — sinon les assertions suivantes sur la
  -- fonction passeraient même sans masquage.
  assert exists (
    select 1 from trade_matches
    where me = v_a and other = v_b
  ), 'S14 échoué : le jeu de test ne produit pas le match attendu dans la matview';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';
  -- ciblé sur le couple (A, B) : sur le vrai projet, A peut avoir d'autres
  -- matches légitimes avec des profils public/matches_only (audit v8).
  assert not exists (
    select 1 from get_trade_matches()
    where me = v_a and other = v_b
  ), 'S14 échoué : le profil private de B est exposé dans le matching !';

  -- S14-suite : B passe en 'matches_only' — il accepte d'apparaître dans les
  -- fenêtres de matching. La visibilité est appliquée au moment de la requête
  -- (jointure profiles dans la fonction) : aucun refresh supplémentaire requis.
  execute 'set local role postgres';
  perform set_config('request.jwt.claims', '', false);
  update profiles set visibility = 'matches_only' where id = v_b;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';
  assert exists (
    select 1 from get_trade_matches() where me = v_a and other = v_b
  ), 'S14 échoué : A ne voit pas son match';
  assert not exists (
    select 1 from get_trade_matches() where me <> v_a
  ), 'S14 échoué : get_trade_matches() expose des lignes d''autrui !';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b::text, 'role', 'authenticated')::text, false);
  assert exists (
    select 1 from get_trade_matches() where me = v_b and other = v_a
  ), 'S14 échoué : B ne voit pas son match (direction inverse)';
  raise notice 'S14 OK : matches cloisonnés par utilisateur (me = auth.uid())';

  -- Nettoyage (retour postgres, bypass RLS)
  perform set_config('request.jwt.claims', '', false);
  execute 'set local role postgres';
  delete from trades where from_user = v_b and to_user = v_a;
  delete from collection_items where user_id in (v_a, v_b);
  delete from profiles where id in (v_a, v_b);

  raise notice '=== TOUS LES TESTS RLS SONT PASSÉS ===';
end $$;
