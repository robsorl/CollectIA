-- 0003 — Durcissement trade_cards pour l'INSTANCE EXISTANTE (kutnkduubllkzcorlelj)
--
-- Contexte : cette instance a reçu 0001_init.sql en version PR #4 (cd20278),
-- qui ne contenait pas les deux durcissements trade_cards de la PR #5.
-- Le hotfix initial (0001_hotfix_trade_cards.sql) a été fusionné dans la
-- 0001 consolidée puis supprimé ; ce fichier matérialise le correctif
-- appliqué sur l'instance le 20/11 (audit v9, échec S12 détecté sur le
-- projet réel : insert dans trade_cards toléré après clôture).
--
-- Une base NEUVE n'a pas besoin de ce fichier : sa 0001 consolidée contient
-- déjà la policy restreinte et la contrainte CHECK.

-- 1) Historique des cartes figé dès la première décision (policy restreinte)
drop policy if exists "trade cards author write" on trade_cards;
create policy "trade cards author write" on trade_cards
  for insert with check (
    exists (
      select 1 from trades t
      where t.id = trade_id and t.from_user = auth.uid()
        and t.status = 'proposed'
    )
  );

-- 2) Quantité strictement positive (NOT VALID puis VALIDATE pour contrôler
--    explicitement les données existantes)
alter table trade_cards drop constraint if exists trade_cards_quantity_check;
alter table trade_cards add constraint trade_cards_quantity_check
  check (quantity > 0) not valid;
alter table trade_cards validate constraint trade_cards_quantity_check;
