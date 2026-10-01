-- Pharmacy-owned inventory, part 1: schema.
--
-- Design (confirmed with the business owner before building): standalone, not auto-synced with
-- marketplace orders. A pharmacy's inventory is its own free-form record -- not tied to any
-- wholesaler's product catalog -- updated only by direct staff actions (create/adjust/edit) and
-- bulk Excel/CSV/PDF import. Auto-syncing from delivered orders was considered and rejected: it
-- would require fuzzy-matching a wholesaler's free-text order_items.product_name against a
-- pharmacy's independently-named inventory rows, which is unreliable and a wrong match would
-- silently corrupt stock counts.
--
-- Reuses existing, already-proven infrastructure rather than inventing new patterns:
--   * public.product_import_identity(name, brand, form, pack_size) -- the exact text-normalizing
--     identity function the wholesaler product-import pipeline already uses (see
--     20260913090000_safe_wholesaler_import.sql) -- is generic and reused as-is.
--   * The preview/confirm import RPC shape (hash-based idempotency via an import_runs table,
--     a server-computed confirmation token that invalidates if inventory changed between preview
--     and confirm) mirrors preview_wholesaler_import exactly; see the next migration.
--
-- Unlike wholesaler products, writes are RPC-only (no direct INSERT/UPDATE/DELETE grant) --
-- matching the rfqs/procurements precedent -- since this is new code without years of an existing
-- direct-write UI depending on table-level RLS.

CREATE TABLE public.pharmacy_inventory_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  brand TEXT,
  category TEXT,
  form TEXT,
  pack_size TEXT,
  stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
  reorder_level INTEGER CHECK (reorder_level IS NULL OR reorder_level >= 0),
  unit_cost_ghs NUMERIC(10,2) CHECK (unit_cost_ghs IS NULL OR unit_cost_ghs >= 0),
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_pharmacy_inventory_items_pharmacy ON public.pharmacy_inventory_items(pharmacy_id, name);
-- Decimal points stay significant (2.5mg must never match 25mg) -- same guarantee as the
-- wholesaler identity index, since it's the same underlying function.
CREATE UNIQUE INDEX pharmacy_inventory_identity_uniq ON public.pharmacy_inventory_items (
  pharmacy_id, public.product_import_identity(name, brand, form, pack_size)
);
CREATE TRIGGER trg_pharmacy_inventory_items_updated BEFORE UPDATE ON public.pharmacy_inventory_items
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Append-only movement ledger: every stock change (manual receive/adjust/write-off, or an import
-- row that changed stock) gets one row here, so a pharmacy can see exactly why its count changed.
CREATE TABLE public.pharmacy_inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id UUID NOT NULL REFERENCES public.pharmacy_inventory_items(id) ON DELETE CASCADE,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('receive', 'adjust', 'write_off', 'import')),
  quantity_delta INTEGER NOT NULL CHECK (quantity_delta <> 0),
  stock_after INTEGER NOT NULL CHECK (stock_after >= 0),
  reason TEXT CHECK (reason IS NULL OR reason IN ('damaged', 'expired', 'count_correction', 'other')),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 500),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_pharmacy_inventory_movements_item ON public.pharmacy_inventory_movements(item_id, created_at DESC);
CREATE INDEX idx_pharmacy_inventory_movements_pharmacy ON public.pharmacy_inventory_movements(pharmacy_id, created_at DESC);

-- Idempotency ledger for the import RPC, keyed by the client-supplied request id -- identical
-- shape to product_import_runs.
CREATE TABLE public.pharmacy_inventory_import_runs (
  id UUID PRIMARY KEY,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
  created_by UUID NOT NULL REFERENCES auth.users(id),
  payload_hash TEXT NOT NULL,
  result JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.pharmacy_inventory_import_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_inventory_import_runs FROM PUBLIC, authenticated;

-- ===========================================================================
-- RLS: reads only (owner/active staff of the pharmacy, or admin); every write goes through a
-- SECURITY DEFINER RPC in the next migration.
-- ===========================================================================
ALTER TABLE public.pharmacy_inventory_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Pharmacy staff read own inventory items" ON public.pharmacy_inventory_items FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = pharmacy_id AND b.owner_id = auth.uid())
  OR public.is_business_staff(auth.uid(), pharmacy_id)
);
CREATE POLICY "Admins see all pharmacy inventory items" ON public.pharmacy_inventory_items FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.pharmacy_inventory_items FROM PUBLIC, anon;
GRANT SELECT ON public.pharmacy_inventory_items TO authenticated;

ALTER TABLE public.pharmacy_inventory_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Pharmacy staff read own inventory movements" ON public.pharmacy_inventory_movements FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = pharmacy_id AND b.owner_id = auth.uid())
  OR public.is_business_staff(auth.uid(), pharmacy_id)
);
CREATE POLICY "Admins see all pharmacy inventory movements" ON public.pharmacy_inventory_movements FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.pharmacy_inventory_movements FROM PUBLIC, anon;
GRANT SELECT ON public.pharmacy_inventory_movements TO authenticated;
