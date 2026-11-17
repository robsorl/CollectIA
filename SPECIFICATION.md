# CardVault — Spécifications fonctionnelles MVP

> Application de gestion de collection de cartes Pokémon à l'unité, avec mise en relation pour échanges entre collectionneurs.
> Nom de travail : "CardVault" (placeholder — le nom final ne doit pas contenir de marque Nintendo/The Pokémon Company).
> Version : 1.0 — Périmètre : MVP solo + échange, sans paiement.

---

## 1. Vision & objectifs

- Permettre à un collectionneur de **numériser sa collection** rapidement (recherche + scan).
- **Classer** les cartes par série, extension, et thématiques personnalisées.
- Gérer les **doublons** (quantité possédée vs. besoin).
- Mettre en relation les collectionneurs sur leurs doublons/compléments (**matching d'échange**), les échanges se finalisant hors plateforme en MVP.
- Préparer la structure de données pour une future marketplace (paiement Stripe Connect).

### Positionnement long terme — référence Delcampe

- Le produit final est une **plateforme de collection & marketplace spécialisée TCG**, à la manière de [Delcampe](https://www.delcampe.net/fr/collections/) pour les univers de collection : catalogue par jeu, fiches publiques, vitrines de collectionneurs, transactions (enchères / prix fixe).
- **CollectIA démarre sur le seul univers Pokémon**, puis duplique le modèle sur d'autres TCG : Magic: The Gathering, Yu-Gi-Oh!, One Piece, Disney Lorcana, Digimon… (chaque jeu = son catalogue, sa communauté, son matching).
- Le nom "CollectIA" est générique à dessein : aucun renommage nécessaire.
- Hors périmètre assumé : les catégories non-TCG de Delcampe (timbres, cartes postales, monnaies…) — le ciblage reste le TCG.
- Conséquences appliquées dès la base de données (coût marginal maintenant, refonte coûteuse après coup) : table `games` (verticaux TCG) + `sets.game_id` + tableau de bord par jeu ; le catalogue se synchronise par jeu (Pokemon JP uniquement en MVP, flag `enabled`).
- SEO multi-univers : les pages /jeu/extension/carte deviennent des points d'entrée d'acquisition organique pour chaque nouveau jeu ajouté.

### Objectifs mesurables (6 mois post-lancement)
- 1 000 comptes inscrits, 30 % avec ≥ 1 collection importée.
- Taux de rétention mensuel ≥ 25 %.
- 50 échanges initiés via le matching.

---

## 2. Utilisateurs & parcours

### Personas
1. **Le collectionneur actif** (cœur de cible) : 18-40 ans, collectionne depuis l'enfance, cherche à compléter des sets et écouler ses doublons.
2. **Le revenant nostalgique** : reprend la collection, veut évaluer ce qu'il possède.
3. **Le trader** : collectionne intensif, cherche des matches d'échange en permanence.

### Parcours clés

**P1 — Import initial (activation)**
1. Inscription (email/Google).
2. Onboarding : "Ajoute ta première carte" → recherche par nom → ajout quantité possédée.
3. Proposition d'import groupé : saisie multi-cartes / scan photo.
4. Écran de synthèse : valeur estimée, complétion par extension.

**P2 — Gestion quotidienne**
1. Ouvrir "Ma collection" → filtre par extension/doublons.
2. Ajuster les quantités (+/-), marquer une carte "recherchée" (wishlist).
3. Consulter la fiche carte (prix, variantes, Possédée/Besoin).

**P3 — Échange**
1. Onglet "Échanges" → matches proposés : utilisateurs qui veulent mes doublons ET possèdent ce que je cherche.
2. Ouvrir un match → voir les 2 listes côte à côte → "Proposer un échange".
3. Le destinataire accepte / refuse / contre-propose.
4. Échange accepté → contacts/messages + marquage des cartes échangées (historique).

---

## 3. Périmètre fonctionnel MVP

### 3.1 Comptes
- Inscription/connexion : email + mot de passe, Google OAuth.
- Profil : pseudo, avatar, bio, ville (facultatif), visibilité de la collection (public / matches seulement / privé).

### 3.2 Catalogue de cartes (global, en lecture seule)
- Source : **PokéTCG API v2** (gratuite) — cartes, extensions, séries, images, raretés.
- **Langue** : les données PokéTCG API sont en anglais (Charizard, Umbreon…). Pour afficher les noms français (Dracaufeu, Noctali), compléter avec [TCGdex](https://tcgdex.dev/) (gratuite, multilingue dont français, Open Source) — mapping par `set code + numéro`, identiques entre éditions FR et EN. La recherche utilisateur accepte nom FR / nom EN indifféremment.
- Synchronisation : job quotidien (nouveautés), cache en base.
- Fiche carte : nom, numéro, extension, série, rareté, type, image, **prix de marché de référence** (moyenne TCGPlayer exposée par l'API).

### 3.3 Collection & doublons
- Ligne de possession par carte : `quantité_possédée`, `quantité_souhaitée`, état facultatif (NEUF/EXCELLENT/...).
- Badge automatique "Doublon" quand `quantité_possédée > quantité_souhaitée`.
- Badges "Manquante" (`souhaitée > 0 et possédée = 0`) et "Complète" par extension.
- Thématiques (liste de lecture) : dossiers personnalisés de cartes (ex. "Pokémon favoris", "Team Eau").
- Statistiques : nombre de cartes, valeur estimée totale, % complétion par extension.

### 3.4 Saisie des cartes
- **Recherche** : autocomplétion (nom, numéro), filtres extension/rareté/type.
- **Ajout rapide** : bouton +/- sur les résultats.
- **Scan photo (OCR)** : le scan ne lit **jamais toute la carte** (papier brillant, holo, reflets = échec quasi certain sur une carte entière). Prototype de référence : `prototype/ocr-prototype.mjs`.
  - **Viseur double** (validé sur images de référence) : le bas-gauche ne suffit pas — le numéro est en bas-**gauche** sur les layouts modernes (Sword & Shield, Scarlet & Violet) mais en bas-**droite** sur les cartes WotC (Base Set, Neo ~85 %/95-98 %). Deux viseurs superposés, ou un seul côté choisisable.
  - Pré-traitement JS avant OCR (pipeline validé) : recadrage viseur → niveaux de gris → soit contraste renforcé, soit binarisation par seuil d'Otsu (avec détection inversion : la minorité sombre est le texte) → upscaling ×4 en nearest-neighbor → marge blanche.
  - Tesseract.js : whitelist `0123456789/`, psm 7 en premier choix. **Multi-passes** (gris + binaire) : sur certaines cartes le numéro et le total sont lus séparément (ex. "9" et "111" sur Neo Genesis) → **combinaison des candidats** sur plusieurs passes.
  - **Résolution en base, pas confiance brute dans l'OCR** (validé) : la lecture "94/102" pour un vrai "4/102" (artefact devant) s'élimine en requêtant le catalogue — si la paire num/total n'existe pas dans le set, on propose les cartes voisines. L'app affiche une **liste de candidats avec images**, correction en 1 clic.
  - La correspondance catalogue se fait sur **numéro + code d'extension** (identiques en FR et EN), jamais sur le nom lu — ce qui contourne le problème de langue de la PokéTCG API (noms anglais uniquement). Complément **TCGdex API** (validé : `base1-4` → "Dracaufeu") pour l'affichage FR.
  - Limite connue : validé sur images de référence nettes (crops studio) — **la précision sur photos smartphone réelles reste à mesurer** (éclairage, angle, glare). L'OCR reste un *assisté* avec correction 1 clic, pas un déterminisme.
  - Mic et scanner code-barres hors MVP.
- **Import groupé** : saisie en série (multi-ajout à la suite).

### 3.5 Matching d'échange (cœur différenciant)
- Algorithme : `mes doublons ∩ sa wishlist` ET `ses doublons ∩ ma wishlist`, scoring = nb de cartes dans chaque sens.
- Filtrage : par pays/ville (rayon), par rareté minimum.
- Page "Matches" avec score et détail croisé des cartes.
- Proposition d'échange : liste de cartes offertes/demandées, message facultatif, statuts → `proposé / accepté / refusé / annulé` (contre-proposition hors MVP).
- Messagerie simple liée à la proposition (incluse en MVP).
- Historique des échanges + réputation simple (jauge 👍 donnée par l'autre partie) sans avis texte en MVP.

### 3.6 Hors périmètre (Phase 2+)
Paiements, vente/achat, notifications push, application mobile native, IA de reconnaissance complète, forums, contre-propositions, visiteurs anonymes sur fiches publiques.

---

## 4. Écrans (maquettes texte)

### 4.1 Accueil / Landing (non connecté)
```
┌────────────────────────────────────────────────┐
│  LOGO        Fonctionnalités   Connexion  S'inscrire │
├────────────────────────────────────────────────┤
│   Numérisez ta collection Pokémon.             │
│   Trouve des échanges pour tes doublons.       │
│   [ Commencer — gratuit ]                      │
│                                                │
│   [capture écran collection]  [capture échange]│
└────────────────────────────────────────────────┘
```

### 4.2 Ma collection (écran pivot)
```
┌─────────────────────────────────────────────────────────┐
│ LOGO | Ma collection | Échanges | Profil     [+ Ajouter]│
├─────────────────────────────────────────────────────────┤
│ 🔍 [Rechercher...]  [Extension ▾] [Rareté ▾] [Type ▾]  │
│ Filtres rapides: (•) Toutes ( ) Doublons ( ) Manquantes│
├─────────────────────────────────────────────────────────┤
│ ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐                  │
│ │ IMG  │  │ IMG  │  │ IMG  │  │ IMG  │   grille cartes  │
│ │Pikachu│ │Charizard│ ...                          │
│ │ ×2 D]│  │ ×1   │  │BESOIN│  │ ×3 DD│  D=doublon      │
│ │ [-][+]│  │ [-][+]│  │      │  │ [-][+]│               │
│ └──────┘  └──────┘  └──────┘  └──────┘                  │
├─────────────────────────────────────────────────────────┤
│ 1 024 cartes · Valeur estimée : 3 412 € · 89 doublons  │
│ Complétion : Épée&Bouclier 12/203 ▓░░  Scr 45/198 ▓▓░  │
└─────────────────────────────────────────────────────────┘
```

### 4.3 Fiche carte
```
┌───────────────────────────────────────────┐
│ ← Retour            Pikachu VMAX #044     │
│ ┌───────────┐  Rare · Électrique          │
│ │  IMAGE    │  Épée & Bouclier — EV01     │
│ │           │  Prix marché : 38,50 €      │
│ └───────────┘                             │
│ Possédé : [−] 2 [+]   Souhaité : [−] 1 [+]│
│ État (possédé) : (•) NEUF ( ) EXC ( ) BON │
│ Thématiques : [Équipe ⚡] [+ dossier]      │
│ [Voir les collectionneurs qui l'ont]  ⟵ Phase 2│
└───────────────────────────────────────────┘
```

### 4.4 Ajout / Scan
```
┌───────────────────────────────────────────┐
│ Ajouter des cartes                        │
│ [🔍 Chercher : illimi___________]         │
│  ├ Illumise        #317  EV — 0,10 €  [+ limite rate]│
│  └ ...                                    │
│ ──────────────────────────────────────────│
│ OU  📷 [Scanner la carte]                 │
│   → numéro détecté : "044" → Pikachu VMAX ✔│
│ Panier en cours : 3 cartes  [ Tout ajouter ]│
└───────────────────────────────────────────┘
```

### 4.5 Échanges — Matches
```
┌────────────────────────────────────────────────────┐
│ Échanges (3)                                       │
│ ▸ @chipie92 — Score 4                              │
│   Tu donnes : Pikachu VMAX, Électhor …             │
│   Tu reçois : Dracaufeu EX, Metagross …   [Voir »] │
│ ▸ @levieux.père — Score 2                          │
└────────────────────────────────────────────────────┘
```

### 4.6 Proposition d'échange
```
┌──────────────────────────────────────────────┐
│ Échange avec @chipie92                        │
│ Tu offres (2)          │ Tu reçois (2)       │
│ ▢ Pikachu VMAX ×1      │ ▢ Dracaufeu EX ×1   │
│ ▢ Électhor ×1          │ ▢ Metagross V ×1    │
│ [Message… (facultatif)]│                    │
│ [ Proposer l'échange ] [ Annuler ]           │
└──────────────────────────────────────────────┘
```
Statuts affichés en fil : `Proposé → Accepté/Refusé` + bouton "Marquer comme échangé".

---

## 5. Modèle de données (PostgreSQL / Supabase)

```sql
-- Référentiel carte (miroir PokéTCG API)
CREATE TABLE sets (
  id TEXT PRIMARY KEY,              -- id API ex. "swsh1"
  name TEXT NOT NULL, series TEXT NOT NULL,
  total_cards INT, release_date DATE, logo_url TEXT, symbol_url TEXT
);

CREATE TABLE cards (
  id TEXT PRIMARY KEY,              -- id API ex. "swsh1-44"
  set_id TEXT REFERENCES sets(id), number TEXT, name TEXT NOT NULL,
  rarity TEXT, supertype TEXT, types TEXT[], image_url TEXT,
  market_price NUMERIC(10,2), api_updated_at TIMESTAMPTZ
);

-- Utilisateurs
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id),
  username CITEXT UNIQUE NOT NULL, avatar_url TEXT, bio TEXT,
  city TEXT, country TEXT,
  visibility TEXT NOT NULL DEFAULT 'matches_only'
    CHECK (visibility IN ('public','matches_only','private'))
);

-- Collection
CREATE TABLE collection_items (
  user_id UUID REFERENCES profiles(id), card_id TEXT REFERENCES cards(id),
  quantity_owned INT NOT NULL DEFAULT 0 CHECK (quantity_owned >= 0),
  quantity_wanted INT NOT NULL DEFAULT 0 CHECK (quantity_wanted >= 0),
  condition TEXT CHECK (condition IN ('mint','excellent','good','played')),
  PRIMARY KEY (user_id, card_id)
);
CREATE INDEX ON collection_items (user_id, quantity_owned);

-- Thématiques (dossiers)
CREATE TABLE themes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id), name TEXT NOT NULL
);
CREATE TABLE theme_cards (
  theme_id UUID REFERENCES themes(id) ON DELETE CASCADE,
  card_id TEXT REFERENCES cards(id), PRIMARY KEY (theme_id, card_id)
);

-- Échanges
CREATE TABLE trades (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user UUID REFERENCES profiles(id), to_user UUID REFERENCES profiles(id),
  status TEXT NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed','accepted','declined','cancelled','completed')),
  message TEXT, created_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);
CREATE TABLE trade_cards (
  trade_id UUID REFERENCES trades(id) ON DELETE CASCADE,
  card_id TEXT REFERENCES cards(id),
  direction TEXT CHECK (direction IN ('offered','requested')),
  quantity INT NOT NULL DEFAULT 1,
  PRIMARY KEY (trade_id, card_id, direction)
);

-- Réputation
CREATE TABLE trade_feedback (
  trade_id UUID REFERENCES trades(id) PRIMARY KEY,
  author UUID REFERENCES profiles(id),
  rating SMALLINT CHECK (rating = 1)   -- 👍 seulement en MVP
);
```

**Index clés pour le matching** :
```sql
CREATE INDEX idx_owned_dupes ON collection_items (user_id)
  WHERE quantity_owned > quantity_wanted;
CREATE INDEX idx_wanted ON collection_items (user_id)
  WHERE quantity_wanted > quantity_owned;
```

**Matching** (vue matérialisée, rafraîchie toutes les 15 min) :
```sql
CREATE MATERIALIZED VIEW trade_matches AS
SELECT a.user_id AS me, b.user_id AS other, COUNT(*) AS score
FROM collection_items a
JOIN collection_items b ON b.card_id = a.card_id
WHERE a.quantity_owned  > a.quantity_wanted      -- j'ai trop
  AND b.quantity_wanted > b.quantity_owned       -- lui en veut
GROUP BY a.user_id, b.user_id
UNION ALL
SELECT a.user_id, b.user_id, COUNT(*)
FROM collection_items a
JOIN collection_items b ON b.card_id = a.card_id
WHERE b.quantity_owned  > b.quantity_wanted
  AND a.quantity_wanted > a.quantity_owned
GROUP BY a.user_id, b.user_id;
```

---

## 6. Architecture technique

```
[Next.js 14 App Router]  ⇄  [Supabase]
   - Pages SSR/ISR pour fiches publiques (SEO)      - Postgres (+ RLS)
   - Server Actions / API routes                    - Auth (email, Google OAuth)
   - Composants : Tailwind + shadcn/ui              - Storage (avatars, photos scan)
   - TanStack Query (cache client)                  - Realtime (messagerie)
[Jobs]
   - Vercel Cron : sync quotidienne PokéTCG API / prix
   - Refresh matview matching (15 min)
[Services tiers]
   - PokéTCG API v2 (catalogue, prix, images)
   - TCGdex (noms + visuels en français, translittération FR↔EN)
   - OCR : Tesseract.js (côté client, viseur + pré-traitement, never full-card)
   - (Phase marketplace) Stripe Connect
```

**Choix de stack** : Next.js (SEO des fiches publiques de cartes = acquisition gratuite), Supabase (Postgres + Auth + Storage + Realtime sans ops, gratuit jusqu'à ~500 MB / 50 000 MAU), Tailwind + shadcn/ui (vitesse de développement).

> **Arbitrage framework tranché** : une exploration Astro avait été envisagée ; Astro est écarté pour ce projet. Numérisage des échanges temps réel (messagerie Supabase), dashboards interactifs et ISR SEO ont besoin d'un framework applicatif unique — Next.js couvre les deux. Une seule stack, aucune double maintenance.

### Sécurité & RLS (extraits)
- `collection_items` : SELECT/UPDATE seulement si `user_id = auth.uid()`.
- `trades` : SELECT si participant ; INSERT si `auth.uid() = from_user` ; UPDATE de statut si destinataire (accepter/refuser) ou auteur (annuler).
- `profiles` : UPDATE soi-même ; SELECT si `visibility != 'private'` ou participant à un échange.

---

## 7. Design & tokens

- Look & feel inspiré du TCG sans reproduire la marque : fond sombre, accents dorés/jaunes, cartes en grille type "album".
- Couleurs : background `#0F1115`, surface `#1A1D23`, primaire `#F5C518` (or), accent doublons `#FF6B6B`, succès `#3ECF8E`.
- Typo : Inter (UI) ; les noms de cartes en gras.
- Mobile-first (la majorité des scans photos se fera au téléphone).

---

## 8. Roadmap & jalons

| Sprint | Durée | Livrable |
|---|---|---|
| S0 | 1 sem | Init projet, CI, schéma DB, migrations Supabase |
| S1 | 2 sem | Auth + profils + sync catalogue PokéTCG + recherche |
| S2 | 2 sem | Collection : ajout +/-, doublons, filtres, statistiques |
| S3 | 2 sem | Scan OCR, thématiques, page import groupé |
| S4 | 2 sem | Matching, propositions d'échange, messagerie |
| S5 | 1 sem | Landing publique, fiches CRUD publiques SEO, feedbacks |
| S6 | 1-2 sem | Beta fermée, corrections, monitoring |
| **Total** | **~10-12 sem** | |

### Après MVP (Phase 2)
Freemium (300 cartes gratuites / illimité 4 €/mois) → marketplace avec Stripe Connect → notifications → reconnaissance IA des cartes → applications mobiles.

### Phase 4 — duplication multi-TCG (référence Delcampe)
1. Magic: The Gathering (API Scryfall, gratuite, très complète), puis Yu-Gi-Oh! (YGOPRODeck), One Piece, Disney Lorcana…
2. Adapter par jeu : schéma de référence (sets/cartes), source de prix, OCR (le layout des cartes diffère : numéro, coin, codes couleur), traductions.
3. Le cœur produit (collection/doublons/matching/échange) est **réutilisé tel quel** ; seuls le référentiel et les spécificités d'import changent.
4. Accueil côté catégorie à la Delcampe : page par jeu avec décompte d'objets et compteur de collectionneurs.

---

## 9. Risques

| Risque | Impact | Mitigation |
|---|---|---|
| Marque "Pokémon" (PI) | juridique | Nom neutre, données via API publique, disclaimer "fan-made" |
| Qualité OCR sur photos | UX | Saisie manuelle prioritaire dans l'UI ; OCR en mode assisté avec correction en 1 clic ; pipeline multi-passes + résolution catalogue (prototype validé sur images de référence) |
| Layouts anciens (WotC) : numéro en bas-droite | UX | Viseur double gauche/droite (cf. 3.4) |
| Matches rares au lancement (effet réseau) | croissance | Matching sur wishlist global + tri par proximité, import massif facilité |
| Fraude/échange malhonnête | confiance | Réputation +, signaler, conditions d'usage ; hors MVP : escrow au stade marketplace |
| Coûts API/images à l'échelle | technique | Cache images CDN, sync incrémentale |

---

## 10. Coûts & point mort

### 10.1 Structure de coûts : fixe vs variable

| Poste | Nature | Lancement | Palier croissance (1k-10k users) |
|---|---|---|---|
| Hébergement (Vercel) | fixe | 0 € (Hobby) | ~19 €/mois (Pro, 1 To bande passante incluse) |
| Base de données + Auth + Storage (Supabase) | fixe | 0 € (Free : 500 MB DB, 1 GB storage, 50k MAU) | ~24 €/mois (Pro : 8 GB DB, 100 GB storage) |
| Nom de domaine | fixe | ~12 €/an | ~12 €/an |
| Catalogue PokéTCG API | fixe | 0 € (gratuite, 1 000 req/jour sans clé / 20 000 avec clé gratuite) | 0 € (sync quotidienne, quota largement suffisant) |
| OCR (Tesseract.js) | **0 €** | calcul exécuté côté client | 0 € |
| Bande passante images de cartes | ~0 € | **non proxysées** : images servies directement depuis le CDN pokemontcg.io (hotlinking autorisé) | ~0 € |
| Paiements (Stripe, phase 3 uniquement) | variable | — | 1,4 % + 0,25 € par transaction EU (payé uniquement sur revenus) |

> Hypothèse structurante : les images (~19 000 cartes) ne sont **jamais** stockées ni proxysées par l'application. C'est le poste qui tuerait la marge ; l'affichage direct depuis le CDN source le ramène à zéro.

### 10.2 Point mort par palier

| Palier | Coûts fixes/mois | Abonnés nécessaires (4 €/mois) |
|---|---|---|
| Bêta (0-1k users) | ~1 € | ~1 abonné |
| Croissance (1k-10k) | ~44 € | 11 abonnés |
| Scale (10k+ users, hors marketplace) | < 100 € (basculer Supabase Pro compute si DB > 8 GB) | 25 abonnés |

**Conclusion structurelle : les coûts d'infrastructure ne conditionnent pas la rentabilité.** Le point mort d'infrastructure est atteint à ~11 abonnés ; le coût principal à amortir est le temps de développement (10-12 semaines MVP), pas la stack.

### 10.3 Projection simplifiée (hypothèses : 4 €/mois, conversion payante 8 %, churn 5 %/mois)

| Horizon | Utilisateurs actifs | Abonnés | Revenus/mois | Coûts/mois | M brute/mois |
|---|---|---|---|---|---|
| Mois 3 (bêta) | 100 | — | 0 | ~1 € | -1 € |
| Mois 6 | 500 | 40 | 160 € | ~2 € | ~158 € |
| Mois 12 | 1 500 | 120 | 480 € | ~44 € | ~436 € |
| Mois 24 | 4 000 | 320 | 1 280 € | ~70 € | ~1 210 € |

Sensibilité : à conversion 5 % (au lieu de 8 %), la marge à 12 mois tombe à ~260 €/mois — toujours très au-dessus des coûts fixes. Le risque financier n'est pas l'infrastructure mais l'acquisition d'utilisateurs (gratuite via SEO des fiches publiques, ou payante : à chiffrer séparément si growth payant).

### 10.4 Amortissement du temps de développement (honnêteté sur la "rentabilité passive")

- 10-12 semaines à temps plein ≈ 24-30 k€ de coût d'opportunité (tarif freelance de référence).
- À ~430 €/mois de marge brute (scénario médian mois 12), l'amortissement prend des années si le produit reste un simple outil de collection.
- **Le levier de rentabilité est la phase 2/3, pas le MVP** : marketplace (commission 5-10 % sur volume de transactions) et une plus grande liberté de prix (stats de valeur, alertes de prix = fonctionnalités à forte disposition à payer chez les collectionneurs de cartes de valeur).
- Décision recommandée : traiter le MVP comme un investissement en acquisition d'audience, et ne valider la poursuite qu'après les métriques d'activation/rétention de la section 1.

### 10.5 Alternatives de coûts plus faibles et pourquoi elles sont écartées

| Alternative | Coût | Écartée car |
|---|---|---|
| VPS 5 €/mois (Hetzner) + Postgres auto-hébergé | ~5-10 €/mois | +10-15 h/mois d'ops (sauvegardes, sécurité, monitoring) — échange 30-40 €/mois d'infra contre du temps, la ressource la plus rare du projet |
| Cloudflare Pages + Neon | ~0 € | viable, mais écosystème moins intégré (Auth, Storage, Realtime à monter soi-même) → temps de dev + |
| Stockage des images en propre | menace marge | voir 10.1 : règle absolue de non-proxysation |

### 10.6 Gardes-fous anti-dérive budgétaire (à mettre en place en S0)

1. **Vercel** : définir une limite de dépense (Spend Management) dès la création du projet — sans elle, aucune alerte en cas de pics de trafic.
2. **Supabase** : activer les alertes d'usage (email à 75 % des quotas) ; prévoir le passage Pro dès la sortie de bêta (le plan Free met en pause après 7 jours d'inactivité, inacceptable en production).
3. **Images** : règle de revue de code — aucune ressource `/cards/*` servie depuis le domaine de l'app ; toujours URL CDN source.
4. **Matview matching** : refresh 15 min au démarrage, passer à 60 min si le coût de compute Supabase monte (l'app n'a pas besoin de matching temps réel).
5. **Cron PokéTCG API** : 1 sync quotidienne max ; le catalogue ne change que quelques fois par an, les prix 1×/jour suffisent.

### 10.7 Coût à ne pas sous-estimer : la modération

- Dès l'ouverture des échanges : gestion des signalements, litiges, contrefaçons — charge humaine non scalable à la main.
- Budgété en phase 2 : outils de modération (vers ~0-20 €/mois), temps humain ~1-2 h/semaine au-delà de 1 000 utilisateurs actifs.
- À horizon marketplace : c'est le poste de coût réel (support + modération + gestion des litiges), à intégrer dans le taux de commission (les 5-10 % couvrent aussi cela).
