-- ============================================================
-- Tests RLS croisés à deux utilisateurs — CollectIA
-- Prérequis : migration 0001_init.sql appliquée, projet Supabase créé.
--
-- 1) Dashboard : Authentication → Users → ajouter deux utilisateurs de test
--    (ex. test-a@test.local et test-b@test.local), confirmer leurs emails.
-- 2) Exécuter ce script dans le SQL Editor : chaque scénario affiche un OK,
--    la moindre assertion échouée aborte le script avec le scénario fautif.
--
-- Scénarios 1-2 : accès légitime attendu. Scénarios 3-8 : attaques croisées
-- qui doivent rester infructueuses.
-- ============================================================
do $$
declare
  v_a uuid;
  v_b uuid;
  v_updated int;
begin
  -- Utilisateurs de test
  select u.id into v_a from auth.users u where u.email = 'test-a@test.local';
  select u.id into v_b from auth.users u where u.email = 'test-b@test.local';
  if v_a is null or v_b is null then
    raise exception 'Créez test-a@test.local et test-b@test.local dans Authentication > Users';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';

  -- Préparation : profils (B est PRIVÉ) + une carte du catalogue
  insert into profiles (id, username, visibility) values (v_a, 'test-a', 'public') on conflict do nothing;
  insert into profiles (id, username, visibility) values (v_b, 'test-b', 'private') on conflict do nothing;
  if not exists (select 1 from cards limit 1) then
    raise exception 'Table cards vide : lancez d''abord la synchronisation du catalogue (S1)';
  end if;

  -- S1 : A écrit dans SA collection → doit réussir
  insert into collection_items (user_id, card_id, language, quantity_owned, quantity_wanted)
  values (v_a, (select id from cards limit 1), 'fr', 2, 1);
  raise notice 'S1 OK : A a écrit sa collection';

  -- S2 : A lit SA collection → 1 ligne attendue
  assert (
    select count(*) from collection_items where user_id = v_a
  ) = 1, 'S2 échoué : A ne voit pas sa propre ligne';
  raise notice 'S2 OK : A lit sa collection (1 ligne)';

  -- S3 : A tente de lire la collection de B → 0 ligne attendue
  assert (
    select count(*) from collection_items where user_id = v_b
  ) = 0, 'S3 échoué : A voit la collection de B !';
  raise notice 'S3 OK : la collection de B est invisible pour A';

  -- S4 : A tente de modifier la collection de B → 0 ligne touchée
  update collection_items set quantity_owned = 999 where user_id = v_b;
  assert not found, 'S4 échoué : A a modifié la collection de B !';
  raise notice 'S4 OK : modification croisée impossible';

  -- S5 : A tente d'insérer au nom de B (usurpation) → doit échouer
  begin
    insert into collection_items (user_id, card_id, language, quantity_owned, quantity_wanted)
    values (v_b, (select id from cards limit 1), 'fr', 1, 0);
    raise exception 'S5 échoué : insertion usurpée acceptée !';
  exception when check_violation then
    raise notice 'S5 OK : usurpation bloquée par RLS';
  end;

  -- S6 : Le profil PRIVÉ de B est invisible pour A
  assert not exists (select 1 from profiles where id = v_b),
    'S6 échoué : A voit le profil privé de B !';
  raise notice 'S6 OK : profil privé de B invisible';

  -- S7 : Catalogue public lisible
  assert exists (select 1 from cards limit 1), 'S7 échoué : cards illisible';
  assert exists (select 1 from sets limit 1), 'S7 échoué : sets illisible';
  assert exists (select 1 from games limit 1), 'S7 échoué : games illisible';
  assert exists (select 1 from card_prices limit 1), 'S7 échoué : card_prices illisible';
  raise notice 'S7 OK : catalogue complet lisible';

  -- S8 : un échange "declined" ne peut pas être accepté par le destinataire A
  perform set_config('request.jwt.claims', '', false);
  execute 'set local role postgres';
  insert into trades (from_user, to_user, status) values (v_b, v_a, 'declined');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a::text, 'role', 'authenticated')::text, false);
  execute 'set local role authenticated';
  update trades set status = 'accepted'
  where to_user = v_a and from_user = v_b and status = 'declined';
  get diagnostics v_updated = row_count;
  assert v_updated = 0, 'S8 échoué : un échange décliné a pu être accepté !';
  raise notice 'S8 OK : échange décliné non modifiable';

  -- Nettoyage (retour en role postgres, bypass RLS)
  perform set_config('request.jwt.claims', '', false);
  execute 'set local role postgres';
  delete from trades where from_user = v_b and to_user = v_a;
  delete from collection_items where user_id = v_a;
  delete from profiles where id in (v_a, v_b);

  raise notice '=== TOUS LES TESTS RLS SONT PASSÉS ===';
end $$;
