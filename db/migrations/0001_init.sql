-- CardVault / CollectIA — initialisation du schéma (cf. SPECIFICATION.md §5)
-- Tables : sets, cards, profiles, collection_items, themes, theme_cards,
-- trades, trade_cards, trade_feedback + indexes matching + matview.

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists unaccent;
create extension if not exists citext;

-- Référentiel carte (miroir PokéTCG API)
create table sets (
  id text primary key,
  game_id text references games(id) not null default 'pokemon',
  name text not null,
  series text not null,
  total_cards int,
  release_date date,
  logo_url text,
  symbol_url text
);

create table cards (
  id text primary key,
  set_id text references sets(id),
  number text,
  name text not null,
  name_fr text,
  rarity text,
  supertype text,
  types text[],
  image_url text,
  market_price numeric(10, 2),
  api_updated_at timestamptz
);
create index cards_set_idx on cards(set_id);
create index cards_name_idx on cards(lower(name));
create index cards_number_idx on cards(set_id, number);

-- Recherche tolérante : trigramme + suppression des accents (immuable) pour que
-- "Dracaufoeu" ou "Dracaufeu" matchent la même ligne.
create or replace function f_unaccent(t text)
returns text
language sql
immutable
strict
parallel safe
as $$
  select unaccent('unaccent', t);
$$;

create index cards_name_trgm_idx on cards using gin (f_unaccent(lower(name)) gin_trgm_ops);
create index cards_name_fr_trgm_idx on cards using gin (f_unaccent(lower(name_fr)) gin_trgm_ops);

-- Utilisateurs
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username citext unique not null,
  avatar_url text,
  bio text,
  city text,
  country text,
  visibility text not null default 'matches_only'
    check (visibility in ('public', 'matches_only', 'private'))
);

-- Collection
-- La langue fait partie de la clé : un collectionneur peut posséder la même
-- carte en plusieurs éditions (FR/EN/JP) avec des quantités distinctes.
create table collection_items (
  user_id uuid references profiles(id) on delete cascade,
  card_id text references cards(id),
  language text not null default 'fr' check (language in ('fr', 'en', 'de', 'es', 'it', 'jp')),
  quantity_owned int not null default 0 check (quantity_owned >= 0),
  quantity_wanted int not null default 0 check (quantity_wanted >= 0),
  condition text check (condition in ('mint', 'excellent', 'good', 'played')),
  primary key (user_id, card_id, language)
);
create index collection_items_user_idx on collection_items(user_id);
create index idx_owned_dupes on collection_items(user_id)
  where quantity_owned > quantity_wanted;
create index idx_wanted on collection_items(user_id)
  where quantity_wanted > quantity_owned;

-- Thématiques (dossiers)
create table themes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete cascade,
  name text not null
);
create table theme_cards (
  theme_id uuid references themes(id) on delete cascade,
  card_id text references cards(id),
  primary key (theme_id, card_id)
);

-- Échanges
create table trades (
  id uuid primary key default gen_random_uuid(),
  from_user uuid references profiles(id),
  to_user uuid references profiles(id),
  status text not null default 'proposed'
    check (status in ('proposed', 'accepted', 'declined', 'cancelled', 'completed')),
  message text,
  created_at timestamptz default now(),
  completed_at timestamptz
);
create index trades_from_idx on trades(from_user);
create index trades_to_idx on trades(to_user);

create table trade_cards (
  trade_id uuid references trades(id) on delete cascade,
  card_id text references cards(id),
  direction text check (direction in ('offered', 'requested')),
  quantity int not null default 1,
  primary key (trade_id, card_id, direction)
);

-- Réputation
create table trade_feedback (
  trade_id uuid references trades(id) primary key,
  author uuid references profiles(id),
  rating smallint check (rating = 1),
  created_at timestamptz default now()
);

-- Machine à états des échanges (transitions autorisées uniquement) :
--   proposed → accepted | declined (destinataire) ; proposed → cancelled (auteur) ;
--   accepted → completed (participants) ; états terminaux irréversibles.
-- Les policies RLS filtrent QUI peut écrire ; ce trigger garantit QUOI peut changer
-- (statut seul + transition valide). Sans JWT (maintenance/service role) : bypass.
create or replace function trades_guard_transition()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  actor uuid;
begin
  actor := auth.uid();
  if actor is null then
    return new;
  end if;

  if new.from_user<> old.from_user or new.to_user <> old.to_user
     or coalesce(new.message, '') <> coalesce(old.message, '') then
    raise exception 'trades : seuls le statut et completed_at sont modifiables';
  end if;

  if new.status = old.status then
    return new;
  end if;

  if old.status = 'proposed' and new.status in ('accepted', 'declined')
     and actor = new.to_user then
    null;  -- destinataire décide
  elsif old.status = 'proposed' and new.status = 'cancelled'
     and actor = new.from_user then
    null;  -- auteur annule
  elsif old.status = 'accepted' and new.status = 'completed'
     and actor in (new.from_user, new.to_user) then
    null;  -- participants clôturent
  else
    raise exception 'trades : transition % -> % interdite pour cet acteur', old.status, new.status;
  end if;

  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  else
    new.completed_at := null;
  end if;
  return new;
end;
$$;

create trigger trades_transition_guard
before update on trades
for each row execute function trades_guard_transition();

-- Matching : mes doublons ∩ sa wishlist + ses doublons ∩ ma wishlist
create materialized view trade_matches as
select a.user_id as me, b.user_id as other, count(*) as score
from collection_items a
join collection_items b on b.card_id = a.card_id
where a.quantity_owned > a.quantity_wanted
  and b.quantity_wanted > b.quantity_owned
group by a.user_id, b.user_id
union all
select a.user_id, b.user_id, count(*)
from collection_items a
join collection_items b on b.card_id = a.card_id
where b.quantity_owned > b.quantity_wanted
  and a.quantity_wanted > a.quantity_owned
group by a.user_id, b.user_id;

create unique index trade_matches_unique on trade_matches(me, other);
create index trade_matches_me_idx on trade_matches(me);

-- Rafraîchissement de la vue matérialisée : PAS de trigger synchrone.
-- REFRESH ... CONCURRENTLY est interdit à l'intérieur d'une transaction, or un
-- trigger s'exécute dans la transaction de l'écriture : il ferait échouer chaque
-- écriture de collection. Le refresh est donc un job planifié :
--   Option A (Supabase) : activer l'extension pg_cron puis :
--     select cron.schedule('refresh-trade-matches', '*/5 * * * *',
--       $$refresh materialized view concurrently trade_matches$$);
--   Option B : Vercel Cron → appel de l'endpoint de sync (service role).
-- La matview n'a pas besoin d'être temps réel : quelques minutes de retard
-- sur les matches sont acceptables (cf. spec §10.6).

-- Historique des prix (alimenté par le job de synchronisation quotidien ;
-- cards.market_price reste le dernier point pour l'affichage rapide).
-- Dimension "variant" : les sources exposent des prix par variant (PokéTCG API :
-- normal / holofoil / reverseHolofoil). Le "prix vendu" réel n'est pas exposé par
-- les sources publiques : il viendra des transactions de notre marketplace (Phase 3).
create table card_prices (
  card_id text references cards(id) on delete cascade,
  source text not null,
  variant text not null default 'normal',
  recorded_at date not null,
  price numeric(10, 2) not null,
  currency text not null default 'EUR',
  primary key (card_id, source, variant, recorded_at)
);
create index card_prices_card_idx on card_prices(card_id, recorded_at desc);

-- Jeux (verticaux TCG) : Pokémon en MVP, extension Magic / Yu-Gi-Oh! / One Piece… (cf. spec §1, Phase 4)
create table games (
  id text primary key,
  name text not null,
  enabled boolean not null default false
);
insert into games (id, name, enabled) values ('pokemon', 'Pokémon JCC', true);

-- ---------------------------------------------------------------- RLS
alter table profiles enable row level security;
alter table collection_items enable row level security;
alter table themes enable row level security;
alter table theme_cards enable row level security;
alter table trades enable row level security;
alter table trade_cards enable row level security;
alter table trade_feedback enable row level security;

alter table sets enable row level security;
alter table cards enable row level security;
alter table games enable row level security;

create policy "games readable" on games for select using (true);
create policy "sets readable" on sets for select using (true);
create policy "cards readable" on cards for select using (true);
-- card_prices : lecture publique, écriture réservée au service role (job de sync)
alter table card_prices enable row level security;
create policy "prices readable" on card_prices for select using (true);

create policy "profiles self update" on profiles for update using (auth.uid() = id);
create policy "profiles insert self" on profiles for insert with check (auth.uid() = id);
create policy "profiles read non private" on profiles
  for select using (visibility <> 'private' or auth.uid() = id);

create policy "collection owner select" on collection_items
  for select using (auth.uid() = user_id);
create policy "collection owner write" on collection_items
  for insert with check (auth.uid() = user_id);
create policy "collection owner update" on collection_items
  for update using (auth.uid() = user_id);
create policy "collection owner delete" on collection_items
  for delete using (auth.uid() = user_id);

create policy "themes owner all" on themes
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "theme cards via theme" on theme_cards
  for all using (
    exists (select 1 from themes t where t.id = theme_id and t.user_id = auth.uid())
  ) with check (
    exists (select 1 from themes t where t.id = theme_id and t.user_id = auth.uid())
  );

create policy "trades participant select" on trades
  for select using (auth.uid() in (from_user, to_user));
create policy "trades author insert" on trades
  for insert with check (auth.uid() = from_user);
create policy "trades recipient decide" on trades
  for update
  using (auth.uid() = to_user and status = 'proposed')
  with check (auth.uid() = to_user and status in ('accepted', 'declined'));
create policy "trades author cancel" on trades
  for update
  using (auth.uid() = from_user and status = 'proposed')
  with check (auth.uid() = from_user and status = 'cancelled');
create policy "trades participants complete" on trades
  for update
  using (auth.uid() in (from_user, to_user) and status = 'accepted')
  with check (auth.uid() in (from_user, to_user) and status = 'completed');

create policy "trade cards participant select" on trade_cards
  for select using (
    exists (
      select 1 from trades t
      where t.id = trade_id and auth.uid() in (t.from_user, t.to_user)
    )
  );
create policy "trade cards author write" on trade_cards
  for insert with check (
    exists (select 1 from trades t where t.id = trade_id and t.from_user = auth.uid())
  );

create policy "feedback trade insert" on trade_feedback
  for insert with check (
    author = auth.uid()
    and exists (
      select 1 from trades t
      where t.id = trade_id and t.status = 'completed'
        and auth.uid() in (t.from_user, t.to_user) and t.from_user <> author
    )
  );
