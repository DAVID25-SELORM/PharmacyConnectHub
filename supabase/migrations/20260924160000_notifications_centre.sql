-- Notifications centre (in-app).
--
-- * notifications gets a `link` (in-app path to open when clicked).
-- * Recipients are the business owner PLUS active staff with the right roles, not just the owner.
-- * New events: payment confirmed/failed, return workflow, delivery details / proof of delivery,
--   product out of stock, business awaiting verification (admins).
-- * Existing order triggers are rewritten to use the same helper and to notify staff.
-- * Notification triggers can NEVER block the business action that caused them: every trigger
--   body swallows errors and raises a WARNING instead.
-- * Users may only flip `read` on their own notifications (column-level grant); they cannot edit
--   titles, bodies, links or owners.
--
-- Not built: email/SMS/WhatsApp channels, per-user preferences, low-stock threshold alerts
-- (only "out of stock"), security-event and failed-payment-spike alerts.

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS link TEXT
  CHECK (link IS NULL OR (link LIKE '/%' AND link NOT LIKE '//%' AND char_length(link) <= 200));

CREATE INDEX IF NOT EXISTS notifications_user_created_id_idx
  ON public.notifications (user_id, created_at DESC, id DESC);

REVOKE UPDATE ON public.notifications FROM PUBLIC, anon, authenticated;
GRANT UPDATE (read) ON public.notifications TO authenticated;

-- ---------------------------------------------------------------------------
-- Helper: notify a business's owner and active staff with the given roles.
-- The acting user is skipped (nobody needs a notification for their own action).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_business(
  p_business_id UUID,
  p_roles TEXT[],
  p_type TEXT,
  p_title TEXT,
  p_body TEXT,
  p_link TEXT,
  p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
  SELECT DISTINCT r.uid, p_type, p_title, p_body, p_link, COALESCE(p_metadata, '{}'::JSONB)
  FROM (
    SELECT b.owner_id AS uid FROM public.businesses b WHERE b.id = p_business_id
    UNION
    SELECT bs.user_id FROM public.business_staff bs
    WHERE bs.business_id = p_business_id AND bs.status = 'active' AND bs.role::TEXT = ANY (p_roles)
  ) r
  WHERE r.uid IS NOT NULL AND r.uid IS DISTINCT FROM auth.uid();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.notify_business(UUID, TEXT[], TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Orders: new order -> wholesaler team; status change -> pharmacy team
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_new_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy TEXT;
BEGIN
  BEGIN
    SELECT name INTO v_pharmacy FROM public.businesses WHERE id = NEW.pharmacy_id;
    PERFORM public.notify_business(NEW.wholesaler_id, ARRAY['owner', 'manager', 'cashier'], 'new_order', 'New order received',
      'Order #' || NEW.order_number || ' from ' || COALESCE(v_pharmacy, 'a pharmacy') || ' - GHS ' || to_char(NEW.total_ghs, 'FM999,999.00'),
      '/wholesaler?tab=orders', jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_new_order failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_order_status_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wholesaler TEXT;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  BEGIN
    SELECT name INTO v_wholesaler FROM public.businesses WHERE id = NEW.wholesaler_id;
    PERFORM public.notify_business(NEW.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_status', 'Order update',
      'Your order #' || NEW.order_number || ' from ' || COALESCE(v_wholesaler, 'your wholesaler') || ' is now ' ||
        CASE NEW.status::TEXT
          WHEN 'accepted' THEN 'accepted'
          WHEN 'packed' THEN 'packed and ready'
          WHEN 'dispatched' THEN 'out for delivery'
          WHEN 'delivered' THEN 'delivered'
          WHEN 'cancelled' THEN 'cancelled'
          ELSE NEW.status::TEXT
        END || '.',
      '/pharmacy?tab=orders', jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number, 'status', NEW.status));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_order_status_changed failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Payments: paid / failed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_payment_status_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.payment_status IS NOT DISTINCT FROM OLD.payment_status OR NEW.payment_status::TEXT NOT IN ('paid', 'failed') THEN
    RETURN NEW;
  END IF;
  BEGIN
    IF NEW.payment_status::TEXT = 'paid' THEN
      PERFORM public.notify_business(NEW.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Payment confirmed',
        'Payment for order #' || NEW.order_number || ' has been confirmed.', '/pharmacy?tab=orders',
        jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number));
      IF NEW.payment_method::TEXT = 'paystack' THEN
        PERFORM public.notify_business(NEW.wholesaler_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Payment received',
          'Online payment received for order #' || NEW.order_number || '.', '/wholesaler?tab=orders',
          jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number));
      END IF;
    ELSE
      PERFORM public.notify_business(NEW.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Payment failed',
        'Payment for order #' || NEW.order_number || ' did not go through.', '/pharmacy?tab=orders',
        jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_payment_status_changed failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_payment_status ON public.orders;
CREATE TRIGGER trg_notify_payment_status
  AFTER UPDATE OF payment_status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.notify_payment_status_changed();

-- ---------------------------------------------------------------------------
-- Returns
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_return_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy TEXT;
  v_order TEXT;
  v_meta JSONB := jsonb_build_object('return_id', NEW.id, 'return_number', NEW.return_number);
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      SELECT name INTO v_pharmacy FROM public.businesses WHERE id = NEW.pharmacy_id;
      SELECT order_number INTO v_order FROM public.orders WHERE id = NEW.order_id;
      PERFORM public.notify_business(NEW.wholesaler_id, ARRAY['owner', 'manager', 'cashier'], 'return_requested', 'Return requested',
        COALESCE(v_pharmacy, 'A pharmacy') || ' requested a return (' || NEW.return_number || ') for order #' || COALESCE(v_order, '') || '.',
        '/wholesaler?tab=returns', v_meta);
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status = 'cancelled' THEN
        PERFORM public.notify_business(NEW.wholesaler_id, ARRAY['owner', 'manager', 'cashier'], 'return_requested', 'Return cancelled',
          'Return ' || NEW.return_number || ' was cancelled by the pharmacy.', '/wholesaler?tab=returns', v_meta);
      ELSIF NEW.status IN ('approved', 'rejected', 'returned', 'resolved') THEN
        PERFORM public.notify_business(NEW.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'return_update',
          CASE NEW.status WHEN 'approved' THEN 'Return approved' WHEN 'rejected' THEN 'Return rejected'
            WHEN 'returned' THEN 'Return goods received' ELSE 'Return resolved' END,
          'Return ' || NEW.return_number || CASE NEW.status
            WHEN 'approved' THEN ' was approved. Please send the goods back.'
            WHEN 'rejected' THEN ' was rejected.' || COALESCE(' Reason: ' || NEW.wholesaler_note, '')
            WHEN 'returned' THEN ' - the supplier has received the goods.'
            ELSE ' was resolved: ' || COALESCE(NEW.resolution, '') || '.' END,
          '/pharmacy?tab=returns', v_meta);
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_return_changed failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_return_changed ON public.order_returns;
CREATE TRIGGER trg_notify_return_changed
  AFTER INSERT OR UPDATE OF status ON public.order_returns
  FOR EACH ROW EXECUTE FUNCTION public.notify_return_changed();

-- ---------------------------------------------------------------------------
-- Delivery details / proof of delivery -> pharmacy
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_delivery_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_dispatch_changed BOOLEAN;
  v_proof_changed BOOLEAN;
BEGIN
  BEGIN
    SELECT o.id, o.order_number, o.pharmacy_id INTO v_order FROM public.orders o WHERE o.id = NEW.order_id;
    v_dispatch_changed := (NEW.driver_name, NEW.driver_phone, NEW.delivery_reference, NEW.expected_delivery_at)
      IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.driver_name END, CASE WHEN TG_OP = 'UPDATE' THEN OLD.driver_phone END,
                        CASE WHEN TG_OP = 'UPDATE' THEN OLD.delivery_reference END, CASE WHEN TG_OP = 'UPDATE' THEN OLD.expected_delivery_at END);
    v_proof_changed := (NEW.received_by_name, NEW.received_at)
      IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.received_by_name END, CASE WHEN TG_OP = 'UPDATE' THEN OLD.received_at END);

    IF v_proof_changed AND NEW.received_by_name IS NOT NULL THEN
      PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'delivery_update', 'Delivery confirmed',
        'Order #' || v_order.order_number || ' was recorded as received by ' || NEW.received_by_name || '.', '/pharmacy?tab=orders',
        jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number));
    ELSIF v_dispatch_changed AND (NEW.driver_name IS NOT NULL OR NEW.delivery_reference IS NOT NULL OR NEW.expected_delivery_at IS NOT NULL) THEN
      PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'delivery_update', 'Delivery details updated',
        'Delivery details for order #' || v_order.order_number || COALESCE(' - driver ' || NEW.driver_name, '') || ' are available.', '/pharmacy?tab=orders',
        jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_delivery_changed failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_delivery_changed ON public.order_deliveries;
CREATE TRIGGER trg_notify_delivery_changed
  AFTER INSERT OR UPDATE ON public.order_deliveries
  FOR EACH ROW EXECUTE FUNCTION public.notify_delivery_changed();

-- ---------------------------------------------------------------------------
-- Product just went out of stock -> wholesaler owner/managers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_product_out_of_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM public.notify_business(NEW.wholesaler_id, ARRAY['owner', 'manager'], 'low_stock', 'Product out of stock',
      NEW.name || ' has run out of stock.', '/wholesaler?tab=insights',
      jsonb_build_object('product_id', NEW.id, 'product_name', NEW.name));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_product_out_of_stock failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_product_out_of_stock ON public.products;
CREATE TRIGGER trg_notify_product_out_of_stock
  AFTER UPDATE OF stock ON public.products
  FOR EACH ROW WHEN (OLD.stock > 0 AND NEW.stock <= 0)
  EXECUTE FUNCTION public.notify_product_out_of_stock();

-- ---------------------------------------------------------------------------
-- Business awaiting verification (new or resubmitted) -> platform admins
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_admins_business_pending()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.verification_status::TEXT <> 'pending' OR (TG_OP = 'UPDATE' AND OLD.verification_status IS NOT DISTINCT FROM NEW.verification_status) THEN
    RETURN NEW;
  END IF;
  BEGIN
    INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
    SELECT ur.user_id, 'verification_pending',
      CASE WHEN TG_OP = 'INSERT' THEN 'Business awaiting verification' ELSE 'Business resubmitted for verification' END,
      NEW.name || ' (' || NEW.type::TEXT || ') is waiting for review.', '/admin',
      jsonb_build_object('business_id', NEW.id, 'business_name', NEW.name)
    FROM public.user_roles ur
    WHERE ur.role::TEXT = 'admin' AND ur.user_id IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_admins_business_pending failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_admins_business_pending ON public.businesses;
CREATE TRIGGER trg_notify_admins_business_pending
  AFTER INSERT OR UPDATE OF verification_status ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.notify_admins_business_pending();

-- The verification-approved/rejected trigger from the original migration keeps working; give its
-- messages a link too (none needed: the owner is taken to their workspace by the app).
