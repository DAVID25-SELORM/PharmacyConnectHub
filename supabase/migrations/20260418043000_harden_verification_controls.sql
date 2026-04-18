-- Harden verification enforcement so approval state cannot be bypassed by direct client writes.

CREATE OR REPLACE FUNCTION public.enforce_business_verification_controls()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Service-role operations (auth.uid() IS NULL) bypass RLS but still fire triggers.
  -- Allow them through unconditionally; RLS is what restricts regular users.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT public.has_role(auth.uid(), 'admin') THEN
    IF NEW.verification_status IS DISTINCT FROM OLD.verification_status
      OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason
      OR NEW.verified_at IS DISTINCT FROM OLD.verified_at THEN
      RAISE EXCEPTION 'Only admins can change verification status.';
    END IF;
  END IF;

  IF NEW.verification_status = 'approved' THEN
    NEW.rejection_reason := NULL;
    NEW.verified_at := COALESCE(NEW.verified_at, OLD.verified_at, now());
  ELSIF NEW.verification_status = 'rejected' THEN
    NEW.verified_at := NULL;
  ELSE
    NEW.rejection_reason := NULL;
    NEW.verified_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_business_verification_controls ON public.businesses;
CREATE TRIGGER trg_enforce_business_verification_controls
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_business_verification_controls();

DROP POLICY IF EXISTS "Wholesalers manage own products" ON public.products;
CREATE POLICY "Wholesalers manage own products"
  ON public.products
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
  );

DROP POLICY IF EXISTS "Managers manage own products" ON public.products;
CREATE POLICY "Managers manage own products"
  ON public.products
  FOR ALL
  USING (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role
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
      'manager'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
    )
  );

DROP POLICY IF EXISTS "Wholesalers update their orders" ON public.orders;
CREATE POLICY "Wholesalers update their orders"
  ON public.orders
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
  );

DROP POLICY IF EXISTS "Wholesaler staff update own orders" ON public.orders;
CREATE POLICY "Wholesaler staff update own orders"
  ON public.orders
  FOR UPDATE
  USING (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role,
      'cashier'::public.staff_role
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
      'cashier'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
    )
  );

DROP POLICY IF EXISTS "Pharmacy staff insert items for own order" ON public.order_items;
CREATE POLICY "Pharmacy staff insert items for own order"
  ON public.order_items
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.orders o
      JOIN public.businesses b ON b.id = o.pharmacy_id
      WHERE o.id = order_id
        AND b.verification_status = 'approved'
        AND public.get_staff_role(auth.uid(), o.pharmacy_id) IN (
          'owner'::public.staff_role,
          'manager'::public.staff_role,
          'cashier'::public.staff_role
        )
    )
  );

DROP POLICY IF EXISTS "Wholesaler staff insert history" ON public.order_status_history;
CREATE POLICY "Wholesaler staff insert history"
  ON public.order_status_history
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.orders o
      JOIN public.businesses b ON b.id = o.wholesaler_id
      WHERE o.id = order_status_history.order_id
        AND b.verification_status = 'approved'
        AND public.get_staff_role(auth.uid(), o.wholesaler_id) IN (
          'owner'::public.staff_role,
          'manager'::public.staff_role,
          'cashier'::public.staff_role
        )
    )
  );