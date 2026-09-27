-- Pharmacy saved carts and a persisted "draft" cart.
--
-- Two kinds of row in the same table, told apart by `name`:
--   * name IS NULL   -> the pharmacy's one active draft: the in-progress cart, synced automatically
--                       as the user shops, so it survives a refresh, a closed tab or a different
--                       device. Shared by the whole pharmacy team (last write wins; no per-user
--                       merge UI is built).
--   * name IS NOT NULL -> a named snapshot the user saved on purpose ("September Restock"), kept
--                       until deleted, unaffected by changes to the active draft.
-- Items are keyed by the EXACT product row the pharmacy picked (a specific wholesaler's offer), not
-- by master product: a saved/draft cart preserves the user's actual choice. Resuming one is a
-- client-side operation against the already-loaded catalogue (mergeIntoCart in reorder.ts), the same
-- re-validate-by-stock treatment already used for reorder lists; a product that is no longer active
-- or in stock is skipped and reported, never silently substituted.
--
-- Access mirrors reorder lists exactly (can_use_reorder_lists, defined in
-- 20260924100000_pharmacy_reorder_lists.sql): any active pharmacy staff can read; owners, managers
-- and cashiers of an APPROVED pharmacy can write. Checkout itself is untouched and still validates
-- everything server-side.

CREATE TABLE public.pharmacy_saved_carts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name TEXT CHECK (name IS NULL OR char_length(btrim(name)) BETWEEN 1 AND 60),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX pharmacy_saved_carts_one_draft ON public.pharmacy_saved_carts (pharmacy_id) WHERE name IS NULL;
CREATE UNIQUE INDEX pharmacy_saved_carts_name_uniq ON public.pharmacy_saved_carts (pharmacy_id, lower(btrim(name))) WHERE name IS NOT NULL;

CREATE TABLE public.pharmacy_saved_cart_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id UUID NOT NULL REFERENCES public.pharmacy_saved_carts(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  -- Display name at save time, so an item that later becomes unavailable is still recognisable.
  name_snapshot TEXT NOT NULL DEFAULT '' CHECK (char_length(name_snapshot) <= 200),
  quantity INTEGER NOT NULL CHECK (quantity BETWEEN 1 AND 100000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (cart_id, product_id)
);
CREATE INDEX pharmacy_saved_cart_items_cart_idx ON public.pharmacy_saved_cart_items (cart_id);

CREATE TRIGGER trg_pharmacy_saved_carts_updated BEFORE UPDATE ON public.pharmacy_saved_carts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Size limits: 30 NAMED saved carts per pharmacy (the single draft row doesn't count), 100 items per cart.
CREATE OR REPLACE FUNCTION public.enforce_saved_cart_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'pharmacy_saved_carts' THEN
    IF NEW.name IS NOT NULL AND (SELECT COUNT(*) FROM public.pharmacy_saved_carts WHERE pharmacy_id = NEW.pharmacy_id AND name IS NOT NULL) >= 30 THEN
      RAISE EXCEPTION 'A pharmacy can have at most 30 saved carts.';
    END IF;
  ELSE
    IF (SELECT COUNT(*) FROM public.pharmacy_saved_cart_items WHERE cart_id = NEW.cart_id) >= 100 THEN
      RAISE EXCEPTION 'A cart can have at most 100 medicines.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pharmacy_saved_carts_limit BEFORE INSERT ON public.pharmacy_saved_carts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_saved_cart_limits();
CREATE TRIGGER trg_pharmacy_saved_cart_items_limit BEFORE INSERT ON public.pharmacy_saved_cart_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_saved_cart_limits();

ALTER TABLE public.pharmacy_saved_carts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_saved_cart_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Pharmacy members read saved carts" ON public.pharmacy_saved_carts
  FOR SELECT TO authenticated USING (public.can_use_reorder_lists(pharmacy_id, FALSE));
CREATE POLICY "Ordering roles create saved carts" ON public.pharmacy_saved_carts
  FOR INSERT TO authenticated WITH CHECK (public.can_use_reorder_lists(pharmacy_id, TRUE) AND created_by = auth.uid());
CREATE POLICY "Ordering roles update saved carts" ON public.pharmacy_saved_carts
  FOR UPDATE TO authenticated
  USING (public.can_use_reorder_lists(pharmacy_id, TRUE))
  WITH CHECK (public.can_use_reorder_lists(pharmacy_id, TRUE));
CREATE POLICY "Ordering roles delete saved carts" ON public.pharmacy_saved_carts
  FOR DELETE TO authenticated USING (public.can_use_reorder_lists(pharmacy_id, TRUE));

CREATE POLICY "Pharmacy members read saved cart items" ON public.pharmacy_saved_cart_items
  FOR SELECT TO authenticated USING (EXISTS (
    SELECT 1 FROM public.pharmacy_saved_carts c WHERE c.id = cart_id AND public.can_use_reorder_lists(c.pharmacy_id, FALSE)));
CREATE POLICY "Ordering roles insert saved cart items" ON public.pharmacy_saved_cart_items
  FOR INSERT TO authenticated WITH CHECK (EXISTS (
    SELECT 1 FROM public.pharmacy_saved_carts c WHERE c.id = cart_id AND public.can_use_reorder_lists(c.pharmacy_id, TRUE)));
CREATE POLICY "Ordering roles update saved cart items" ON public.pharmacy_saved_cart_items
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.pharmacy_saved_carts c WHERE c.id = cart_id AND public.can_use_reorder_lists(c.pharmacy_id, TRUE)))
  WITH CHECK (EXISTS (SELECT 1 FROM public.pharmacy_saved_carts c WHERE c.id = cart_id AND public.can_use_reorder_lists(c.pharmacy_id, TRUE)));
CREATE POLICY "Ordering roles delete saved cart items" ON public.pharmacy_saved_cart_items
  FOR DELETE TO authenticated USING (EXISTS (
    SELECT 1 FROM public.pharmacy_saved_carts c WHERE c.id = cart_id AND public.can_use_reorder_lists(c.pharmacy_id, TRUE)));

REVOKE ALL ON public.pharmacy_saved_carts, public.pharmacy_saved_cart_items FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pharmacy_saved_carts, public.pharmacy_saved_cart_items TO authenticated;

-- ---------------------------------------------------------------------------
-- Sync the active draft cart. Called with the FULL current cart every time it changes (debounced
-- client-side); replaces whatever was there. An empty item list deletes the draft row entirely, so
-- "no draft" and "empty cart" are the same state. Not used for named saved carts (see below).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_draft_cart(p_pharmacy_id UUID, p_items JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cart_id UUID;
  v_entry JSONB;
  v_quantity INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_use_reorder_lists(p_pharmacy_id, TRUE) THEN
    RAISE EXCEPTION 'You do not have permission to save a cart for this pharmacy.';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'items must be an array.'; END IF;

  SELECT id INTO v_cart_id FROM public.pharmacy_saved_carts WHERE pharmacy_id = p_pharmacy_id AND name IS NULL;

  IF jsonb_array_length(p_items) = 0 THEN
    IF v_cart_id IS NOT NULL THEN DELETE FROM public.pharmacy_saved_carts WHERE id = v_cart_id; END IF;
    RETURN;
  END IF;

  IF v_cart_id IS NULL THEN
    INSERT INTO public.pharmacy_saved_carts (pharmacy_id, name, created_by) VALUES (p_pharmacy_id, NULL, auth.uid()) RETURNING id INTO v_cart_id;
  ELSE
    UPDATE public.pharmacy_saved_carts SET updated_at = now() WHERE id = v_cart_id;
    DELETE FROM public.pharmacy_saved_cart_items WHERE cart_id = v_cart_id;
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_quantity := LEAST(GREATEST(COALESCE((v_entry ->> 'quantity')::INTEGER, 1), 1), 100000);
    INSERT INTO public.pharmacy_saved_cart_items (cart_id, product_id, name_snapshot, quantity)
    VALUES (v_cart_id, (v_entry ->> 'productId')::UUID, left(COALESCE(v_entry ->> 'name', ''), 200), v_quantity)
    ON CONFLICT (cart_id, product_id) DO UPDATE SET quantity = EXCLUDED.quantity;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Save the current cart as a NAMED snapshot. Independent of, and unaffected by, the active draft.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_saved_cart(p_pharmacy_id UUID, p_name TEXT, p_items JSONB)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cart_id UUID;
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_entry JSONB;
  v_quantity INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_use_reorder_lists(p_pharmacy_id, TRUE) THEN
    RAISE EXCEPTION 'You do not have permission to save a cart for this pharmacy.';
  END IF;
  IF char_length(v_name) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'Enter a name for this cart (up to 60 characters).'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'The cart is empty, so there is nothing to save.';
  END IF;

  INSERT INTO public.pharmacy_saved_carts (pharmacy_id, name, created_by) VALUES (p_pharmacy_id, v_name, auth.uid()) RETURNING id INTO v_cart_id;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_quantity := LEAST(GREATEST(COALESCE((v_entry ->> 'quantity')::INTEGER, 1), 1), 100000);
    INSERT INTO public.pharmacy_saved_cart_items (cart_id, product_id, name_snapshot, quantity)
    VALUES (v_cart_id, (v_entry ->> 'productId')::UUID, left(COALESCE(v_entry ->> 'name', ''), 200), v_quantity)
    ON CONFLICT (cart_id, product_id) DO UPDATE SET quantity = EXCLUDED.quantity;
  END LOOP;

  RETURN v_cart_id;
END;
$$;

REVOKE ALL ON FUNCTION public.save_draft_cart(UUID, JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_saved_cart(UUID, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_draft_cart(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_saved_cart(UUID, TEXT, JSONB) TO authenticated;
