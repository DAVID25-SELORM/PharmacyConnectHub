-- Pharmacy reorder lists (saved restock lists) and "reorder a previous order" support.
--
-- Lists are keyed by MASTER product, not by a supplier's product row, so a list keeps working
-- when a supplier changes price/stock or a product is delisted: the app re-resolves each line
-- against the current catalogue (preferred supplier if available, else the best net price).
--
-- Access: any owner/active staff of the pharmacy can read its lists; owners, managers and
-- cashiers of an APPROVED pharmacy can change them (same roles that may place orders).
-- Nothing here places orders or touches stock; checkout still validates everything server-side.

CREATE TABLE IF NOT EXISTS public.reorder_lists (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS reorder_lists_pharmacy_name_uniq
  ON public.reorder_lists (pharmacy_id, lower(btrim(name)));

CREATE TABLE IF NOT EXISTS public.reorder_list_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id UUID NOT NULL REFERENCES public.reorder_lists(id) ON DELETE CASCADE,
  master_product_id UUID NOT NULL REFERENCES public.master_products(id) ON DELETE CASCADE,
  -- Display name at the time it was added, so a delisted medicine can still be recognised.
  name_snapshot TEXT NOT NULL DEFAULT '' CHECK (char_length(name_snapshot) <= 200),
  quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity BETWEEN 1 AND 100000),
  preferred_wholesaler_id UUID REFERENCES public.businesses(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (list_id, master_product_id)
);
CREATE INDEX IF NOT EXISTS reorder_list_items_list_idx ON public.reorder_list_items (list_id);

DROP TRIGGER IF EXISTS trg_reorder_lists_updated ON public.reorder_lists;
CREATE TRIGGER trg_reorder_lists_updated BEFORE UPDATE ON public.reorder_lists
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS trg_reorder_list_items_updated ON public.reorder_list_items;
CREATE TRIGGER trg_reorder_list_items_updated BEFORE UPDATE ON public.reorder_list_items
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Access helper. p_write = true additionally requires an approved pharmacy and an ordering role.
CREATE OR REPLACE FUNCTION public.can_use_reorder_lists(p_pharmacy_id UUID, p_write BOOLEAN)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id = p_pharmacy_id
      AND b.type = 'pharmacy'
      AND (NOT p_write OR b.verification_status = 'approved')
      AND (
        b.owner_id = auth.uid()
        OR (
          public.is_business_staff(auth.uid(), b.id)
          AND (NOT p_write OR public.get_staff_role(auth.uid(), b.id) IN ('owner', 'manager', 'cashier'))
        )
      )
  );
$$;

REVOKE ALL ON FUNCTION public.can_use_reorder_lists(UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_use_reorder_lists(UUID, BOOLEAN) TO authenticated;

-- Size limits (a list is a working document, not a data store).
CREATE OR REPLACE FUNCTION public.enforce_reorder_list_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'reorder_lists' THEN
    IF (SELECT COUNT(*) FROM public.reorder_lists WHERE pharmacy_id = NEW.pharmacy_id) >= 50 THEN
      RAISE EXCEPTION 'A pharmacy can have at most 50 reorder lists.';
    END IF;
  ELSE
    IF (SELECT COUNT(*) FROM public.reorder_list_items WHERE list_id = NEW.list_id) >= 200 THEN
      RAISE EXCEPTION 'A reorder list can have at most 200 medicines.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reorder_lists_limit ON public.reorder_lists;
CREATE TRIGGER trg_reorder_lists_limit BEFORE INSERT ON public.reorder_lists
  FOR EACH ROW EXECUTE FUNCTION public.enforce_reorder_list_limits();
DROP TRIGGER IF EXISTS trg_reorder_list_items_limit ON public.reorder_list_items;
CREATE TRIGGER trg_reorder_list_items_limit BEFORE INSERT ON public.reorder_list_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_reorder_list_limits();

ALTER TABLE public.reorder_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reorder_list_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Pharmacy members read reorder lists" ON public.reorder_lists;
CREATE POLICY "Pharmacy members read reorder lists" ON public.reorder_lists
  FOR SELECT TO authenticated USING (public.can_use_reorder_lists(pharmacy_id, FALSE));
DROP POLICY IF EXISTS "Ordering roles create reorder lists" ON public.reorder_lists;
CREATE POLICY "Ordering roles create reorder lists" ON public.reorder_lists
  FOR INSERT TO authenticated WITH CHECK (public.can_use_reorder_lists(pharmacy_id, TRUE) AND created_by = auth.uid());
DROP POLICY IF EXISTS "Ordering roles update reorder lists" ON public.reorder_lists;
CREATE POLICY "Ordering roles update reorder lists" ON public.reorder_lists
  FOR UPDATE TO authenticated
  USING (public.can_use_reorder_lists(pharmacy_id, TRUE))
  WITH CHECK (public.can_use_reorder_lists(pharmacy_id, TRUE));
DROP POLICY IF EXISTS "Ordering roles delete reorder lists" ON public.reorder_lists;
CREATE POLICY "Ordering roles delete reorder lists" ON public.reorder_lists
  FOR DELETE TO authenticated USING (public.can_use_reorder_lists(pharmacy_id, TRUE));

DROP POLICY IF EXISTS "Pharmacy members read reorder list items" ON public.reorder_list_items;
CREATE POLICY "Pharmacy members read reorder list items" ON public.reorder_list_items
  FOR SELECT TO authenticated USING (EXISTS (
    SELECT 1 FROM public.reorder_lists l WHERE l.id = list_id AND public.can_use_reorder_lists(l.pharmacy_id, FALSE)));
DROP POLICY IF EXISTS "Ordering roles insert reorder list items" ON public.reorder_list_items;
CREATE POLICY "Ordering roles insert reorder list items" ON public.reorder_list_items
  FOR INSERT TO authenticated WITH CHECK (EXISTS (
    SELECT 1 FROM public.reorder_lists l WHERE l.id = list_id AND public.can_use_reorder_lists(l.pharmacy_id, TRUE)));
DROP POLICY IF EXISTS "Ordering roles update reorder list items" ON public.reorder_list_items;
CREATE POLICY "Ordering roles update reorder list items" ON public.reorder_list_items
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.reorder_lists l WHERE l.id = list_id AND public.can_use_reorder_lists(l.pharmacy_id, TRUE)))
  WITH CHECK (EXISTS (SELECT 1 FROM public.reorder_lists l WHERE l.id = list_id AND public.can_use_reorder_lists(l.pharmacy_id, TRUE)));
DROP POLICY IF EXISTS "Ordering roles delete reorder list items" ON public.reorder_list_items;
CREATE POLICY "Ordering roles delete reorder list items" ON public.reorder_list_items
  FOR DELETE TO authenticated USING (EXISTS (
    SELECT 1 FROM public.reorder_lists l WHERE l.id = list_id AND public.can_use_reorder_lists(l.pharmacy_id, TRUE)));

REVOKE ALL ON public.reorder_lists, public.reorder_list_items FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reorder_lists, public.reorder_list_items TO authenticated;
GRANT ALL ON public.reorder_lists, public.reorder_list_items TO service_role;

-- The lines of a past order, keyed by master product, for "reorder". The client re-resolves each
-- line against today's catalogue, so old prices/stock are never reused.
CREATE OR REPLACE FUNCTION public.get_order_reorder_lines(p_order_id UUID)
RETURNS TABLE (
  product_id UUID,
  master_product_id UUID,
  product_name TEXT,
  quantity INTEGER,
  wholesaler_id UUID
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT oi.product_id, w.product_id, oi.product_name, oi.quantity, o.wholesaler_id
  FROM public.orders o
  JOIN public.order_items oi ON oi.order_id = o.id
  LEFT JOIN public.wholesaler_products w ON w.id = oi.product_id
  WHERE o.id = p_order_id
    AND public.can_use_reorder_lists(o.pharmacy_id, FALSE);
$$;

REVOKE ALL ON FUNCTION public.get_order_reorder_lines(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_order_reorder_lines(UUID) TO authenticated;
