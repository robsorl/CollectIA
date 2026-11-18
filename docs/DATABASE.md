# Base de données — schéma & sécurité

Source de vérité : [`db/migrations/0001_init.sql`](../db/migrations/0001_init.sql).

## Application de la migration

1. SQL Editor de Supabase → coller le contenu de `0001_init.sql` → Run
   (ou `supabase db push` si la CLI est configurée)
2. La migration est idempotente au niveau extensions (`create extension if not exists`)
   mais pas sur les tables : à n'exécuter que sur une base vierge.

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
réciproquement, score = nombre de cartes croisées) + trigger `collection_items_changed`
qui la rafraîchit automatiquement.

## Recherche

- Index trigrammes (pg_trgm, GIN) sur `f_unaccent(lower(name))` et `f_unaccent(lower(name_fr))`
  (fonction `f_unaccent` immuable basée sur l'extension `unaccent`) : autocomplétion
  tolérante aux fautes, troncatures **et accents** ("dracafu" matche « Dracaufeu »).
  Les requêtes doivent utiliser la même expression : `where f_unaccent(lower(name)) like '%q%'`.
- Index `cards(set_id, number)` : résolution OCR numéro + extension.

## Tests RLS

`db/tests/rls_tests.sql` — 8 scénarios d'accès croisés entre deux utilisateurs
(écrits de propre gré, lecture croisée, modification croisée, usurpation d'identité,
profil privé, catalogue public, échange décliné non réversible). À exécuter dans le
SQL Editor Supabase une fois les deux utilisateurs de test créés — passerelle
obligatoire avant la mise en production.

## Sécurité — Row Level Security (19 policies)

Principe : le client n'utilise **que la clé anon** ; chaque accès passe par les
policies côté Postgres. Aucune clé `service_role` dans le code applicatif
(réservée au job serveur de synchronisation du catalogue).

| Table | Lecture | Écriture |
|---|---|---|
| `games`, `sets`, `cards`, `card_prices` | publique | service role uniquement |
| `profiles` | soi-même + profils `<> 'private'` | soi-même uniquement |
| `collection_items` | **strictement soi-même** (`auth.uid() = user_id`) | soi-même uniquement |
| `themes` / `theme_cards` | propriétaire uniquement | propriétaire uniquement |
| `trades` | uniquement les 2 participants | `from_user` (insertion), `to_user` (accepter/refuser), `from_user` (annuler) |
| `trade_cards` | uniquement les participants à l'échange | auteur de la proposition |
| `trade_feedback` | — | insertion contrôlée : échange `completed`, l'auteur ≠ donneur de l'avis |

## À configurer côté Supabase (dashboard, hors migration)

- Auth → confirmation d'email activée, templates FR
- Auth → rate limits par défaut conservés ; Google OAuth à ajouter quand le projet
  Google Cloud sera créé (S1/S2)
- Backups : inclus au plan Pro (recommandé à la mise en production, cf. spec §10)
