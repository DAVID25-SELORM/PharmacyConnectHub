-- Phase 0 only. Run the read-only preflight before applying. No historical rows are repaired.
BEGIN;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
  signup_owner_is_superintendent BOOLEAN;
  signup_superintendent_name TEXT;
  signup_owner_full_name TEXT;
  signup_owner_phone TEXT;
  signup_public_phone TEXT;
  signup_public_email TEXT;
  signup_gps_address TEXT;
  signup_location_description TEXT;
  signup_working_hours TEXT;
  signup_superintendent_phone TEXT;
  signup_superintendent_email TEXT;
  created_business_id UUID;
BEGIN
  signup_owner_full_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), '');
  signup_owner_phone := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '');

  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    signup_owner_full_name,
    signup_owner_phone
  )
  ON CONFLICT (id) DO UPDATE
    SET full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
        phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
        updated_at = now();

  IF COALESCE(NEW.raw_user_meta_data->>'is_staff_invite', '') = 'true' THEN
    RETURN NEW;
  END IF;

  signup_role := CASE
    WHEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy') IN ('pharmacy', 'wholesaler')
      THEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy')::public.app_role
    ELSE 'pharmacy'::public.app_role
  END;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, signup_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  signup_business_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'business_name', '')), '');
  signup_owner_is_superintendent := CASE
    WHEN signup_role = 'pharmacy'::public.app_role
      THEN COALESCE((NEW.raw_user_meta_data->>'owner_is_superintendent')::BOOLEAN, true)
    ELSE true
  END;
  signup_superintendent_name := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_name', '')),
    ''
  );
  signup_public_phone := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'public_phone',
        NEW.raw_user_meta_data->>'phone',
        ''
      )
    ),
    ''
  );
  signup_public_email := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'public_email', '')), '');
  signup_gps_address := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'gps_address',
        NEW.raw_user_meta_data->>'address',
        ''
      )
    ),
    ''
  );
  signup_location_description := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'location_description', '')),
    ''
  );
  signup_working_hours := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'working_hours', '')), '');
  signup_superintendent_phone := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_phone', '')),
    ''
  );
  signup_superintendent_email := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_email', '')),
    ''
  );

  IF signup_role IN ('pharmacy'::public.app_role, 'wholesaler'::public.app_role)
    AND signup_business_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.owner_id = NEW.id
    ) THEN
    INSERT INTO public.businesses (
      owner_id,
      type,
      name,
      license_number,
      city,
      region,
      phone,
      address,
      public_email,
      working_hours,
      location_description,
      owner_is_superintendent,
      superintendent_name
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      signup_public_phone,
      signup_gps_address,
      signup_public_email,
      signup_working_hours,
      signup_location_description,
      signup_owner_is_superintendent,
      CASE
        WHEN signup_role = 'pharmacy'::public.app_role AND NOT signup_owner_is_superintendent
          THEN signup_superintendent_name
        ELSE NULL
      END
    )
    RETURNING id INTO created_business_id;

    INSERT INTO public.business_private_contacts (
      business_id,
      owner_full_name,
      owner_phone,
      owner_email,
      superintendent_full_name,
      superintendent_phone,
      superintendent_email
    )
    VALUES (
      created_business_id,
      signup_owner_full_name,
      signup_owner_phone,
      NULLIF(BTRIM(COALESCE(NEW.email, '')), ''),
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_full_name
        ELSE signup_superintendent_name
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_phone
        ELSE signup_superintendent_phone
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN NULLIF(BTRIM(COALESCE(NEW.email, '')), '')
        ELSE signup_superintendent_email
      END
    )
    ON CONFLICT (business_id) DO UPDATE
      SET owner_full_name = COALESCE(EXCLUDED.owner_full_name, public.business_private_contacts.owner_full_name),
          owner_phone = COALESCE(EXCLUDED.owner_phone, public.business_private_contacts.owner_phone),
          owner_email = COALESCE(EXCLUDED.owner_email, public.business_private_contacts.owner_email),
          superintendent_full_name = COALESCE(
            EXCLUDED.superintendent_full_name,
            public.business_private_contacts.superintendent_full_name
          ),
          superintendent_phone = COALESCE(
            EXCLUDED.superintendent_phone,
            public.business_private_contacts.superintendent_phone
          ),
          superintendent_email = COALESCE(
            EXCLUDED.superintendent_email,
            public.business_private_contacts.superintendent_email
          ),
          updated_at = now();
  END IF;

  RETURN NEW;
END;
$$;

-- Reserve wholesaler stock atomically when marketplace orders are created.
-- This prevents partial orders and reduces overselling between pharmacy and wholesaler flows.

CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB
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
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN
    RAISE EXCEPTION 'caller_id and pharmacy_id are required.';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(_items) = 'array' THEN _items ELSE '[]'::jsonb END) x
    WHERE jsonb_typeof(x) <> 'object' OR coalesce(x->>'quantity', '') !~ '^[1-9][0-9]*$'
      OR nullif(x->>'productId', '') IS NULL) THEN
    RAISE EXCEPTION 'Invalid checkout item.';
  END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required.';
  END IF;

  SELECT id, owner_id, type, verification_status
  INTO v_business
  FROM public.businesses
  WHERE id = _pharmacy_id FOR SHARE;

  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;

  IF v_business.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.';
  END IF;

  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role
    INTO v_role
    FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id
      AND bs.user_id = _caller_id
      AND bs.status = 'active'
    LIMIT 1;

    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.';
    END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (
    product_id UUID PRIMARY KEY,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  INSERT INTO tmp_requested_items (product_id, quantity)
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER
  FROM (
    SELECT
      (item ->> 'productId')::UUID AS product_id,
      (item ->> 'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(_items) item
  ) raw
  WHERE raw.product_id IS NOT NULL
    AND raw.quantity > 0
  GROUP BY raw.product_id;

  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN
    RAISE EXCEPTION 'Each item needs a valid productId and quantity.';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM public.products p
    JOIN tmp_requested_items r ON r.product_id = p.id
  ) <> v_requested_count THEN
    RAISE EXCEPTION 'One or more products could not be found.';
  END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY,
    wholesaler_id UUID NOT NULL,
    product_name TEXT NOT NULL,
    unit_price_ghs NUMERIC NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT
      p.id,
      p.name,
      p.price_ghs,
      p.stock,
      p.active,
      p.wholesaler_id,
      b.name AS wholesaler_name,
      b.verification_status AS wholesaler_status,
      b.type AS wholesaler_type,
      r.quantity
    FROM tmp_requested_items r
    JOIN public.products p ON p.id = r.product_id
    JOIN public.businesses b ON b.id = p.wholesaler_id
    ORDER BY p.id
    FOR UPDATE OF p FOR SHARE OF b
  LOOP
    IF NOT v_product.active THEN
      RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name;
    END IF;

    IF v_product.wholesaler_status <> 'approved' OR v_product.wholesaler_type <> 'wholesaler' THEN
      RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name;
    END IF;

    IF v_product.stock <= 0 THEN
      RAISE EXCEPTION '% is currently out of stock.', v_product.name;
    END IF;

    IF v_product.stock < v_product.quantity THEN
      RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name;
    END IF;

    UPDATE public.products
    SET stock = stock - v_product.quantity
    WHERE id = v_product.id;

    INSERT INTO tmp_locked_products (
      product_id,
      wholesaler_id,
      product_name,
      unit_price_ghs,
      quantity
    )
    VALUES (
      v_product.id,
      v_product.wholesaler_id,
      v_product.name,
      v_product.price_ghs,
      v_product.quantity
    );
  END LOOP;

  FOR v_wholesaler IN
    SELECT
      wholesaler_id,
      SUM(unit_price_ghs * quantity) AS total_ghs
    FROM tmp_locked_products
    GROUP BY wholesaler_id
  LOOP
    INSERT INTO public.orders (
      pharmacy_id,
      wholesaler_id,
      total_ghs,
      payment_method
    )
    VALUES (
      _pharmacy_id,
      v_wholesaler.wholesaler_id,
      v_wholesaler.total_ghs,
      'cod'
    )
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_items (
      order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    )
    SELECT
      v_order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    INSERT INTO public.order_stock_deductions(order_id, product_id, wholesaler_id, quantity)
    SELECT v_order_id, product_id, wholesaler_id, quantity FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    v_order_count := v_order_count + 1;
  END LOOP;

  RETURN v_order_count;
END;
$$;

-- Private evidence populated only by canonical checkout, never inferred from legacy orders.
CREATE TABLE public.order_stock_deductions (
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  restored_at TIMESTAMPTZ,
  PRIMARY KEY(order_id, product_id)
);
ALTER TABLE public.order_stock_deductions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_stock_deductions FROM PUBLIC, anon, authenticated, service_role;

-- Remove all client mutation policies, including permissive historical alternatives.
DO $$ DECLARE pol RECORD; col RECORD; BEGIN
  FOR pol IN SELECT tablename, policyname FROM pg_policies WHERE schemaname = 'public'
    AND tablename IN ('orders','order_items','order_status_history','business_staff')
    AND cmd <> 'SELECT'
  LOOP EXECUTE format('DROP POLICY %I ON public.%I', pol.policyname, pol.tablename); END LOOP;
  -- Clear column-level grants as well as table grants.
  FOR col IN SELECT table_name, column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name IN ('orders','order_items','order_status_history','business_staff')
  LOOP EXECUTE format('REVOKE INSERT (%I), UPDATE (%I), REFERENCES (%I) ON public.%I FROM PUBLIC, anon, authenticated',
    col.column_name, col.column_name, col.column_name, col.table_name); END LOOP;
END $$;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.orders, public.order_items,
  public.order_status_history, public.business_staff FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.orders, public.order_items, public.order_status_history FROM service_role;
GRANT UPDATE(receipt_sent_at, receipt_sent_to) ON public.orders TO service_role;
REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB) TO service_role;
REVOKE ALL ON FUNCTION public.add_business_staff_by_email(UUID,TEXT,public.staff_role) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.lookup_user_id_by_email(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.write_audit_log(TEXT,TEXT,TEXT,UUID,TEXT,JSONB,UUID,TEXT,TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_business_verification_controls()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE trusted BOOLEAN := coalesce(public.has_role(auth.uid(), 'admin'), false) OR coalesce(auth.role() = 'service_role', false);
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Even administrator-created businesses must be approved in a separate review operation.
    NEW.verification_status := 'pending'; NEW.verified_at := NULL; NEW.rejection_reason := NULL;
    RETURN NEW;
  END IF;
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id OR NEW.type IS DISTINCT FROM OLD.type THEN
    RAISE EXCEPTION 'Business ownership and type cannot be changed through profile editing.';
  END IF;
  -- Nested evidence triggers may only invalidate approval, never grant it.
  IF pg_trigger_depth() > 1 AND NEW.verification_status = 'pending'
    AND NEW.verified_at IS NULL AND NEW.rejection_reason IS NULL THEN RETURN NEW; END IF;
  IF NOT trusted AND (NEW.verification_status IS DISTINCT FROM OLD.verification_status
    OR NEW.verified_at IS DISTINCT FROM OLD.verified_at OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason) THEN
    RAISE EXCEPTION 'Only administrators may change verification fields.';
  END IF;
  IF ROW(NEW.name, NEW.license_number, NEW.address, NEW.city, NEW.region,
      NEW.owner_is_superintendent, NEW.superintendent_name)
    IS DISTINCT FROM ROW(OLD.name, OLD.license_number, OLD.address, OLD.city, OLD.region,
      OLD.owner_is_superintendent, OLD.superintendent_name) THEN
    NEW.verification_status := 'pending';
  END IF;
  IF NEW.verification_status = 'approved' THEN
    NEW.verified_at := coalesce(OLD.verified_at, now()); NEW.rejection_reason := NULL;
  ELSE
    NEW.verified_at := NULL;
    IF NEW.verification_status = 'pending' THEN NEW.rejection_reason := NULL; END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER trg_enforce_business_verification_controls ON public.businesses;
CREATE TRIGGER trg_enforce_business_verification_controls BEFORE INSERT OR UPDATE ON public.businesses
FOR EACH ROW EXECUTE FUNCTION public.enforce_business_verification_controls();

-- Restrictive policy intersects every existing permissive write policy.
CREATE POLICY phase0_wholesaler_product_insert ON public.products AS RESTRICTIVE FOR INSERT TO authenticated
WITH CHECK (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'));
CREATE POLICY phase0_wholesaler_product_update ON public.products AS RESTRICTIVE FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'))
WITH CHECK (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'));
CREATE POLICY phase0_wholesaler_product_delete ON public.products AS RESTRICTIVE FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'));

CREATE FUNCTION public.phase0_product_supplier_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.wholesaler_id IS DISTINCT FROM OLD.wholesaler_id THEN
    RAISE EXCEPTION 'Product supplier is immutable.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase0_product_supplier BEFORE UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION public.phase0_product_supplier_immutable();

CREATE FUNCTION public.phase0_order_item_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
END $$;
CREATE TRIGGER phase0_item_integrity BEFORE INSERT OR UPDATE OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.phase0_order_item_integrity();

CREATE FUNCTION public.phase0_order_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF ROW(NEW.id,NEW.pharmacy_id,NEW.wholesaler_id,NEW.order_number,NEW.total_ghs,NEW.payment_method,NEW.created_at)
    IS DISTINCT FROM ROW(OLD.id,OLD.pharmacy_id,OLD.wholesaler_id,OLD.order_number,OLD.total_ghs,OLD.payment_method,OLD.created_at) THEN
    RAISE EXCEPTION 'Order parties and historical financial fields are immutable.';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
    (OLD.status = 'pending' AND NEW.status IN ('accepted','cancelled')) OR
    (OLD.status = 'accepted' AND NEW.status IN ('packed','cancelled')) OR
    (OLD.status = 'packed' AND NEW.status = 'dispatched') OR
    (OLD.status = 'dispatched' AND NEW.status = 'delivered')) THEN
    RAISE EXCEPTION 'Invalid order transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER aa_phase0_order_integrity BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.phase0_order_integrity();

CREATE OR REPLACE FUNCTION public.restore_stock_for_cancelled_order()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
    UPDATE public.products SET stock = stock + deduction.quantity WHERE id = deduction.product_id AND wholesaler_id = deduction.wholesaler_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Deducted product supplier mismatch.'; END IF;
    UPDATE public.order_stock_deductions SET restored_at = now() WHERE order_id = deduction.order_id AND product_id = deduction.product_id;
  END LOOP;
  RETURN NEW;
END $$;

CREATE FUNCTION public.transition_order(_order_id UUID, _status public.order_status, _reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  SELECT * INTO o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = o.wholesaler_id
    AND b.type = 'wholesaler' AND b.verification_status = 'approved'
    AND (b.owner_id = auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager','cashier'))) THEN
    RAISE EXCEPTION 'Order access denied.';
  END IF;
  IF _status IS NULL THEN RAISE EXCEPTION 'Status is required.'; END IF;
  IF o.status = _status THEN RETURN; END IF;
  UPDATE public.orders SET status = _status,
    cancellation_reason = CASE WHEN _status = 'cancelled' THEN nullif(btrim(_reason),'') ELSE cancellation_reason END
  WHERE id = _order_id;
END $$;
REVOKE ALL ON FUNCTION public.transition_order(UUID,public.order_status,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transition_order(UUID,public.order_status,TEXT) TO authenticated;

CREATE FUNCTION public.confirm_order_payment(_order_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  SELECT * INTO o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = o.wholesaler_id
    AND b.type = 'wholesaler' AND b.verification_status = 'approved'
    AND (b.owner_id = auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager','cashier'))) THEN
    RAISE EXCEPTION 'Order access denied.';
  END IF;
  IF o.status <> 'delivered' OR o.payment_status <> 'unpaid' OR o.payment_method <> 'cod' THEN
    RAISE EXCEPTION 'Only delivered unpaid COD orders can be confirmed.';
  END IF;
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now(), payment_confirmed_by = auth.uid()
    WHERE id = _order_id;
  RETURN _order_id;
END $$;
REVOKE ALL ON FUNCTION public.confirm_order_payment(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_order_payment(UUID) TO authenticated;

-- Pending membership activation belongs to the invited account, not its tenant administrator.
CREATE FUNCTION public.phase0_staff_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF ROW(NEW.id,NEW.business_id,NEW.user_id) IS DISTINCT FROM ROW(OLD.id,OLD.business_id,OLD.user_id) THEN
      RAISE EXCEPTION 'Membership identity is immutable.';
    END IF;
    IF NEW.status = 'active' AND OLD.status <> 'active' AND (OLD.status = 'pending' OR OLD.joined_at IS NULL) AND auth.uid() IS DISTINCT FROM NEW.user_id THEN
      RAISE EXCEPTION 'The invited account must accept its membership.';
    END IF;
  END IF;
  IF NEW.role = 'owner' AND NOT EXISTS (SELECT 1 FROM public.businesses WHERE id = NEW.business_id AND owner_id = NEW.user_id) THEN
    RAISE EXCEPTION 'Owner role is reserved for the business owner.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase0_staff_integrity BEFORE INSERT OR UPDATE ON public.business_staff
FOR EACH ROW EXECUTE FUNCTION public.phase0_staff_integrity();

CREATE FUNCTION public.accept_business_invitations()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE accepted INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = auth.uid() AND email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'A verified signed-in account is required.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.business_staff WHERE user_id = auth.uid() AND status = 'pending' AND role <> 'owner') THEN RETURN 0; END IF;
  IF EXISTS (SELECT 1 FROM public.platform_staff WHERE user_id = auth.uid() AND status IN ('active','pending')) THEN
    RAISE EXCEPTION 'Platform accounts cannot accept business memberships.';
  END IF;
  UPDATE public.business_staff SET status = 'active', joined_at = now()
    WHERE user_id = auth.uid() AND status = 'pending' AND role <> 'owner';
  GET DIAGNOSTICS accepted = ROW_COUNT;
  RETURN accepted;
END $$;
REVOKE ALL ON FUNCTION public.accept_business_invitations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_business_invitations() TO authenticated;

CREATE FUNCTION public.phase0_invalidate_business_evidence()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'updated_at' - 'uploaded_at') = (to_jsonb(OLD) - 'updated_at' - 'uploaded_at') THEN RETURN NEW; END IF;
  IF TG_OP <> 'INSERT' THEN
    UPDATE public.businesses SET verification_status = 'pending', verified_at = NULL, rejection_reason = NULL
      WHERE id = OLD.business_id AND verification_status <> 'pending';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    UPDATE public.businesses SET verification_status = 'pending', verified_at = NULL, rejection_reason = NULL
      WHERE id = NEW.business_id AND verification_status <> 'pending';
    RETURN NEW;
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER phase0_contacts_invalidate AFTER INSERT OR UPDATE OR DELETE ON public.business_private_contacts
FOR EACH ROW EXECUTE FUNCTION public.phase0_invalidate_business_evidence();
CREATE TRIGGER phase0_documents_invalidate AFTER INSERT OR UPDATE OR DELETE ON public.license_documents
FOR EACH ROW EXECUTE FUNCTION public.phase0_invalidate_business_evidence();
REVOKE ALL ON FUNCTION public.phase0_invalidate_business_evidence() FROM PUBLIC, anon, authenticated;

COMMIT;
