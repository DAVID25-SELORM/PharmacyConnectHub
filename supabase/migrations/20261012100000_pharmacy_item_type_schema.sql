-- Pharmacy inventory item types, part 1: schema.
--
-- Adds a first-class item_type to public.pharmacy_inventory_items: medicine (the default, so every
-- existing row keeps working unchanged), medical_consumable, medical_equipment, non_medical. This
-- table is already fully standalone from the wholesaler/marketplace catalogue (confirmed by review:
-- cart/checkout/order_items/reports never touch it), so this stays scoped to pharmacy inventory only
-- -- the wholesaler catalog (products/master_products) is NOT touched by this migration, by design.
--
-- All new columns are nullable and purely additive. Nothing becomes required for any item type;
-- which fields are shown/asked for per item_type is a UI concern (InventoryItemFormDialog), not a
-- database constraint -- matching this table's existing philosophy (brand/category/form/pack_size
-- have always been optional). A pharmacy stock count has no mandatory selling price or batch info
-- today, and that stays true after this migration.
--
-- Column reuse by item type (documented here since the UI will show different subsets):
--   name, brand, category, stock, reorder_level, unit_cost_ghs, selling_price_ghs, supplier -- all types
--   form (dosage form), pack_size, generic_name, strength, manufacturer -- medicine
--   pack_size, unit_of_measure                                          -- medicine + consumable
--   barcode, batch_number, expiry_date                                  -- medicine + consumable (barcode also non_medical)
--   unit_of_measure, barcode                                            -- non_medical ("unit", "SKU/barcode")
--   model, serial_number, warranty_info                                 -- equipment only

ALTER TABLE public.pharmacy_inventory_items
  ADD COLUMN item_type TEXT NOT NULL DEFAULT 'medicine'
    CHECK (item_type IN ('medicine', 'medical_consumable', 'medical_equipment', 'non_medical')),
  ADD COLUMN generic_name TEXT,
  ADD COLUMN strength TEXT,
  ADD COLUMN manufacturer TEXT,
  ADD COLUMN barcode TEXT,
  ADD COLUMN batch_number TEXT,
  ADD COLUMN expiry_date DATE,
  ADD COLUMN selling_price_ghs NUMERIC(10,2) CHECK (selling_price_ghs IS NULL OR selling_price_ghs >= 0),
  ADD COLUMN supplier TEXT,
  ADD COLUMN unit_of_measure TEXT,
  ADD COLUMN model TEXT,
  ADD COLUMN serial_number TEXT,
  ADD COLUMN warranty_info TEXT;

CREATE INDEX idx_pharmacy_inventory_items_type ON public.pharmacy_inventory_items(pharmacy_id, item_type);

-- The identity-uniqueness index now also scopes by item_type: without this, a medicine and a
-- non-medical item that happen to share a name+brand (both with empty form/pack_size, which is the
-- norm for non-medicine rows) would collide as "the same item" even though they are not. Rebuilt,
-- not altered in place, since a unique index can't have a column inserted into it.
DROP INDEX IF EXISTS public.pharmacy_inventory_identity_uniq;
CREATE UNIQUE INDEX pharmacy_inventory_identity_uniq ON public.pharmacy_inventory_items (
  pharmacy_id, item_type, public.product_import_identity(name, brand, form, pack_size)
);
