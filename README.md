# CollectIA

Application de gestion de collection de cartes Pokémon à l'unité : numérisation,
classement par extension/thématique, gestion des doublons et matching d'échange
entre collectionneurs (sans paiement au stade MVP).

**Spécifications complètes : [SPECIFICATION.md](SPECIFICATION.md)**

## Stack

- **Next.js 14** (App Router, TypeScript) — SSR/ISR pour les fiches publiques (SEO)
- **Supabase** — Postgres + RLS, Auth (email + Google OAuth), Storage, Realtime
- **Tailwind CSS** — tokens design dans `tailwind.config.ts`
- **PokéTCG API v2** (catalogue anglais, prix) + **TCGdex** (noms français)

## Démarrage

```bash
npm install
cp .env.example .env.local
# renseigner NEXT_PUBLIC_SUPABASE_URL et NEXT_PUBLIC_SUPABASE_ANON_KEY
npm run dev
```

## Base de données

Schéma et RLS dans `db/migrations/0001_init.sql` — à appliquer via l'éditeur SQL
Supabase ou `supabase db push` (si CLI configurée). Inclut :

- référentiel `sets`/`cards` (miroir PokéTCG API)
- `profiles`, `collection_items` (quantités possédée/souhaitée, badges doublons)
- `themes`/`theme_cards`, `trades`/`trade_cards`, `trade_feedback`
- vue matérialisée `trade_matches` (mes doublons ∩ sa wishlist) + trigger de refresh

## Prototype scan OCR

`prototype/ocr-prototype.mjs` — lecture du numéro de carte
(Tesseract.js), pipeline validé : viseur (bas-gauche moderne / bas-droite WotC) →
gris ou binarisation Otsu → upscale ×4 → OCR → résolution en catalogue.
Dépendances (pas dans package.json) :

```bash
cd prototype && npm i tesseract.js jimp@0.22.12
node ocr-prototype.mjs https://images.pokemontcg.io/swsh1/44_hires.png
```

## Scripts

| Commande | Rôle |
|---|---|
| `npm run dev` | serveur de développement |
| `npm run build` | build production (bloquant en CI) |
| `npm run typecheck` | TypeScript strict |

## Roadmap

Sprints détaillés dans la spec (§8) : S1 auth + sync catalogue → S2 collection →
S3 scan/thématiques → S4 matching/échanges → S5 landing SEO → S6 bêta.

**Vision long terme** (spec §1 et §8, Phase 4) : plateforme de collection &
marketplace TCG à la Delcampe — démarrage Pokémon, puis duplication du modèle
sur Magic, Yu-Gi-Oh!, One Piece, Lorcana (schéma déjà préparé : table `games`).
