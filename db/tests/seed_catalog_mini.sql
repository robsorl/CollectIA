-- Mini-jeu de données de catalogue pour exécuter rls_tests.sql AVANT la
-- synchronisation PokéTCG API (S1). Rend le scénario S1 possible dès aujourd'hui
-- sur une base vierge : le job de synchronisation futur remplira le vrai
-- catalogue (milliers de cartes) et rendra ce jeu superflu.
--
-- Sans ce jeu, rls_tests.sql s'arrête strictement avec :
--   'Table cards vide : lancez d'abord la synchronisation du catalogue (S1)'

insert into sets (id, name, series, total_cards, release_date)
values ('swsh1', 'Sword & Shield', 'Sword & Shield', 202, '2020-02-07')
on conflict (id) do nothing;

insert into cards (id, set_id, number, name, name_fr) values
  ('swsh1-25', 'swsh1', '025/202', 'Pikachu',   'Pikachu'),
  ('swsh1-4',  'swsh1', '004/202', 'Charizard', 'Dracaufeu')
on conflict (id) do nothing;
