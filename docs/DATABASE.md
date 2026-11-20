# Base de données — schéma & sécurité

Source de vérité : [`db/migrations/0001_init.sql`](../db/migrations/0001_init.sql).

## Application de la migration

1. SQL Editor de Supabase → coller le contenu de `0001_init.sql` → Run
   (ou `supabase db push` si la CLI est configurée)
2. La migration est idempotente au niveau extensions (`create extension if not exists`)
   mais pas sur les tables : à n'exécuter que sur une base vierge.
3. Une fois `0001_init.sql` exécuté, exécuter [`db/migrations/0002_data_api_grants.sql`](../db/migrations/0002_data_api_grants.sql)
   — **indispensable** si l'option « Grant API access to new tables automatically »
   est désactivée (c'est notre configuration, cf. audit v5 : les privilèges SQL
   PostgREST ne sont posés par personne d'autre).
4. Instance **déjà migrée** (`kutnkduubllkzcorlelj`) : ne PAS rejouer `0001_init.sql`
   (il recréerait des objets existants). Exécuter uniquement `0002_data_api_grants.sql` :
   il converge quel que soit l'état initial (révocation du bloc `grant all` global
   posé en urgence pour le 42501, puis privilèges minimaux objet par objet).
5. Si l'instance avait reçu la version PR #4 de `0001_init.sql` (le cas de
   `kutnkduubllkzcorlelj` avant 2026-11-20), exécuter aussi
   [`0003_trade_cards_instance_hardening.sql`](../db/migrations/0003_trade_cards_instance_hardening.sql) :
   policy `trade cards author write` restreinte à `status = 'proposed'` et
   `CHECK (quantity > 0)` — détectés manquants par l'échec de S12 sur le projet réel.

## Tables

| Table | Rôle | Clé primaire |
|---|---|---|
| `games` | Verticaux TCG (Pokémon MVP ; Magic, Yu-Gi-Oh!, One Piece en Phase 4), flag `enabled` | `id` |
| `sets` | Extensions/éditions, rattachées à un jeu (`game_id`) | `id` |
| `cards` | Catalogue centralisé (miroir PokéTCG API + `name_fr` via TCGdex) | `id` |
| `card_prices` | Historique des prix par source/**variante** et par jour (écrit par le job de sync). Les sources publiques exposent des prix de marché (cotation affichée), pas le prix vendu — celui-ci viendra des transactions de la marketplace (Phase 3) | `(card_id, source, variant, recorded_at)` |
| `profiles` | Profil utilisateur (pseudo, ville, **visibilité** : `public` / `matches_only` / `private`) | `id` = `auth.users.id` |
| `collection_items` | Possession par carte/langue/état ; quantités possédée + souhaitée. **Choix assumé MVP** : une ligne par (carte, langue) avec condition unique — la granularité exemplaire-par-exemplaire (état distinct par copie) arrivera avec les annonces de la marketplace (Phase 3) | `(user_id, card_id, language)` |
| `themes`, `theme_cards` | Dossiers personnalisés | — |
| `trades`, `trade_cards` | Propositions d'échange (statuts : proposed/accepted/declined/cancelled/completed) | — |
| `trade_feedback` | Réputation post-échange (👍) | `trade_id` |

Objets calculés : vue matérialisée `trade_matches` (mes doublons ∩ sa wishlist et
réciproquement, score = nombre de cartes croisées). Les deux directions sont
agrégées (`union all` puis `group by (me, other)` avec `sum(score)`) : un couple
de collectionneurs peut matcher dans les deux sens, et l'unique index sur
`(me, other)` doit rester sans doublon pour que le `refresh concurrently` passe.

> 🔒 **Accès cloisonné** : la matview ne supporte pas la RLS (limitation
> PostgreSQL sur les vues matérialisées). Elle n'est donc **jamais lisible en
> direct** par `anon`/`authenticated` — l'accès passe uniquement par la fonction
> `SECURITY DEFINER get_trade_matches()` qui ne retourne que les lignes
> `me = auth.uid()`, en masquant les collectionneurs au profil `private`.
> Voir `db/migrations/0002_data_api_grants.sql` (privilèges minimaux).

> ⚠️ **Pas de trigger de refresh** : `REFRESH ... CONCURRENTLY` est interdit dans
> une transaction, or un trigger s'exécute dans celle de l'écriture — ce trigger
> aurait rendu chaque écriture de collection échouante. Le refresh est un **job
> planifié** : pg_cron (extension à activer dans Supabase) toutes les 5 min, ou
> Vercel Cron. La fraîcheur des matches à quelques minutes près est acceptable
> (cf. spec §10.6).

## Machine à états des échanges

Trigger `trades_guard_transition` (avant UPDATE sur `trades`) — il couvre ce que
les policies RLS ne peuvent pas exprimer (contraintes sur les nouvelles valeurs) :

| Acteur | Ancien statut | Nouveaux autorisés |
|---|---|---|
| Destinataire (`to_user`) | `proposed` | `accepted`, `declined` |
| Auteur (`from_user`) | `proposed` | `cancelled` |
| Participants | `accepted` | `completed` (+ `completed_at`) |
| Tous | `declined`, `cancelled`, `completed` | aucun (états terminaux) |
| Tous | statut inchangé | aucune autre colonne modifiable |

Colonnes immuables après création : `id`, `created_at`, `from_user`, `to_user`,
`message` (comparaison `IS DISTINCT FROM`, robuste contre NULL — la traversée
NULL → valeur est également bloquée). `from_user` et `to_user` sont `NOT NULL` :
un échange sans auteur ou destinataire n'a pas de sens métier. La colonne
`completed_at` appartient au trigger : horodatée `now()` à la clôture réelle,
`NULL` sinon — aucune date fournie par le client n'est conservée (pas de
`coalesce`).
Bypass du trigger : sans JWT (maintenance directe) **ou** JWT `service_role`
(le claim `role` est reconnu explicitement — un JWT utilisateur sans `sub` ne
bypass pas, il est rejeté). Les policies `FOR UPDATE` sur `trades` portent
`USING` + `WITH CHECK` correspondants (les policies permissives se combinent
en OR — le trigger reste la contrainte forte).

## Recherche

- Index trigrammes (pg_trgm, GIN) sur `f_unaccent(lower(name))` et `f_unaccent(lower(name_fr))`
  (fonction `f_unaccent` immuable basée sur l'extension `unaccent`) : autocomplétion
  tolérante aux fautes, troncatures **et accents** ("dracafu" matche « Dracaufeu »).
  Les requêtes doivent utiliser la même expression : `where f_unaccent(lower(name)) like '%q%'`.
- Index `cards(set_id, number)` : résolution OCR numéro + extension.

## Tests RLS

`db/tests/rls_tests.sql` — 14 scénarios d'accès croisés entre deux utilisateurs
(écrits de propre gré, lecture croisée, modification croisée, usurpation d'identité,
profil privé, catalogue public, échange décliné non réversible, machine à états
+ bypass service_role, traversée NULL, historique de cartes figé + quantité,
cloisonnement anon/matches, fenêtre de matching).
À exécuter dans le SQL Editor Supabase une fois les deux utilisateurs de test
créés (et, avant la synchro S1, le jeu [`db/tests/seed_catalog_mini.sql`](../db/tests/seed_catalog_mini.sql))
— passerelle obligatoire avant la mise en production.

## Sécurité — Row Level Security (21 policies)

Principe : le client n'utilise **que la clé anon** ; chaque accès passe par les
policies côté Postgres. Aucune clé `service_role` dans le code applicatif
(réservée au job serveur de synchronisation du catalogue).

| Table | Lecture | Écriture |
|---|---|---|
| `games`, `sets`, `cards`, `card_prices` | publique | service role uniquement |
| `profiles` | soi-même + profils `<> 'private'` | soi-même uniquement |
| `collection_items` | **strictement soi-même** (`auth.uid() = user_id`) | soi-même uniquement |
| `themes` / `theme_cards` | propriétaire uniquement | propriétaire uniquement |
| `trades` | uniquement les 2 participants | `from_user` (insertion) ; mises à jour limitées à la machine à états (cf. section dédiée) : destinataire (accepter/refuser), auteur (annuler), participants (clôture) |
| `trade_cards` | uniquement les participants à l'échange | auteur de la proposition |
| `trade_feedback` | — | insertion contrôlée : échange `completed`, l'auteur ≠ donneur de l'avis |

## À configurer côté Supabase (dashboard, hors migration)

- Auth → confirmation d'email activée, templates FR
- Auth → rate limits par défaut conservés ; Google OAuth à ajouter quand le projet
  Google Cloud sera créé (S1/S2)
- Backups : inclus au plan Pro (recommandé à la mise en production, cf. spec §10)
