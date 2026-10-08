-- Production stock mechanism, as reproduced by production-stock-fixture.sql (read from the production catalog,
-- 8 Oct 2026). These checks document how production behaves today so every new feature is tested against it:
--   * checkout deducts stock, writes deduction evidence and an inventory movement (through the context row);
--   * a cancellation restores the full deduction exactly once, and refuses a legacy order with no evidence;
--   * every other stock change is recorded as an admin adjustment unless a context row says otherwise;
--   * order lines are immutable (insert-only, pending orders only);
--   * existing features that edit order lines must still work under that guard (classification changes).
-- Run after setup.sql + migrations, with production-guard-fixture.sql and production-stock-fixture.sql installed and the
-- checkout compatibility migration (20261017110000) re-applied.
-- Successful create_marketplace_orders calls are top-level statements (ON COMMIT DROP temp tables).
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
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
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'PS Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.ps AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='PS Item') p_item;
CREATE TABLE zz.ps_orders(label TEXT PRIMARY KEY, order_id UUID);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.ps), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.ps)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;

SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ps), (SELECT good FROM zz.ps),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ps), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ps)::text, 'cod')) AS r \gset c1_
INSERT INTO zz.ps_orders SELECT 'checkout', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- 1. Checkout.
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout'); p UUID := (SELECT p_item FROM zz.ps);
BEGIN
  PERFORM zz.check('checkout deducted 5 units (1000 -> 995)', (SELECT stock = 995 FROM public.products WHERE id = p));
  PERFORM zz.check('checkout wrote the deduction evidence (order, product, 5, not restored)',
    (SELECT count(*) = 1 AND bool_and(quantity = 5 AND restored_at IS NULL) FROM public.order_stock_deductions WHERE order_id = o AND product_id = p));
  PERFORM zz.check('checkout recorded a "checkout_deduction" inventory movement of -5 with the order attached',
    (SELECT count(*) = 1 AND bool_and(quantity_delta = -5 AND quantity_before = 1000 AND quantity_after = 995) FROM public.inventory_movements WHERE order_id = o AND product_id = p AND movement_type = 'checkout_deduction'));
  PERFORM zz.check('the inventory context row is removed again once checkout is done', NOT EXISTS (SELECT 1 FROM public.inventory_operation_context));
END $$;

-- 2. A plain stock change without a context row is an admin adjustment.
UPDATE public.products SET stock = stock + 3 WHERE id = (SELECT p_item FROM zz.ps);
DO $$
BEGIN
  PERFORM zz.check('a stock change with no context row is recorded as an "admin_adjustment" (+3)',
    EXISTS (SELECT 1 FROM public.inventory_movements WHERE product_id = (SELECT p_item FROM zz.ps) AND movement_type = 'admin_adjustment' AND quantity_delta = 3));
  PERFORM zz.check('and the movement CHECK only allows the nine known movement types',
    NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inventory_movements_movement_type_check' AND pg_get_constraintdef(oid) LIKE '%order_amendment_release%'));
END $$;
UPDATE public.products SET stock = stock - 3 WHERE id = (SELECT p_item FROM zz.ps);

-- 3. Order lines are immutable.
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout'); item UUID := (SELECT id FROM public.order_items WHERE order_id = (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout') LIMIT 1);
BEGIN
  BEGIN
    UPDATE public.order_items SET quantity = 4 WHERE id = item;
    PERFORM zz.check('an order line cannot be updated', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('an order line cannot be updated', SQLERRM = 'Historical order items are immutable.', SQLERRM);
  END;
  BEGIN
    DELETE FROM public.order_items WHERE id = item;
    PERFORM zz.check('an order line cannot be deleted', FALSE, 'delete allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('an order line cannot be deleted', SQLERRM = 'Historical order items are immutable.', SQLERRM);
  END;
END $$;

-- 4. Existing features must still work under that guard: changing a line's purchase classification.
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout'); item UUID := (SELECT id FROM public.order_items WHERE order_id = (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout') LIMIT 1); r TEXT;
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ps), format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Claim approved by NHIA'')::text', item));
  PERFORM zz.check('the pharmacy owner can change a line''s classification on an existing order (the feature we shipped)', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('and only the classification changed (quantity and price are untouched)',
    (SELECT purchase_category = 'nhis' AND quantity = 5 AND unit_price_ghs = 100 FROM public.order_items WHERE id = item));
END $$;

-- 5. Cancellation restores the full deduction exactly once.
UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'test' WHERE id = (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout');
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout'); p UUID := (SELECT p_item FROM zz.ps);
BEGIN
  PERFORM zz.check('cancelling restored the 5 units (back to 1000)', (SELECT stock = 1000 FROM public.products WHERE id = p));
  PERFORM zz.check('the evidence row is stamped restored', (SELECT restored_at IS NOT NULL FROM public.order_stock_deductions WHERE order_id = o AND product_id = p));
  PERFORM zz.check('one "order_cancellation_restore" movement of +5 was recorded',
    (SELECT count(*) = 1 AND bool_and(quantity_delta = 5) FROM public.inventory_movements WHERE order_id = o AND product_id = p AND movement_type = 'order_cancellation_restore'));
  BEGIN
    INSERT INTO public.inventory_movements(product_id, wholesaler_id, order_id, movement_type, quantity_delta, quantity_before, quantity_after, source_operation)
    SELECT p, (SELECT alpha FROM zz.ps), o, 'order_cancellation_restore', 1, 1000, 1001, 'test';
    PERFORM zz.check('a second cancellation restore for the same order and product is impossible (unique index)', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('a second cancellation restore for the same order and product is impossible (unique index)', TRUE);
  END;
END $$;

-- 6. A legacy order (no deduction evidence) cannot be cancelled: manual reconciliation is required.
ALTER TABLE public.orders DISABLE TRIGGER trg_notify_new_order;
INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order)
SELECT good, alpha, 100, 0, 0, 100, 'cod', false FROM zz.ps;
ALTER TABLE public.orders ENABLE TRIGGER trg_notify_new_order;
INSERT INTO zz.ps_orders SELECT 'legacy', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity)
SELECT (SELECT order_id FROM zz.ps_orders WHERE label = 'legacy'), p_item, 'PS Item', 100, 1 FROM zz.ps;
DO $$
BEGIN
  BEGIN
    UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.ps_orders WHERE label = 'legacy');
    PERFORM zz.check('cancelling a legacy order with no deduction evidence is refused', FALSE, 'cancel allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('cancelling a legacy order with no deduction evidence is refused', SQLERRM LIKE 'Legacy order has no verified stock deduction%', SQLERRM);
  END;
  BEGIN
    INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity)
    SELECT (SELECT order_id FROM zz.ps_orders WHERE label = 'checkout'), p_item, 'PS Item', 100, 1 FROM zz.ps;
    PERFORM zz.check('a line cannot be added to an order that is no longer pending', FALSE, 'insert allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('a line cannot be added to an order that is no longer pending', SQLERRM LIKE 'Order product must belong to its wholesaler and a pending order.%', SQLERRM);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
