-- Isolated database only: legacy production guard captured via Chrome catalog review.
CREATE OR REPLACE FUNCTION public.phase0_order_integrity() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public' AS $$
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
