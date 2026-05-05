-- Platform audit log for admin activity visibility.
-- Captures actor and request IP where Supabase request context is available.

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  activity TEXT NOT NULL,
  organization TEXT,
  performed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  performed_by_email TEXT,
  record_type TEXT NOT NULL,
  record_id UUID,
  record_label TEXT,
  ip_address TEXT,
  details JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at
  ON public.audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_record
  ON public.audit_logs(record_type, record_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_performed_by
  ON public.audit_logs(performed_by, created_at DESC)
  WHERE performed_by IS NOT NULL;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins see audit logs" ON public.audit_logs;
CREATE POLICY "Admins see audit logs"
  ON public.audit_logs
  FOR SELECT
  USING (public.has_role(auth.uid(), 'admin'));

REVOKE ALL ON public.audit_logs FROM PUBLIC;
GRANT SELECT ON public.audit_logs TO authenticated;
GRANT INSERT ON public.audit_logs TO service_role;

CREATE OR REPLACE FUNCTION public.current_request_ip_address()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  request_headers JSONB;
  forwarded_for TEXT;
BEGIN
  request_headers := COALESCE(NULLIF(current_setting('request.headers', true), '')::JSONB, '{}'::JSONB);
  forwarded_for := NULLIF(BTRIM(request_headers->>'x-forwarded-for'), '');

  IF forwarded_for IS NOT NULL THEN
    RETURN NULLIF(BTRIM(split_part(forwarded_for, ',', 1)), '');
  END IF;

  RETURN COALESCE(
    NULLIF(BTRIM(request_headers->>'cf-connecting-ip'), ''),
    NULLIF(BTRIM(request_headers->>'x-real-ip'), '')
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.current_actor_email()
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT email
  FROM auth.users
  WHERE id = auth.uid()
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.write_audit_log(
  _activity TEXT,
  _organization TEXT,
  _record_type TEXT,
  _record_id UUID,
  _record_label TEXT,
  _details JSONB DEFAULT '{}'::JSONB,
  _performed_by UUID DEFAULT auth.uid(),
  _performed_by_email TEXT DEFAULT public.current_actor_email(),
  _ip_address TEXT DEFAULT public.current_request_ip_address()
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.audit_logs (
    activity,
    organization,
    performed_by,
    performed_by_email,
    record_type,
    record_id,
    record_label,
    ip_address,
    details
  )
  VALUES (
    _activity,
    _organization,
    _performed_by,
    _performed_by_email,
    _record_type,
    _record_id,
    _record_label,
    _ip_address,
    COALESCE(_details, '{}'::JSONB)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.audit_business_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      CASE WHEN NEW.type = 'pharmacy' THEN 'Pharmacy submitted' ELSE 'Wholesaler submitted' END,
      NEW.name,
      'business',
      NEW.id,
      COALESCE(NEW.license_number, NEW.id::TEXT),
      jsonb_build_object(
        'business_type', NEW.type,
        'city', NEW.city,
        'region', NEW.region,
        'verification_status', NEW.verification_status
      ),
      NEW.owner_id,
      NULL,
      public.current_request_ip_address()
    );
    RETURN NEW;
  END IF;

  IF NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
    PERFORM public.write_audit_log(
      CASE
        WHEN NEW.verification_status = 'approved' THEN 'Business approved'
        WHEN NEW.verification_status = 'rejected' THEN 'Business rejected'
        ELSE 'Business verification updated'
      END,
      NEW.name,
      'business',
      NEW.id,
      COALESCE(NEW.license_number, NEW.id::TEXT),
      jsonb_build_object(
        'from_status', OLD.verification_status,
        'to_status', NEW.verification_status,
        'rejection_reason', NEW.rejection_reason
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_business_changes ON public.businesses;
CREATE TRIGGER trg_audit_business_changes
  AFTER INSERT OR UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_business_changes();

CREATE OR REPLACE FUNCTION public.audit_order_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pharmacy_name TEXT;
  wholesaler_name TEXT;
BEGIN
  SELECT name INTO pharmacy_name FROM public.businesses WHERE id = NEW.pharmacy_id;
  SELECT name INTO wholesaler_name FROM public.businesses WHERE id = NEW.wholesaler_id;

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Order placed',
      COALESCE(pharmacy_name, 'Pharmacy'),
      'order',
      NEW.id,
      NEW.order_number,
      jsonb_build_object(
        'status', NEW.status,
        'payment_status', NEW.payment_status,
        'payment_method', NEW.payment_method,
        'total_ghs', NEW.total_ghs,
        'wholesaler', wholesaler_name
      )
    );
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Order ' || NEW.status::TEXT,
      COALESCE(pharmacy_name, 'Pharmacy'),
      'order',
      NEW.id,
      NEW.order_number,
      jsonb_build_object(
        'from_status', OLD.status,
        'to_status', NEW.status,
        'total_ghs', NEW.total_ghs,
        'wholesaler', wholesaler_name,
        'cancellation_reason', NEW.cancellation_reason
      )
    );
  END IF;

  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status THEN
    PERFORM public.write_audit_log(
      'Payment ' || NEW.payment_status::TEXT,
      COALESCE(pharmacy_name, 'Pharmacy'),
      'order',
      NEW.id,
      NEW.order_number,
      jsonb_build_object(
        'from_payment_status', OLD.payment_status,
        'to_payment_status', NEW.payment_status,
        'total_ghs', NEW.total_ghs,
        'wholesaler', wholesaler_name
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_order_changes ON public.orders;
CREATE TRIGGER trg_audit_order_changes
  AFTER INSERT OR UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_order_changes();

CREATE OR REPLACE FUNCTION public.audit_business_staff_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  business_name TEXT;
  staff_email TEXT;
BEGIN
  SELECT name INTO business_name FROM public.businesses WHERE id = COALESCE(NEW.business_id, OLD.business_id);
  SELECT email INTO staff_email FROM auth.users WHERE id = COALESCE(NEW.user_id, OLD.user_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Business staff invited',
      business_name,
      'business_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object('role', NEW.role, 'status', NEW.status)
    );
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Business staff updated',
      business_name,
      'business_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object(
        'from_role', OLD.role,
        'to_role', NEW.role,
        'from_status', OLD.status,
        'to_status', NEW.status
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_business_staff_changes ON public.business_staff;
CREATE TRIGGER trg_audit_business_staff_changes
  AFTER INSERT OR UPDATE ON public.business_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_business_staff_changes();

CREATE OR REPLACE FUNCTION public.audit_platform_staff_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  staff_email TEXT;
BEGIN
  SELECT email INTO staff_email FROM auth.users WHERE id = COALESCE(NEW.user_id, OLD.user_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Platform staff invited',
      'PharmaHub GH',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object('role', NEW.role, 'status', NEW.status)
    );
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Platform staff updated',
      'PharmaHub GH',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object(
        'from_role', OLD.role,
        'to_role', NEW.role,
        'from_status', OLD.status,
        'to_status', NEW.status
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_platform_staff_changes ON public.platform_staff;
CREATE TRIGGER trg_audit_platform_staff_changes
  AFTER INSERT OR UPDATE ON public.platform_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_platform_staff_changes();
