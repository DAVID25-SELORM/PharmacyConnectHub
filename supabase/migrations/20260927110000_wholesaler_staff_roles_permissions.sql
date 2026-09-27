-- Wire up the 'warehouse' and 'finance' staff roles added in the previous migration.
--
-- Scope (deliberately narrow):
--   - warehouse: same order-processing rights as cashier (accept/pack/dispatch/deliver, record
--     delivery details, pick/confirm batches, handle returns) EXCEPT it may never change a
--     payment/receipt column on an order.
--   - finance: read-only on everything a cashier can read, PLUS may confirm payment received and
--     send receipts, but may never change an order's fulfilment status.
--   - Neither role gains 'manage' tier access, so order terms, product-specific discounts and
--     credit terms (the "Customer discounts" tab, gated to owner/manager in the UI) stay exactly
--     as invisible to warehouse/finance as they already are to cashier/assistant today. No code
--     change was needed for that; it falls out of the existing gate.
--   - Only wholesaler-type businesses may assign these two roles (enforced below, not just in the
--     UI).
--   - owner/manager/cashier/assistant behaviour is completely unchanged by this migration.

-- ---------------------------------------------------------------------------
-- 1. Widen can_act_for_business: warehouse joins the 'process' tier (order/return/batch
--    processing); both warehouse and finance join the default read tier.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_act_for_business(p_business_id UUID, p_level TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR (
      public.is_business_staff(auth.uid(), p_business_id)
      AND public.get_staff_role(auth.uid(), p_business_id)::TEXT = ANY (
        CASE p_level
          WHEN 'manage' THEN ARRAY['owner', 'manager']
          WHEN 'process' THEN ARRAY['owner', 'manager', 'cashier', 'warehouse']
          ELSE ARRAY['owner', 'manager', 'cashier', 'assistant', 'warehouse', 'finance']
        END
      )
    )
$$;
REVOKE ALL ON FUNCTION public.can_act_for_business(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Only wholesaler businesses may have warehouse/finance staff.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_staff_role_business_type()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.role IN ('warehouse', 'finance') AND NOT EXISTS (
    SELECT 1 FROM public.businesses b WHERE b.id = NEW.business_id AND b.type = 'wholesaler'
  ) THEN
    RAISE EXCEPTION 'The warehouse and finance roles are only available for wholesaler businesses.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_staff_role_business_type ON public.business_staff;
CREATE TRIGGER trg_enforce_staff_role_business_type
  BEFORE INSERT OR UPDATE ON public.business_staff
  FOR EACH ROW EXECUTE FUNCTION public.enforce_staff_role_business_type();

-- ---------------------------------------------------------------------------
-- 3. Let warehouse/finance staff reach the orders UPDATE policy at all (column-level split is
--    enforced by the trigger in step 4, since RLS alone cannot see which columns changed).
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Wholesaler staff update own orders" ON public.orders;
CREATE POLICY "Wholesaler staff update own orders"
  ON public.orders
  FOR UPDATE
  USING (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role,
      'cashier'::public.staff_role,
      'warehouse'::public.staff_role,
      'finance'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
    )
  )
  WITH CHECK (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role,
      'cashier'::public.staff_role,
      'warehouse'::public.staff_role,
      'finance'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
    )
  );

-- ---------------------------------------------------------------------------
-- 4. Column-level split: warehouse may never touch payment/receipt columns; finance may never
--    touch fulfilment-status columns. Owner/manager/cashier are untouched (the role check only
--    fires for warehouse/finance). System/service-role writes (auth.uid() IS NULL) bypass this,
--    same as every other trigger in this codebase that keys off auth.uid().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_wholesaler_staff_order_scope()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role public.staff_role;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = NEW.wholesaler_id AND b.owner_id = auth.uid()) THEN
    RETURN NEW;
  END IF;

  v_role := public.get_staff_role(auth.uid(), NEW.wholesaler_id);

  IF v_role = 'warehouse' THEN
    IF NEW.payment_status IS DISTINCT FROM OLD.payment_status
      OR NEW.paid_at IS DISTINCT FROM OLD.paid_at
      OR NEW.payment_confirmed_at IS DISTINCT FROM OLD.payment_confirmed_at
      OR NEW.payment_confirmed_by IS DISTINCT FROM OLD.payment_confirmed_by
      OR NEW.receipt_sent_at IS DISTINCT FROM OLD.receipt_sent_at
      OR NEW.receipt_sent_to IS DISTINCT FROM OLD.receipt_sent_to
    THEN
      RAISE EXCEPTION 'Warehouse staff cannot change payment or receipt details.';
    END IF;
  ELSIF v_role = 'finance' THEN
    IF NEW.status IS DISTINCT FROM OLD.status
      OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at
      OR NEW.packed_at IS DISTINCT FROM OLD.packed_at
      OR NEW.dispatched_at IS DISTINCT FROM OLD.dispatched_at
      OR NEW.delivered_at IS DISTINCT FROM OLD.delivered_at
      OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at
      OR NEW.cancellation_reason IS DISTINCT FROM OLD.cancellation_reason
    THEN
      RAISE EXCEPTION 'Finance staff cannot change order fulfilment status.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_wholesaler_staff_order_scope ON public.orders;
CREATE TRIGGER trg_enforce_wholesaler_staff_order_scope
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.enforce_wholesaler_staff_order_scope();
