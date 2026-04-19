-- In-app notifications for verification status changes, new orders, and order status updates.

CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  read BOOLEAN NOT NULL DEFAULT false,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user
  ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON public.notifications(user_id) WHERE NOT read;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users see own notifications"
  ON public.notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users update own notifications"
  ON public.notifications FOR UPDATE
  USING (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Trigger: business verification status changed -> notify business owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_business_verification_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.verification_status IS NOT DISTINCT FROM OLD.verification_status THEN
    RETURN NEW;
  END IF;

  IF NEW.verification_status = 'approved' THEN
    INSERT INTO public.notifications(user_id, type, title, body, metadata)
    VALUES (
      NEW.owner_id,
      'business_approved',
      'Application approved',
      'Your business "' || NEW.name || '" has been verified. You now have full access to the marketplace.',
      jsonb_build_object('business_id', NEW.id, 'business_name', NEW.name)
    );
  ELSIF NEW.verification_status = 'rejected' THEN
    INSERT INTO public.notifications(user_id, type, title, body, metadata)
    VALUES (
      NEW.owner_id,
      'business_rejected',
      'Application not approved',
      CASE
        WHEN NEW.rejection_reason IS NOT NULL AND NEW.rejection_reason <> ''
        THEN 'Your application for "' || NEW.name || '" was not approved. Reason: ' || NEW.rejection_reason
        ELSE 'Your application for "' || NEW.name || '" was not approved. Please contact support.'
      END,
      jsonb_build_object('business_id', NEW.id, 'business_name', NEW.name)
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_business_verification ON public.businesses;
CREATE TRIGGER trg_notify_business_verification
  AFTER UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_business_verification_changed();

-- ---------------------------------------------------------------------------
-- Trigger: new order placed -> notify wholesaler owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_new_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.notifications(user_id, type, title, body, metadata)
  SELECT
    w.owner_id,
    'new_order',
    'New order received',
    'Order #' || NEW.order_number || ' from ' || COALESCE(ph.name, 'a pharmacy') ||
      ' - GHS ' || to_char(NEW.total_ghs, 'FM999,999.00'),
    jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number)
  FROM public.businesses w
  LEFT JOIN public.businesses ph ON ph.id = NEW.pharmacy_id
  WHERE w.id = NEW.wholesaler_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_new_order ON public.orders;
CREATE TRIGGER trg_notify_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_new_order();

-- ---------------------------------------------------------------------------
-- Trigger: order status changed -> notify pharmacy owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_order_status_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications(user_id, type, title, body, metadata)
  SELECT
    ph.owner_id,
    'order_status',
    'Order update',
    'Your order #' || NEW.order_number || ' from ' || COALESCE(w.name, 'your wholesaler') ||
      ' is now ' || CASE NEW.status
        WHEN 'accepted'   THEN 'accepted'
        WHEN 'packed'     THEN 'packed and ready'
        WHEN 'dispatched' THEN 'out for delivery'
        WHEN 'delivered'  THEN 'delivered'
        WHEN 'cancelled'  THEN 'cancelled'
        ELSE NEW.status::TEXT
      END || '.',
    jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number, 'status', NEW.status)
  FROM public.businesses ph
  LEFT JOIN public.businesses w ON w.id = NEW.wholesaler_id
  WHERE ph.id = NEW.pharmacy_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_order_status ON public.orders;
CREATE TRIGGER trg_notify_order_status
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_order_status_changed();
