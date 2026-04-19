-- Fix notify_new_order and notify_order_status_changed to avoid DECLARE/SELECT INTO
-- which can be misinterpreted by the Supabase SQL editor.
-- Rewritten to use INSERT ... SELECT with direct joins, no intermediate variables.

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
      ' — GHS ' || to_char(NEW.total_ghs, 'FM999,999.00'),
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
