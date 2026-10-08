-- Isolated database only. Reproduces production's stock evidence / inventory ledger mechanism and its
-- immutable-order-items guard, exactly as read from the PharmacyConnectHub catalog on 8 Oct 2026 (read-only
-- review; see docs/order-amendments-and-partial-fulfilment.md section 13).
--
-- Install AFTER the repository migrations and AFTER production-guard-fixture.sql, then re-apply
-- supabase/migrations/20261017110000_production_checkout_compatibility.sql so checkout writes the deduction
-- evidence and the inventory context row exactly as it does in production:
--     psql < production-guard-fixture.sql
--     psql < production-stock-fixture.sql
--     psql < ../../supabase/migrations/20261017110000_production_checkout_compatibility.sql
-- Do NOT run this against production: production already has these objects.

CREATE TABLE IF NOT EXISTS public.inventory_operation_context (
  transaction_id BIGINT PRIMARY KEY,
  actor_id UUID, movement_type TEXT, order_id UUID, import_run_id UUID, request_id UUID, reason TEXT
);
CREATE TABLE IF NOT EXISTS public.server_audit_context (transaction_id BIGINT PRIMARY KEY, actor_id UUID);

CREATE TABLE IF NOT EXISTS public.order_stock_deductions (
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  restored_at TIMESTAMPTZ,
  PRIMARY KEY (order_id, product_id)
);

CREATE TABLE IF NOT EXISTS public.inventory_opening_balances (
  product_id UUID PRIMARY KEY REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  quantity INTEGER NOT NULL CHECK (quantity >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  actor_id UUID,
  order_id UUID REFERENCES public.orders(id),
  import_run_id UUID,
  request_id UUID,
  movement_type TEXT NOT NULL,
  quantity_delta BIGINT NOT NULL,
  quantity_before INTEGER NOT NULL CHECK (quantity_before >= 0),
  quantity_after INTEGER NOT NULL CHECK (quantity_after >= 0),
  reason TEXT,
  source_operation TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT inventory_movements_check CHECK (((quantity_after)::BIGINT - quantity_before) = quantity_delta),
  CONSTRAINT inventory_movements_movement_type_check CHECK (movement_type = ANY (ARRAY[
    'product_created', 'manual_add', 'manual_remove', 'manual_reconciliation', 'checkout_deduction',
    'order_cancellation_restore', 'import_add', 'import_replace', 'admin_adjustment']))
);
CREATE INDEX IF NOT EXISTS inventory_movements_tenant_product ON public.inventory_movements (wholesaler_id, product_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS inventory_order_movement_once ON public.inventory_movements (order_id, product_id, movement_type)
  WHERE movement_type = ANY (ARRAY['checkout_deduction', 'order_cancellation_restore']);

-- Every change to products.stock is recorded, using the context row for the current transaction when there is one.
CREATE OR REPLACE FUNCTION public.phase1_record_inventory()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE ctx public.inventory_operation_context%ROWTYPE; previous INTEGER;
BEGIN
  previous := CASE WHEN TG_OP='INSERT' THEN 0 ELSE OLD.stock END;
  IF TG_OP='UPDATE' AND NEW.stock=OLD.stock THEN RETURN NEW; END IF;
  SELECT * INTO ctx FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  IF TG_OP='INSERT' THEN
    INSERT INTO public.inventory_opening_balances(product_id,wholesaler_id,quantity) VALUES(NEW.id,NEW.wholesaler_id,0);
  END IF;
  IF NEW.stock=previous THEN RETURN NEW; END IF;
  INSERT INTO public.inventory_movements(product_id,wholesaler_id,actor_id,order_id,import_run_id,request_id,
    movement_type,quantity_delta,quantity_before,quantity_after,reason,source_operation)
  VALUES(NEW.id,NEW.wholesaler_id,coalesce(ctx.actor_id,auth.uid()),ctx.order_id,ctx.import_run_id,ctx.request_id,
    coalesce(ctx.movement_type,CASE WHEN TG_OP='INSERT' THEN 'product_created' ELSE 'admin_adjustment' END),
    NEW.stock::BIGINT-previous,previous,NEW.stock,ctx.reason,
    coalesce(ctx.movement_type,CASE WHEN TG_OP='INSERT' THEN 'product_insert' ELSE 'database_maintenance' END));
  RETURN NEW;
END $function$;
DROP TRIGGER IF EXISTS phase1_inventory_movement ON public.products;
CREATE TRIGGER phase1_inventory_movement AFTER INSERT OR UPDATE OF stock ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.phase1_record_inventory();

-- Strict cancellation restore: needs matching evidence, restores the full deduction once.
CREATE OR REPLACE FUNCTION public.restore_stock_for_cancelled_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE deduction RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.order_stock_deductions WHERE order_id = NEW.id) THEN
    RAISE EXCEPTION 'Legacy order has no verified stock deduction. Manual reconciliation is required.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_stock_deductions d FULL JOIN
      (SELECT product_id, sum(quantity) quantity FROM public.order_items WHERE order_id = NEW.id GROUP BY product_id) i
      ON d.product_id = i.product_id AND d.order_id = NEW.id
    WHERE (d.order_id = NEW.id OR d.order_id IS NULL)
      AND (d.product_id IS NULL OR i.product_id IS NULL OR d.quantity <> i.quantity OR d.wholesaler_id <> NEW.wholesaler_id)
  ) THEN RAISE EXCEPTION 'Order deduction evidence does not match order items.'; END IF;
  FOR deduction IN SELECT * FROM public.order_stock_deductions WHERE order_id = NEW.id ORDER BY product_id FOR UPDATE LOOP
    IF deduction.restored_at IS NOT NULL THEN RAISE EXCEPTION 'Stock was already restored.'; END IF;
    INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,order_id,reason)
      VALUES(txid_current(),auth.uid(),'order_cancellation_restore',NEW.id,NEW.cancellation_reason);
    UPDATE public.products SET stock = stock + deduction.quantity WHERE id = deduction.product_id AND wholesaler_id = deduction.wholesaler_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Deducted product supplier mismatch.'; END IF;
    DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
    UPDATE public.order_stock_deductions SET restored_at = now() WHERE order_id = deduction.order_id AND product_id = deduction.product_id;
  END LOOP;
  RETURN NEW;
END $function$;

-- Order lines are historical: only INSERT, only into a pending order for a product of the same wholesaler.
CREATE OR REPLACE FUNCTION public.phase0_order_item_integrity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Historical order items are immutable.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.orders o JOIN public.products p ON p.wholesaler_id = o.wholesaler_id
    WHERE o.id = NEW.order_id AND p.id = NEW.product_id AND o.status = 'pending') THEN
    RAISE EXCEPTION 'Order product must belong to its wholesaler and a pending order.';
  END IF;
  IF NEW.unit_price_ghs < 0 THEN RAISE EXCEPTION 'Invalid historical price.'; END IF;
  IF EXISTS (SELECT 1 FROM public.order_items WHERE order_id = NEW.order_id AND product_id = NEW.product_id) THEN
    RAISE EXCEPTION 'Duplicate order product.';
  END IF;
  RETURN NEW;
END $function$;
DROP TRIGGER IF EXISTS phase0_item_integrity ON public.order_items;
CREATE TRIGGER phase0_item_integrity BEFORE INSERT OR DELETE OR UPDATE ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.phase0_order_item_integrity();
