-- Let the purchase classification of an existing order line be changed (and ONLY that).
--
-- Production guards order lines with phase0_order_item_integrity(): historical lines are immutable, so ANY update or
-- delete raises "Historical order items are immutable." The "change purchase classification" feature
-- (change_order_item_classification, migration 20261014100000) updates order_items.purchase_category on an existing
-- order, so under that guard it can never succeed in production. The classification is the one line field that is
-- legitimately corrected after the fact (NHIS claim approved, reclassification requested by the pharmacy); the
-- function already records who changed it, why, and the before/after, in the audit log.
--
-- This patches the guard IN PLACE from its live definition. An UPDATE is now allowed only when every column other
-- than purchase_category is unchanged; quantities, prices, products, discounts and the order they belong to stay
-- immutable, and deletes stay refused. If the live function is not exactly what this migration expects, it stops
-- and changes nothing. Where the guard does not exist (a database without it) it does nothing.

DO $$
DECLARE
  v_def TEXT;
  v_old TEXT := 'IF TG_OP <> ''INSERT'' THEN RAISE EXCEPTION ''Historical order items are immutable.''; END IF;';
  v_new TEXT := 'IF TG_OP = ''UPDATE'' AND (to_jsonb(NEW) - ''purchase_category'') IS NOT DISTINCT FROM (to_jsonb(OLD) - ''purchase_category'') THEN RETURN NEW; END IF;'
    || E'\n  ' || 'IF TG_OP <> ''INSERT'' THEN RAISE EXCEPTION ''Historical order items are immutable.''; END IF;';
  v_count INTEGER;
BEGIN
  IF to_regprocedure('public.phase0_order_item_integrity()') IS NULL THEN
    RETURN;
  END IF;
  v_def := replace(pg_get_functiondef('public.phase0_order_item_integrity()'::regprocedure), E'\r', '');
  IF position('(to_jsonb(NEW) - ''purchase_category'')' IN v_def) > 0 THEN
    RETURN; -- already patched
  END IF;
  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Unexpected order-item guard (expected one immutability check, found %). Nothing was changed.', v_count;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;
