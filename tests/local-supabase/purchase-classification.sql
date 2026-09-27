-- Purchase classification (NHIS / Cash-Private / Other / derived Mixed) and parent procurement
-- grouping. Run after setup.sql + migrations through
-- 20260928100000_purchase_classification_and_procurements.sql.
--
-- Each create_marketplace_orders call below is its own top-level statement (its own transaction
-- under psql's default autocommit), matching every other test file in this suite - the function's
-- "ON COMMIT DROP" temp tables require that (two calls in the same transaction/DO block collide on
-- them). New orders are identified via a small zz.seen_orders table rather than by ordering on
-- created_at or id: every order created inside one transaction shares the exact same now(), and
-- gen_random_uuid() ids are not chronological.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

CREATE TABLE zz.seen_orders(id UUID PRIMARY KEY);
CREATE TABLE zz.stash(k TEXT PRIMARY KEY, v UUID);

CREATE FUNCTION zz.new_order() RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  SELECT o.id INTO v_id FROM public.orders o WHERE o.id NOT IN (SELECT id FROM zz.seen_orders);
  INSERT INTO zz.seen_orders VALUES (v_id);
  RETURN v_id;
END $$;

CREATE FUNCTION zz.new_orders() RETURNS UUID[] LANGUAGE plpgsql AS $$
DECLARE v_ids UUID[];
BEGIN
  SELECT array_agg(o.id) INTO v_ids FROM public.orders o WHERE o.id NOT IN (SELECT id FROM zz.seen_orders);
  INSERT INTO zz.seen_orders SELECT unnest(v_ids);
  RETURN v_ids;
END $$;

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'PC Metformin', 'Generic', 'Antidiabetic', 'TABLET', '100s', 20, 500, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'PC Vitamin C', 'Generic', 'Supplement', 'TABLET', '30s', 15, 500, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'PC Amlodipine', 'Generic', 'Antihypertensive', 'TABLET', '50s', 25, 500, true FROM zz.b WHERE name='Other Wholesale';
CREATE TABLE zz.pc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='PC Metformin') p_metf,
  (SELECT id FROM public.products WHERE name='PC Vitamin C') p_vitc,
  (SELECT id FROM public.products WHERE name='PC Amlodipine') p_amlo;

-- 1. Fully NHIS order.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 5, 'category', 'nhis')
));
DO $$
DECLARE o_id UUID := zz.new_order();
BEGIN
  PERFORM zz.check('NHIS order: order.purchase_category = nhis', (SELECT purchase_category FROM public.orders WHERE id = o_id) = 'nhis');
  PERFORM zz.check('NHIS order: item.purchase_category = nhis', (SELECT purchase_category FROM public.order_items WHERE order_id = o_id) = 'nhis');
  PERFORM zz.check('NHIS order: procurement.purchase_category = nhis',
    (SELECT p.purchase_category FROM public.procurements p JOIN public.orders o ON o.procurement_id = p.id WHERE o.id = o_id) = 'nhis');
END $$;

-- 2. Fully Cash / Private order.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 3, 'category', 'cash_private')
));
DO $$
DECLARE o_id UUID := zz.new_order();
BEGIN
  PERFORM zz.check('Cash order: order.purchase_category = cash_private', (SELECT purchase_category FROM public.orders WHERE id = o_id) = 'cash_private');
END $$;

-- 3. "Other" order.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 2, 'category', 'other')
));
DO $$
DECLARE o_id UUID := zz.new_order();
BEGIN
  PERFORM zz.check('Other order: order.purchase_category = other', (SELECT purchase_category FROM public.orders WHERE id = o_id) = 'other');
END $$;

-- 4. Mixed order, single wholesaler: two lines, two categories.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 4, 'category', 'nhis'),
  jsonb_build_object('productId', (SELECT p_vitc FROM zz.pc), 'quantity', 1, 'category', 'cash_private')
));
DO $$
DECLARE o_id UUID := zz.new_order();
BEGIN
  PERFORM zz.check('Mixed order: order.purchase_category = mixed', (SELECT purchase_category FROM public.orders WHERE id = o_id) = 'mixed');
  PERFORM zz.check('Mixed order: each line keeps its own category',
    (SELECT array_agg(DISTINCT purchase_category) FROM public.order_items WHERE order_id = o_id) @> ARRAY['nhis','cash_private']::TEXT[]);
  PERFORM zz.check('Mixed order: procurement.purchase_category = mixed',
    (SELECT p.purchase_category FROM public.procurements p JOIN public.orders o ON o.procurement_id = p.id WHERE o.id = o_id) = 'mixed');
END $$;

-- 5. Invalid category value is rejected outright (not silently dropped). Called directly (like
--    steps 1-4) rather than through zz.val_as: this function is only GRANTed to service_role (the
--    API route's admin client), so the "authenticated" role zz.val_as switches to would hit a
--    permission error before ever reaching the category check - that is a separate, deliberate
--    restriction (see checkout1.sql's impersonation probe), not what this check is testing.
DO $$
BEGIN
  PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc),
    jsonb_build_array(jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 1, 'category', 'made_up')));
  PERFORM zz.check('Invalid category is rejected', FALSE);
EXCEPTION WHEN OTHERS THEN
  PERFORM zz.check('Invalid category is rejected', SQLERRM LIKE 'Invalid purchase category%', SQLERRM);
END $$;

-- 6. Omitted category (every pre-existing caller of this function): stays NULL end to end, no
--    error - the backward-compatibility guarantee. Procurement grouping still applies though.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 1)
));
DO $$
DECLARE o_id UUID := zz.new_order();
BEGIN
  PERFORM zz.check('Omitted category: order.purchase_category is NULL', (SELECT purchase_category FROM public.orders WHERE id = o_id) IS NULL);
  PERFORM zz.check('Omitted category: item.purchase_category is NULL', (SELECT purchase_category FROM public.order_items WHERE order_id = o_id) IS NULL);
  PERFORM zz.check('Omitted category: procurement.purchase_category is NULL',
    (SELECT p.purchase_category FROM public.procurements p JOIN public.orders o ON o.procurement_id = p.id WHERE o.id = o_id) IS NULL);
  PERFORM zz.check('Omitted category: procurement was still created (grouping is unconditional)',
    (SELECT o.procurement_id FROM public.orders o WHERE o.id = o_id) IS NOT NULL);
  INSERT INTO zz.stash VALUES ('step6_procurement', (SELECT procurement_id FROM public.orders WHERE id = o_id));
END $$;

-- 7. Procurement reference format + uniqueness across two separate checkout calls (compares
--    against the order created in step 6, the last one seen before this one).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 1, 'category', 'nhis')
));
DO $$
DECLARE o_id UUID := zz.new_order();
DECLARE proc1 UUID;
DECLARE proc2 UUID;
BEGIN
  SELECT o.procurement_id INTO proc2 FROM public.orders o WHERE o.id = o_id;
  SELECT v INTO proc1 FROM zz.stash WHERE k = 'step6_procurement';
  PERFORM zz.check('Two separate checkouts get two different procurements', proc1 IS DISTINCT FROM proc2);
  PERFORM zz.check('Procurement reference follows PUR-###### format',
    (SELECT reference FROM public.procurements WHERE id = proc2) ~ '^PUR-[0-9]{6}$');
END $$;

-- 8. Multi-wholesaler split, all NHIS: both child orders NHIS, one shared procurement.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 2, 'category', 'nhis'),
  jsonb_build_object('productId', (SELECT p_amlo FROM zz.pc), 'quantity', 2, 'category', 'nhis')
));
DO $$
DECLARE new_ids UUID[] := zz.new_orders();
BEGIN
  PERFORM zz.check('Multi-wholesaler cart creates two child orders', array_length(new_ids, 1) = 2);
  PERFORM zz.check('Both child orders share one procurement',
    (SELECT count(DISTINCT procurement_id) FROM public.orders WHERE id = ANY(new_ids)) = 1);
  PERFORM zz.check('Both child orders are NHIS',
    (SELECT bool_and(purchase_category = 'nhis') FROM public.orders WHERE id = ANY(new_ids)));
END $$;

-- 9. Multi-wholesaler split, genuinely mixed: supplier A (Alpha) gets NHIS + Cash (its own order
--    is 'mixed'), supplier B (Other) gets only NHIS (its own order is 'nhis'), and the procurement
--    as a whole is 'mixed' - the exact worked example from the brief.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_metf FROM zz.pc), 'quantity', 2, 'category', 'nhis'),
  jsonb_build_object('productId', (SELECT p_vitc FROM zz.pc), 'quantity', 1, 'category', 'cash_private'),
  jsonb_build_object('productId', (SELECT p_amlo FROM zz.pc), 'quantity', 2, 'category', 'nhis')
));
DO $$
DECLARE new_ids UUID[] := zz.new_orders();
DECLARE proc1 UUID;
BEGIN
  PERFORM zz.check('Split-mixed: Alpha''s order is mixed',
    (SELECT o.purchase_category FROM public.orders o JOIN public.businesses b ON b.id = o.wholesaler_id WHERE o.id = ANY(new_ids) AND b.name = 'Alpha Wholesale') = 'mixed');
  PERFORM zz.check('Split-mixed: Other Wholesale''s order is nhis-only',
    (SELECT o.purchase_category FROM public.orders o JOIN public.businesses b ON b.id = o.wholesaler_id WHERE o.id = ANY(new_ids) AND b.name = 'Other Wholesale') = 'nhis');
  PERFORM zz.check('Split-mixed: the procurement itself is mixed',
    (SELECT DISTINCT p.purchase_category FROM public.procurements p JOIN public.orders o ON o.procurement_id = p.id WHERE o.id = ANY(new_ids)) = 'mixed');

  SELECT procurement_id INTO proc1 FROM public.orders WHERE id = new_ids[1];

  -- 10. RLS: the pharmacy owner can read its own procurement; a different pharmacy cannot; the
  --     fulfilling wholesaler cannot read the procurements table at all (isolation requirement -
  --     a wholesaler must never learn about sibling orders from other suppliers).
  PERFORM zz.check('Pharmacy owner can read its own procurement',
    zz.val_as((SELECT u_po FROM zz.pc), format('SELECT reference FROM public.procurements WHERE id = %L', proc1)) LIKE 'PUR-%');
  PERFORM zz.check('A different pharmacy cannot see it',
    zz.val_as((SELECT u_px FROM zz.pc), format('SELECT count(*)::text FROM public.procurements WHERE id = %L', proc1)) = '0');
  PERFORM zz.check('The fulfilling wholesaler cannot read the procurements table',
    zz.val_as((SELECT u_wo FROM zz.pc), format('SELECT count(*)::text FROM public.procurements WHERE id = %L', proc1)) = '0');
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
