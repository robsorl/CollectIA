-- Correctif ponctuel pour une base où 0001_init.sql (version PR #4, cd20278) a
-- DÉJÀ été appliqué : le durcissement trade_cards de la PR #5 arrive après coup.
-- Après la PR #5, une base neuve fait tout en une seule migration — ce fichier
-- ne sert que pour mettre à jour l'instance existante (kutnkduubllkzcorlelj).

-- 1) Historique des cartes figé dès la première décision (policy restreinte)
drop policy "trade cards author write" on trade_cards;
create policy "trade cards author write" on trade_cards
  for insert with check (
    exists (
      select 1 from trades t
      where t.id = trade_id and t.from_user = auth.uid()
        and t.status = 'proposed'
    )
  );

-- 2) Quantité strictement positive
alter table trade_cards drop constraint if exists trade_cards_quantity_check;
alter table trade_cards add constraint trade_cards_quantity_check
  check (quantity > 0) not valid;
alter table trade_cards validate constraint trade_cards_quantity_check;
