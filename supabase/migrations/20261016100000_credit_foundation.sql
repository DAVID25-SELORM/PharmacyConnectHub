-- Phase 3: credit foundation.
--
-- 1. The credit LEDGER becomes the single source of truth for how much credit a pharmacy has used
--    with a wholesaler. Until now checkout, list_wholesaler_credit_terms and get_my_credit_terms
--    summed unpaid credit-order TOTALS from `orders`, so a partial payment, a credit note or a
--    write-off freed no credit until an order was fully paid, and the ledger and the limit check
--    could disagree. credit_exposure() is now the one calculation they all use.
-- 2. Cancelling a credit order releases its credit: the ledger gets a credit note for whatever is
--    still outstanding on that order (once; idempotent), instead of leaving the invoice standing.
--    Orders already cancelled when this migration runs are brought into line.
-- 3. A credit relationship now has a status (active / suspended / blocked). A suspended or blocked
--    relationship cannot take NEW credit orders; existing invoices stay payable. "Closed" is the
--    existing `active = false` (revoke). set_credit_status() changes the status with a reason, an
--    audit entry and a notification to the pharmacy.
-- 4. orders.credit_terms_days snapshots the payment-term length a credit order was placed under.
--    Behaviour is unchanged (the due date is still order date + terms); the snapshot just means the
--    due-date basis can be changed later without losing what was agreed.
--
-- No back-fill of balances is needed: the ledger already holds an invoice entry for every credit
-- order (20261003110000). The checkout lock is unchanged: every credit checkout for a
-- wholesaler/pharmacy pair takes FOR UPDATE on that pair's wholesaler_credit_terms row, so two
-- simultaneous orders cannot both pass the limit check (proven in credit-concurrency.sh).

ALTER TABLE public.wholesaler_credit_terms
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS status_reason TEXT,
  ADD COLUMN IF NOT EXISTS status_changed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS status_changed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'wholesaler_credit_terms_status_check') THEN
    ALTER TABLE public.wholesaler_credit_terms ADD CONSTRAINT wholesaler_credit_terms_status_check
      CHECK (status IN ('active', 'suspended', 'blocked'));
  END IF;
END $$;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS credit_terms_days INTEGER;

-- A structured marker keeps user-entered adjustment notes out of idempotency decisions.
ALTER TABLE public.credit_ledger_entries
  ADD COLUMN IF NOT EXISTS cancellation_order_id UUID REFERENCES public.orders(id);
CREATE UNIQUE INDEX IF NOT EXISTS credit_ledger_cancellation_order_unique
  ON public.credit_ledger_entries(cancellation_order_id)
  WHERE cancellation_order_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- credit_exposure: what a pharmacy currently owes a wholesaler on credit, from the ledger.
-- Debits (invoices, debit notes, reversed payments) minus credits (payments, credit notes,
-- write-offs, reversed invoices). Floored at zero: an overpayment is not extra credit.
-- Internal helper; callers are SECURITY DEFINER functions that have already authorized the caller.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.credit_exposure(p_wholesaler_id UUID, p_pharmacy_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT GREATEST(COALESCE(SUM(CASE e.direction WHEN 'debit' THEN e.amount_ghs ELSE -e.amount_ghs END), 0), 0)::NUMERIC(12,2)
  FROM public.credit_ledger_entries e
  WHERE e.wholesaler_id = p_wholesaler_id AND e.pharmacy_id = p_pharmacy_id
$$;
REVOKE ALL ON FUNCTION public.credit_exposure(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.credit_exposure(UUID, UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- Cancelling a credit order releases the credit still outstanding on it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_credit_on_order_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_outstanding NUMERIC;
BEGIN
  IF NOT NEW.is_credit_order THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE cancellation_order_id = NEW.id) THEN
    RETURN NEW;
  END IF;
  SELECT COALESCE(SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END), 0)
    INTO v_outstanding FROM public.credit_ledger_entries WHERE order_id = NEW.id;
  IF v_outstanding > 0 THEN
    INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, cancellation_order_id)
    VALUES (NEW.wholesaler_id, NEW.pharmacy_id, NEW.id, 'credit_note', 'credit', v_outstanding, auth.uid(), 'Order cancelled', NEW.id);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.release_credit_on_order_cancel() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_release_credit_on_order_cancel ON public.orders;
CREATE TRIGGER trg_release_credit_on_order_cancel
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW
  WHEN (NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' AND NEW.is_credit_order)
  EXECUTE FUNCTION public.release_credit_on_order_cancel();

-- Bring already-cancelled credit orders into line (idempotent; a no-op when there are none).
INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, note, cancellation_order_id)
SELECT o.wholesaler_id, o.pharmacy_id, o.id, 'credit_note', 'credit', b.outstanding, 'Order cancelled', o.id
FROM public.orders o
JOIN LATERAL (
  SELECT COALESCE(SUM(CASE e.direction WHEN 'debit' THEN e.amount_ghs ELSE -e.amount_ghs END), 0) AS outstanding
  FROM public.credit_ledger_entries e WHERE e.order_id = o.id
) b ON TRUE
WHERE o.is_credit_order AND o.status = 'cancelled' AND b.outstanding > 0
  AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries e WHERE e.cancellation_order_id = o.id);

CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB,
  _credit_wholesaler_ids UUID[] DEFAULT '{}',
  _require_classification BOOLEAN DEFAULT FALSE,
  _settlement_methods JSONB DEFAULT '{}'::JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_requested_count INTEGER;
  v_product RECORD;
  v_wholesaler RECORD;
  v_order_count INTEGER := 0;
  v_order_id UUID;
  v_discount RECORD;
  v_subtotal NUMERIC;
  v_discount_total NUMERIC;
  v_has_discount BOOLEAN;
  v_terms RECORD;
  v_terms_found BOOLEAN;
  v_goods NUMERIC;
  v_fee NUMERIC;
  v_wholesaler_name TEXT;
  v_general_base NUMERIC;
  v_specific_count INTEGER;
  v_use_credit BOOLEAN;
  v_credit RECORD;
  v_credit_found BOOLEAN;
  v_credit_outstanding NUMERIC;
  v_due_date DATE;
  v_procurement_id UUID;
  v_order_category TEXT;
  v_procurement_category TEXT;
  v_order_number TEXT;
  v_unclassified INTEGER;
  v_actor_email TEXT;
  v_method TEXT;
  v_bad_method TEXT;
  v_terms_days INTEGER;
  v_credit_audit JSONB;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN RAISE EXCEPTION 'caller_id and pharmacy_id are required.'; END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'At least one item is required.'; END IF;

  SELECT id, owner_id, type, verification_status, name INTO v_business FROM public.businesses WHERE id = _pharmacy_id;
  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF v_business.verification_status <> 'approved' THEN RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.'; END IF;
  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role INTO v_role FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id AND bs.user_id = _caller_id AND bs.status = 'active' LIMIT 1;
    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.'; END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (product_id UUID PRIMARY KEY, quantity INTEGER NOT NULL CHECK (quantity > 0), purchase_category TEXT) ON COMMIT DROP;
  INSERT INTO tmp_requested_items
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER, (array_agg(raw.category))[1]
  FROM (SELECT (item ->> 'productId')::UUID product_id, (item ->> 'quantity')::INTEGER quantity, NULLIF(btrim(item ->> 'category'), '') category FROM jsonb_array_elements(_items) item) raw
  WHERE raw.product_id IS NOT NULL AND raw.quantity > 0 GROUP BY raw.product_id;
  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN RAISE EXCEPTION 'Each item needs a valid productId and quantity.'; END IF;
  IF EXISTS (SELECT 1 FROM tmp_requested_items WHERE purchase_category IS NOT NULL AND purchase_category NOT IN ('nhis', 'cash_private', 'other')) THEN
    RAISE EXCEPTION 'Invalid purchase category.';
  END IF;
  -- A real checkout must classify every line (the API passes TRUE). Raised before any stock is
  -- reserved, so nothing is held when it fails.
  IF _require_classification THEN
    SELECT COUNT(*) INTO v_unclassified FROM tmp_requested_items WHERE purchase_category IS NULL;
    IF v_unclassified > 0 THEN
      RAISE EXCEPTION '% item(s) still need a purchase classification.', v_unclassified;
    END IF;
  END IF;
  -- Settlement methods: a map of wholesaler id -> method. Validated before any stock is reserved.
  -- Online payment ('pay_now') is refused: no integration exists, and an order must never claim a
  -- payment that was not taken.
  IF _settlement_methods IS NULL THEN _settlement_methods := '{}'::JSONB; END IF;
  IF jsonb_typeof(_settlement_methods) <> 'object' THEN RAISE EXCEPTION 'Payment methods must be a map of supplier to method.'; END IF;
  SELECT m.value INTO v_bad_method FROM jsonb_each_text(_settlement_methods) m
  WHERE m.value NOT IN ('cod', 'credit', 'bank_transfer', 'momo', 'cheque', 'other') LIMIT 1;
  IF v_bad_method IS NOT NULL THEN
    IF v_bad_method = 'pay_now' THEN RAISE EXCEPTION 'Online payment is not available yet. Choose another payment method.'; END IF;
    RAISE EXCEPTION 'Invalid payment method.';
  END IF;
  IF (SELECT COUNT(*) FROM public.products p JOIN tmp_requested_items r ON r.product_id = p.id) <> v_requested_count THEN RAISE EXCEPTION 'One or more products could not be found.'; END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY, wholesaler_id UUID NOT NULL, product_name TEXT NOT NULL,
    base_unit_price_ghs NUMERIC(10,2) NOT NULL, unit_price_ghs NUMERIC(10,2) NOT NULL,
    discount_amount_ghs NUMERIC(10,2) NOT NULL DEFAULT 0, quantity INTEGER NOT NULL CHECK (quantity > 0),
    specific_discount BOOLEAN NOT NULL DEFAULT FALSE, discount_source TEXT, purchase_category TEXT
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT p.id, p.name, p.price_ghs, p.stock, p.active, p.wholesaler_id, b.name wholesaler_name,
      b.verification_status wholesaler_status, r.quantity, r.purchase_category,
      COALESCE(wp.minimum_order_quantity, 1) AS min_qty
    FROM tmp_requested_items r JOIN public.products p ON p.id = r.product_id JOIN public.businesses b ON b.id = p.wholesaler_id
    LEFT JOIN public.wholesaler_products wp ON wp.id = p.id
    FOR UPDATE OF p
  LOOP
    IF NOT v_product.active THEN RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name; END IF;
    IF v_product.wholesaler_status <> 'approved' THEN RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name; END IF;
    IF v_product.stock <= 0 THEN RAISE EXCEPTION '% is currently out of stock.', v_product.name; END IF;
    IF v_product.stock < v_product.quantity THEN RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name; END IF;
    IF v_product.quantity < v_product.min_qty THEN RAISE EXCEPTION 'The minimum order for % is % unit(s).', v_product.name, v_product.min_qty; END IF;
    UPDATE public.products SET stock = stock - v_product.quantity WHERE id = v_product.id;
    INSERT INTO tmp_locked_products(product_id, wholesaler_id, product_name, base_unit_price_ghs, unit_price_ghs, quantity, purchase_category)
    VALUES (v_product.id, v_product.wholesaler_id, v_product.name, v_product.price_ghs, v_product.price_ghs, v_product.quantity, v_product.purchase_category);
  END LOOP;

  UPDATE tmp_locked_products t
  SET unit_price_ghs = round(t.base_unit_price_ghs * (1 - r.pct / 100), 2),
      discount_amount_ghs = round((t.base_unit_price_ghs - round(t.base_unit_price_ghs * (1 - r.pct / 100), 2)) * t.quantity, 2),
      specific_discount = TRUE,
      discount_source = 'product'
  FROM (
    SELECT DISTINCT ON (x.product_id) x.product_id, d.discount_percent AS pct
    FROM tmp_locked_products x
    JOIN public.product_discounts d
      ON d.product_id = x.product_id AND d.wholesaler_id = x.wholesaler_id AND x.quantity >= d.min_quantity
    WHERE d.pharmacy_id = _pharmacy_id AND d.active AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now())
    ORDER BY x.product_id, d.discount_percent DESC, d.min_quantity DESC, d.created_at DESC
  ) r
  WHERE r.product_id = t.product_id;

  INSERT INTO public.procurements(pharmacy_id) VALUES (_pharmacy_id) RETURNING id INTO v_procurement_id;

  FOR v_wholesaler IN SELECT wholesaler_id FROM tmp_locked_products GROUP BY wholesaler_id LOOP
    SELECT SUM(base_unit_price_ghs * quantity) INTO v_subtotal FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    SELECT d.* INTO v_discount FROM public.customer_discounts d
    WHERE d.wholesaler_id = v_wholesaler.wholesaler_id AND d.pharmacy_id = _pharmacy_id AND d.active
      AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now()) AND v_subtotal >= d.minimum_order_value
    ORDER BY d.starts_at DESC, d.created_at DESC LIMIT 1;
    v_has_discount := FOUND;

    SELECT COALESCE(SUM(base_unit_price_ghs * quantity) FILTER (WHERE NOT specific_discount), 0), COUNT(*) FILTER (WHERE specific_discount)
      INTO v_general_base, v_specific_count
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    IF v_has_discount AND v_general_base = 0 THEN v_has_discount := FALSE; END IF;

    IF v_has_discount THEN
      IF v_discount.discount_type = 'percentage' THEN
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2)) * quantity, 2),
          discount_source = 'customer'
        WHERE wholesaler_id = v_wholesaler.wholesaler_id AND NOT specific_discount;
      ELSE
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / v_general_base * LEAST(v_discount.discount_amount, v_general_base)) / quantity, 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / v_general_base * LEAST(v_discount.discount_amount, v_general_base)) / quantity, 2)) * quantity, 2),
          discount_source = 'customer'
        WHERE wholesaler_id = v_wholesaler.wholesaler_id AND NOT specific_discount;
      END IF;
    END IF;

    SELECT COALESCE(SUM(discount_amount_ghs), 0) INTO v_discount_total FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    v_goods := v_subtotal - v_discount_total;
    SELECT t.min_order_value_ghs, t.delivery_fee_ghs, t.free_delivery_threshold_ghs INTO v_terms
    FROM public.wholesaler_order_terms t WHERE t.wholesaler_id = v_wholesaler.wholesaler_id;
    v_terms_found := FOUND;
    v_fee := 0;
    IF v_terms_found THEN
      IF v_terms.min_order_value_ghs > 0 AND v_goods < v_terms.min_order_value_ghs THEN
        SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wholesaler.wholesaler_id;
        RAISE EXCEPTION '% requires a minimum order of GHS % (your order with them is GHS %).',
          v_wholesaler_name, to_char(v_terms.min_order_value_ghs, 'FM999,999,990.00'), to_char(v_goods, 'FM999,999,990.00');
      END IF;
      IF v_terms.delivery_fee_ghs > 0
         AND NOT (v_terms.free_delivery_threshold_ghs IS NOT NULL AND v_goods >= v_terms.free_delivery_threshold_ghs) THEN
        v_fee := v_terms.delivery_fee_ghs;
      END IF;
    END IF;
    -- This supplier's payment method: the explicit choice, else credit if the legacy credit list
    -- names them, else cash on delivery. A credit request that contradicts the chosen method is an
    -- error rather than a silent pick.
    v_method := NULLIF(_settlement_methods ->> v_wholesaler.wholesaler_id::TEXT, '');
    IF v_method IS NULL THEN
      v_method := CASE WHEN v_wholesaler.wholesaler_id = ANY (COALESCE(_credit_wholesaler_ids, '{}')) THEN 'credit' ELSE 'cod' END;
    ELSIF v_wholesaler.wholesaler_id = ANY (COALESCE(_credit_wholesaler_ids, '{}')) AND v_method <> 'credit' THEN
      SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wholesaler.wholesaler_id;
      RAISE EXCEPTION 'Conflicting payment method for %: credit was requested but another method was chosen.', v_wholesaler_name;
    END IF;
    v_use_credit := v_method = 'credit';
    v_due_date := NULL;
    v_terms_days := NULL;
    v_credit_audit := NULL;
    IF v_use_credit THEN
      -- The row lock below serializes every credit checkout for this wholesaler/pharmacy pair: a
      -- second order waits here until the first commits, then sees the first order's ledger invoice
      -- in the exposure, so two orders cannot both fit into the same remaining credit.
      SELECT c.credit_limit_ghs, c.payment_terms_days, c.active, c.status INTO v_credit
      FROM public.wholesaler_credit_terms c
      WHERE c.wholesaler_id = v_wholesaler.wholesaler_id AND c.pharmacy_id = _pharmacy_id
      FOR UPDATE;
      v_credit_found := FOUND AND v_credit.active;
      SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wholesaler.wholesaler_id;
      IF NOT v_credit_found THEN
        RAISE EXCEPTION '% has not approved credit for your pharmacy.', v_wholesaler_name;
      END IF;
      IF v_credit.status = 'suspended' THEN
        RAISE EXCEPTION '% has suspended credit for your pharmacy. Choose another payment method.', v_wholesaler_name;
      ELSIF v_credit.status = 'blocked' THEN
        RAISE EXCEPTION 'Credit with % is blocked for your pharmacy. Choose another payment method.', v_wholesaler_name;
      END IF;
      v_credit_outstanding := public.credit_exposure(v_wholesaler.wholesaler_id, _pharmacy_id);
      IF v_credit_outstanding + v_goods + v_fee > v_credit.credit_limit_ghs THEN
        RAISE EXCEPTION 'Using credit with % would exceed your approved limit of GHS % (you currently owe GHS %, this order is GHS %).',
          v_wholesaler_name, to_char(v_credit.credit_limit_ghs, 'FM999,999,990.00'), to_char(v_credit_outstanding, 'FM999,999,990.00'), to_char(v_goods + v_fee, 'FM999,999,990.00');
      END IF;
      v_terms_days := v_credit.payment_terms_days;
      v_due_date := (now() + make_interval(days => v_credit.payment_terms_days))::DATE;
      -- Built here, not in the audit call: v_credit is only assigned on this branch, and PL/pgSQL
      -- would fail on a cash-on-delivery order if the audit expression touched it.
      v_credit_audit := jsonb_build_object(
        'limit_ghs', v_credit.credit_limit_ghs,
        'exposure_before_ghs', v_credit_outstanding,
        'order_ghs', v_goods + v_fee,
        'exposure_after_ghs', v_credit_outstanding + v_goods + v_fee,
        'available_after_ghs', v_credit.credit_limit_ghs - (v_credit_outstanding + v_goods + v_fee),
        'terms_days', v_terms_days);
    END IF;

    -- Order-level purchase category, derived from this wholesaler's own slice of items: all-NULL
    -- stays NULL (unclassified, e.g. every pre-existing caller of this function), all-the-same
    -- non-null value wins outright, anything else (including a mix of classified/unclassified) is 'mixed'.
    SELECT CASE
      WHEN bool_and(purchase_category IS NULL) THEN NULL
      WHEN COUNT(DISTINCT purchase_category) = 1 AND bool_and(purchase_category IS NOT NULL) THEN MIN(purchase_category)
      ELSE 'mixed'
    END INTO v_order_category FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_type, discount_rate, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_due_date, procurement_id, purchase_category, settlement_method, credit_terms_days)
    VALUES (_pharmacy_id, v_wholesaler.wholesaler_id, v_subtotal,
      CASE WHEN v_has_discount THEN v_discount.discount_type WHEN v_specific_count > 0 THEN 'product' ELSE NULL END,
      CASE WHEN v_has_discount THEN COALESCE(v_discount.discount_percent, v_discount.discount_amount) ELSE NULL END,
      v_discount_total, v_fee, v_goods + v_fee, 'cod', v_use_credit, v_due_date, v_procurement_id, v_order_category, v_method, v_terms_days)
      RETURNING id, order_number INTO v_order_id, v_order_number;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source, purchase_category)
    SELECT v_order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source, purchase_category
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    -- Audit the classification this order was submitted with (value and line count per class).
    SELECT email INTO v_actor_email FROM auth.users WHERE id = _caller_id;
    PERFORM public.write_audit_log(
      'Order classification recorded', v_business.name, 'order', v_order_id, v_order_number,
      jsonb_build_object(
        'purchase_category', v_order_category,
        'classification_required', _require_classification,
        'settlement_method', v_method,
        'payment_status', 'unpaid',
        'credit_due_date', v_due_date,
        'credit', v_credit_audit,
        'lines', (SELECT COUNT(*) FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id),
        'by_classification', COALESCE((
          SELECT jsonb_object_agg(COALESCE(t.purchase_category, 'unclassified'),
            jsonb_build_object('lines', t.line_count, 'value_ghs', t.line_value))
          FROM (
            SELECT purchase_category, COUNT(*) AS line_count, round(SUM(unit_price_ghs * quantity), 2) AS line_value
            FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id GROUP BY purchase_category
          ) t
        ), '{}'::JSONB)),
      _caller_id, v_actor_email, NULL, _pharmacy_id);

    IF v_use_credit THEN
      INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
      VALUES (v_wholesaler.wholesaler_id, _pharmacy_id, v_order_id, 'invoice', 'debit', v_goods + v_fee, _caller_id);
    END IF;

    v_order_count := v_order_count + 1;
  END LOOP;

  SELECT CASE
    WHEN bool_and(purchase_category IS NULL) THEN NULL
    WHEN COUNT(DISTINCT purchase_category) = 1 AND bool_and(purchase_category IS NOT NULL) THEN MIN(purchase_category)
    ELSE 'mixed'
  END INTO v_procurement_category FROM tmp_locked_products;
  UPDATE public.procurements SET purchase_category = v_procurement_category WHERE id = v_procurement_id;

  RETURN v_order_count;
END;
$$;

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN, JSONB) TO service_role;

-- ---------------------------------------------------------------------------
-- Readers: same shape as before plus the relationship status, with exposure taken from the ledger.
-- (Return types change, so the old functions are dropped first.)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_wholesaler_credit_terms(UUID);
CREATE FUNCTION public.list_wholesaler_credit_terms(p_wholesaler_id UUID)
RETURNS TABLE(
  pharmacy_id UUID, pharmacy_name TEXT, credit_limit_ghs NUMERIC, payment_terms_days INTEGER,
  outstanding_ghs NUMERIC, available_ghs NUMERIC, internal_note TEXT, updated_at TIMESTAMPTZ,
  status TEXT, status_reason TEXT, status_changed_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may view credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.pharmacy_id, ph.name, c.credit_limit_ghs, c.payment_terms_days,
    public.credit_exposure(c.wholesaler_id, c.pharmacy_id),
    GREATEST(c.credit_limit_ghs - public.credit_exposure(c.wholesaler_id, c.pharmacy_id), 0::NUMERIC),
    c.internal_note, c.updated_at, c.status, c.status_reason, c.status_changed_at
  FROM public.wholesaler_credit_terms c
  JOIN public.businesses ph ON ph.id = c.pharmacy_id
  WHERE c.wholesaler_id = p_wholesaler_id AND c.active
  ORDER BY ph.name;
END;
$$;
REVOKE ALL ON FUNCTION public.list_wholesaler_credit_terms(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_wholesaler_credit_terms(UUID) TO authenticated;

DROP FUNCTION IF EXISTS public.get_my_credit_terms(UUID, UUID);
CREATE FUNCTION public.get_my_credit_terms(p_pharmacy_id UUID, p_wholesaler_id UUID DEFAULT NULL)
RETURNS TABLE(
  wholesaler_id UUID, credit_limit_ghs NUMERIC, payment_terms_days INTEGER,
  outstanding_ghs NUMERIC, available_ghs NUMERIC, status TEXT
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_pharmacy_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.wholesaler_id, c.credit_limit_ghs, c.payment_terms_days,
    public.credit_exposure(c.wholesaler_id, c.pharmacy_id),
    GREATEST(c.credit_limit_ghs - public.credit_exposure(c.wholesaler_id, c.pharmacy_id), 0::NUMERIC),
    c.status
  FROM public.wholesaler_credit_terms c
  WHERE c.pharmacy_id = p_pharmacy_id AND c.active
    AND (p_wholesaler_id IS NULL OR c.wholesaler_id = p_wholesaler_id);
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_credit_terms(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_credit_terms(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Suspend, block or reactivate a pharmacy's credit with one wholesaler.
--   suspended: no NEW credit orders (temporary; e.g. while an overdue invoice is chased)
--   blocked:   no NEW credit orders (a stronger, deliberate stop)
--   active:    credit usable again
-- Existing invoices are untouched and stay payable. Owner / manager of the wholesaler only; a
-- reason (5-500 characters) is required each time; the change is audited (before/after, reason,
-- role, actor) and the pharmacy is notified. A closed (revoked) line can't be changed here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_credit_status(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_status TEXT,
  p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
  v_line RECORD;
  v_org TEXT;
  v_pharmacy TEXT;
  v_role TEXT;
  v_activity TEXT;
  v_actor_email TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('active', 'suspended', 'blocked') THEN
    RAISE EXCEPTION 'Invalid credit status.';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A reason of 5 to 500 characters is required to change a credit status.';
  END IF;

  SELECT * INTO v_line FROM public.wholesaler_credit_terms
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id FOR UPDATE;
  IF NOT FOUND OR NOT v_line.active THEN RAISE EXCEPTION 'No active credit line for this pharmacy.'; END IF;
  IF v_line.status = p_status THEN RAISE EXCEPTION 'This credit line is already %.', p_status; END IF;

  UPDATE public.wholesaler_credit_terms
  SET status = p_status, status_reason = v_reason, status_changed_at = now(), status_changed_by = auth.uid(), updated_by = auth.uid()
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id;

  SELECT name INTO v_org FROM public.businesses WHERE id = p_wholesaler_id;
  SELECT name INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id;
  v_role := CASE WHEN EXISTS (SELECT 1 FROM public.businesses WHERE id = p_wholesaler_id AND owner_id = auth.uid())
    THEN 'owner' ELSE public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT END;
  v_activity := CASE p_status WHEN 'suspended' THEN 'Credit account suspended'
    WHEN 'blocked' THEN 'Credit account blocked' ELSE 'Credit account reactivated' END;
  SELECT email INTO v_actor_email FROM auth.users WHERE id = auth.uid();
  PERFORM public.write_audit_log(
    v_activity, v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object(
      'from', v_line.status, 'to', p_status, 'reason', v_reason, 'actor_role', v_role,
      'credit_limit_ghs', v_line.credit_limit_ghs,
      'exposure_ghs', public.credit_exposure(p_wholesaler_id, p_pharmacy_id)),
    auth.uid(), v_actor_email, NULL, p_wholesaler_id);

  BEGIN
    PERFORM public.notify_business(p_pharmacy_id, ARRAY['owner', 'manager', 'accountant'], 'credit_status',
      CASE p_status WHEN 'active' THEN 'Credit reactivated' WHEN 'suspended' THEN 'Credit suspended' ELSE 'Credit blocked' END,
      CASE p_status
        WHEN 'active' THEN v_org || ' has reactivated your credit account.'
        ELSE v_org || ' has ' || CASE p_status WHEN 'suspended' THEN 'suspended' ELSE 'blocked' END
          || ' new credit orders for your pharmacy. Existing invoices are unaffected. Reason: ' || v_reason
      END,
      '/pharmacy?tab=credit', jsonb_build_object('wholesaler_id', p_wholesaler_id, 'status', p_status));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'set_credit_status notification failed: %', SQLERRM;
  END;
END;
$$;
REVOKE ALL ON FUNCTION public.set_credit_status(UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_credit_status(UUID, UUID, TEXT, TEXT) TO authenticated;
