-- Expiry sales guard: expired batch units must not be sold.
--
-- Until now checkout (and the other places that sell stock) looked only at products.stock, one number per product. Units in an expired batch stayed inside that
-- number until somebody wrote them off, so they could be ordered; picking then skipped them and left the shortfall as a message.
--
-- Sellable stock = stock minus the units in batches whose expiry date has passed, never below zero. A batch is sellable ON its expiry date and not after,
-- the same rule picking already uses (expiry_date >= current_date). A product with no batches is unchanged. Writing off expired units lowers stock and the
-- expired batch together, so sellable stock does not change when they are written off.
--
-- THREE MODES, held in one row and changed by an administrator without a deployment:
--   off      nothing is checked.
--   observe  (the default) nothing is blocked; every sale that WOULD have been blocked is recorded in expiry_guard_events. The storefront still shows stock as before.
--   enforce  a sale that needs expired units is refused with a message that says why, and the storefront shows the sellable number.
-- (In enforce mode the refused sale rolls back, and with it any record of the attempt; the buyer sees the message. Observe mode is where attempts are counted.)
--
-- WHERE IT APPLIES: marketplace checkout, RFQ awards (whole quote and by line) and back-order shipment dispatch; and the pharmacy storefront, whose catalogue (list_marketplace_catalogue)
-- reports the sellable number as each offer's stock once the guard is enforced, so a pharmacy is never told "available" and then refused. Each is PATCHED in place by exact text, not replaced,
-- because the deployed checkout carries production-only safeguards (see 20261017110000_production_checkout_compatibility.sql). Each fragment must match exactly once
-- or the migration stops and changes nothing. Applying twice is safe.
-- Picking is unchanged: it already skips expired batches.
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The policy (one row) and the record of what the guard saw
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expiry_guard_policy (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  mode TEXT NOT NULL DEFAULT 'observe' CHECK (mode IN ('off', 'observe', 'enforce')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);
INSERT INTO public.expiry_guard_policy (id, mode) VALUES (TRUE, 'observe') ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.expiry_guard_policy ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read the expiry guard policy" ON public.expiry_guard_policy;
CREATE POLICY "Admins read the expiry guard policy" ON public.expiry_guard_policy FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.expiry_guard_policy FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.expiry_guard_policy TO authenticated;

CREATE TABLE IF NOT EXISTS public.expiry_guard_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  entry_point TEXT NOT NULL CHECK (entry_point IN ('checkout', 'rfq_award', 'backorder_shipment')),
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  product_name TEXT NOT NULL,
  wholesaler_id UUID REFERENCES public.businesses(id) ON DELETE SET NULL,
  actor_id UUID,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  stock INTEGER NOT NULL,
  expired_units INTEGER NOT NULL CHECK (expired_units > 0),
  sellable INTEGER NOT NULL CHECK (sellable >= 0)
);
CREATE INDEX IF NOT EXISTS expiry_guard_events_created_idx ON public.expiry_guard_events (created_at DESC);
ALTER TABLE public.expiry_guard_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read expiry guard events" ON public.expiry_guard_events;
CREATE POLICY "Admins read expiry guard events" ON public.expiry_guard_events FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.expiry_guard_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.expiry_guard_events TO authenticated;

CREATE OR REPLACE FUNCTION public.expiry_guard_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Expiry guard events cannot be changed or deleted.';
END;
$$;
DROP TRIGGER IF EXISTS expiry_guard_events_append_only ON public.expiry_guard_events;
CREATE TRIGGER expiry_guard_events_append_only BEFORE UPDATE OR DELETE ON public.expiry_guard_events FOR EACH ROW EXECUTE FUNCTION public.expiry_guard_append_only();
REVOKE ALL ON FUNCTION public.expiry_guard_append_only() FROM PUBLIC, anon, authenticated;

-- The lookup the guard and the storefront both make: only batches that still hold stock.
CREATE INDEX IF NOT EXISTS product_batches_live_expiry_idx ON public.product_batches (product_id, expiry_date) WHERE quantity_on_hand > 0;

-- ---------------------------------------------------------------------------
-- 2. The arithmetic, in one place
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expiry_guard_mode()
RETURNS TEXT
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((SELECT p.mode FROM public.expiry_guard_policy p WHERE p.id), 'off')
$$;
REVOKE ALL ON FUNCTION public.expiry_guard_mode() FROM PUBLIC, anon, authenticated;

-- Units still on hand in batches whose expiry date has passed (the same rule picking uses: a batch is good ON its expiry date).
CREATE OR REPLACE FUNCTION public.expired_units_on_hand(p_product_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(sum(b.quantity_on_hand), 0)::INTEGER
  FROM public.product_batches b
  WHERE b.product_id = p_product_id AND b.quantity_on_hand > 0 AND b.expiry_date < current_date
$$;
REVOKE ALL ON FUNCTION public.expired_units_on_hand(UUID) FROM PUBLIC, anon, authenticated;

-- Called from inside the sale, after the ordinary stock checks, while the product row is locked. p_stock is the stock the sale is being checked against.
CREATE OR REPLACE FUNCTION public._expiry_guard(p_product_id UUID, p_stock INTEGER, p_quantity INTEGER, p_product_name TEXT, p_entry_point TEXT, p_actor UUID DEFAULT auth.uid())
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_mode TEXT := public.expiry_guard_mode();
  v_expired INTEGER;
  v_sellable INTEGER;
BEGIN
  IF v_mode = 'off' OR p_quantity IS NULL OR p_quantity <= 0 THEN RETURN; END IF;
  v_expired := public.expired_units_on_hand(p_product_id);
  IF v_expired = 0 THEN RETURN; END IF;
  v_sellable := GREATEST(COALESCE(p_stock, 0) - v_expired, 0);
  IF p_quantity <= v_sellable THEN RETURN; END IF;

  IF v_mode = 'enforce' THEN
    IF v_sellable = 0 THEN
      RAISE EXCEPTION '% cannot be sold right now: its remaining % unit(s) are past their expiry date.', p_product_name, v_expired;
    END IF;
    RAISE EXCEPTION 'Only % unit(s) of % can be sold: % unit(s) are past their expiry date.', v_sellable, p_product_name, v_expired;
  END IF;

  INSERT INTO public.expiry_guard_events (entry_point, product_id, product_name, wholesaler_id, actor_id, quantity, stock, expired_units, sellable)
  VALUES (p_entry_point, p_product_id, p_product_name, (SELECT p.wholesaler_id FROM public.products p WHERE p.id = p_product_id), p_actor, p_quantity, COALESCE(p_stock, 0), v_expired, v_sellable);
END;
$$;
REVOKE ALL ON FUNCTION public._expiry_guard(UUID, INTEGER, INTEGER, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. What the screens read: computed columns on products
-- ---------------------------------------------------------------------------
-- available_stock: what a buyer can order. Equal to stock until the guard is enforced, so observing changes nothing on screen.
CREATE OR REPLACE FUNCTION public.available_stock(p public.products)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN public.expiry_guard_mode() = 'enforce' THEN GREATEST(p.stock - public.expired_units_on_hand(p.id), 0) ELSE p.stock END
$$;
REVOKE ALL ON FUNCTION public.available_stock(public.products) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.available_stock(public.products) TO authenticated;

-- expired_stock: units past their date. Only the product's own staff (and administrators) are told; everyone else gets nothing.
CREATE OR REPLACE FUNCTION public.expired_stock(p public.products)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN public.has_role(auth.uid(), 'admin') OR public.can_act_for_business(p.wholesaler_id, 'process') THEN public.expired_units_on_hand(p.id) ELSE NULL END
$$;
REVOKE ALL ON FUNCTION public.expired_stock(public.products) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.expired_stock(public.products) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Administrator controls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_expiry_guard_status(p_limit INTEGER DEFAULT 20)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Administrators only.'; END IF;
  RETURN jsonb_build_object(
    'mode', public.expiry_guard_mode(),
    'changed_at', (SELECT updated_at FROM public.expiry_guard_policy WHERE id),
    'products_with_expired_units', (SELECT count(DISTINCT b.product_id) FROM public.product_batches b WHERE b.quantity_on_hand > 0 AND b.expiry_date < current_date),
    'expired_units', COALESCE((SELECT sum(b.quantity_on_hand) FROM public.product_batches b WHERE b.quantity_on_hand > 0 AND b.expiry_date < current_date), 0),
    'orderable_products_with_expired_units', (SELECT count(DISTINCT p.id) FROM public.product_batches b JOIN public.products p ON p.id = b.product_id
                                              WHERE b.quantity_on_hand > 0 AND b.expiry_date < current_date AND p.stock > 0 AND p.active),
    'products_where_batches_exceed_stock', (SELECT count(*) FROM (SELECT p.id FROM public.products p JOIN public.product_batches b ON b.product_id = p.id
                                                                 GROUP BY p.id, p.stock HAVING sum(b.quantity_on_hand) > p.stock) x),
    'would_have_blocked_7_days', (SELECT count(*) FROM public.expiry_guard_events e WHERE e.created_at > now() - interval '7 days'),
    'would_have_blocked_30_days', (SELECT count(*) FROM public.expiry_guard_events e WHERE e.created_at > now() - interval '30 days'),
    'events', COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM (
      SELECT e.created_at, e.entry_point, e.product_name, b.name AS wholesaler_name, e.quantity, e.stock, e.expired_units, e.sellable
      FROM public.expiry_guard_events e LEFT JOIN public.businesses b ON b.id = e.wholesaler_id
      ORDER BY e.created_at DESC LIMIT v_limit) r), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_expiry_guard_status(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_expiry_guard_status(INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_expiry_guard_mode(p_mode TEXT, p_reason TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Administrators only.'; END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('off', 'observe', 'enforce') THEN RAISE EXCEPTION 'Choose off, observe or enforce.'; END IF;
  IF char_length(btrim(COALESCE(p_reason, ''))) < 5 THEN RAISE EXCEPTION 'Give a reason of at least 5 characters.'; END IF;
  SELECT mode INTO v_old FROM public.expiry_guard_policy WHERE id FOR UPDATE;
  UPDATE public.expiry_guard_policy SET mode = p_mode, updated_at = now(), updated_by = auth.uid() WHERE id;
  PERFORM public.write_audit_log('Expiry guard mode changed', 'DrugXOne', 'expiry_guard_policy', NULL, 'Expiry guard',
    jsonb_build_object('previous', v_old, 'new', p_mode, 'reason', btrim(p_reason)));
  RETURN p_mode;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_expiry_guard_mode(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_expiry_guard_mode(TEXT, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Patch the four places that sell stock (each fragment must match exactly once, or nothing changes)
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.patch_function(p_signature TEXT, p_old TEXT[], p_new TEXT[]) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
  definition TEXT;
  hits INTEGER;
  i INTEGER;
  old_text TEXT;
BEGIN
  definition := replace(pg_get_functiondef(p_signature::regprocedure), E'\r', '');
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    old_text := replace(p_old[i], E'\r', '');
    hits := (length(definition) - length(replace(definition, old_text, ''))) / length(old_text);
    IF hits <> 1 THEN
      RAISE EXCEPTION 'Unexpected % body (a fragment matched % times, expected 1); inspect before patching. Fragment starts: %',
        p_signature, hits, left(old_text, 80);
    END IF;
  END LOOP;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    definition := replace(definition, replace(p_old[i], E'\r', ''), replace(p_new[i], E'\r', ''));
  END LOOP;
  EXECUTE definition;
END $$;

DO $migration$
BEGIN
  IF strpos(pg_get_functiondef('public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)'::regprocedure), '_expiry_guard') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)',
      ARRAY[E'    IF v_product.stock < v_product.quantity THEN RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_product.stock, v_product.name; END IF;\n'],
      ARRAY[E'    IF v_product.stock < v_product.quantity THEN RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_product.stock, v_product.name; END IF;\n    PERFORM public._expiry_guard(v_product.id, v_product.stock, v_product.quantity, v_product.name, ''checkout'', _caller_id);\n']);
  END IF;

  IF strpos(pg_get_functiondef('public.award_rfq_quote(uuid,uuid,boolean)'::regprocedure), '_expiry_guard') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.award_rfq_quote(uuid,uuid,boolean)',
      ARRAY[E'    IF v_item.stock < v_item.quantity THEN\n      RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_item.stock, v_item.product_name;\n    END IF;\n'],
      ARRAY[E'    IF v_item.stock < v_item.quantity THEN\n      RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_item.stock, v_item.product_name;\n    END IF;\n    PERFORM public._expiry_guard(v_item.product_id, v_item.stock, v_item.quantity, v_item.product_name, ''rfq_award'');\n']);
  END IF;

  IF strpos(pg_get_functiondef('public.award_rfq_lines(uuid,jsonb,boolean)'::regprocedure), '_expiry_guard') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.award_rfq_lines(uuid,jsonb,boolean)',
      ARRAY[E'      IF v_product.stock < v_line.qty THEN\n        RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_product.stock, v_product.name;\n      END IF;\n'],
      ARRAY[E'      IF v_product.stock < v_line.qty THEN\n        RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_product.stock, v_product.name;\n      END IF;\n      PERFORM public._expiry_guard(v_line.product_id, v_product.stock, v_line.qty, v_product.name, ''rfq_award'');\n']);
  END IF;

  -- The storefront: each offer's stock becomes the sellable number (the plain stock unless the guard is enforced, so observing changes nothing on screen).
  IF strpos(pg_get_functiondef('public.list_marketplace_catalogue()'::regprocedure), 'available_stock') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.list_marketplace_catalogue()',
      ARRAY[E'        SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object(
          ''minimum_order_quantity'', w.minimum_order_quantity,'],
      ARRAY[E'        SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object(
          ''stock'', public.available_stock(p), ''minimum_order_quantity'', w.minimum_order_quantity,']);
  END IF;

  IF strpos(pg_get_functiondef('public.advance_backorder_shipment(uuid,text)'::regprocedure), '_expiry_guard') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.advance_backorder_shipment(uuid,text)',
      ARRAY[E'        IF v_stock < v_line.quantity THEN\n          RAISE EXCEPTION ''Not enough stock of % to dispatch this shipment (% in stock, % needed). Receive the goods into stock first.'',\n            v_line.product_name, v_stock, v_line.quantity;\n        END IF;\n'],
      ARRAY[E'        IF v_stock < v_line.quantity THEN\n          RAISE EXCEPTION ''Not enough stock of % to dispatch this shipment (% in stock, % needed). Receive the goods into stock first.'',\n            v_line.product_name, v_stock, v_line.quantity;\n        END IF;\n        PERFORM public._expiry_guard(v_line.product_id, v_stock, v_line.quantity, v_line.product_name, ''backorder_shipment'');\n']);
  END IF;
END;
$migration$;

COMMIT;
