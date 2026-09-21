-- Scalable, admin-only activity log access.
--
-- * admin_list_activity(): server-side filtering + keyset pagination on (created_at, id).
--   Every call is bounded by its page size, whatever the size of audit_logs.
-- * admin_get_activity(): one full record (drawer), incl. IP address.
-- * admin_platform_summary(): dashboard KPIs computed in the database (the dashboard used to
--   derive them from a client-side sample of 25 orders).
-- * redact_audit_details(): secrets are stripped from metadata before it leaves the database.
-- audit_logs itself is unchanged and stays append-only; nothing here writes to it.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Main keyset order (dashboard preview + unfiltered history).
CREATE INDEX IF NOT EXISTS audit_logs_created_id_idx
  ON public.audit_logs (created_at DESC, id DESC);

-- Organization filter, newest first.
CREATE INDEX IF NOT EXISTS audit_logs_org_created_idx
  ON public.audit_logs (organization, created_at DESC, id DESC);

-- Actor filter (by email, case-insensitive). Without it a rare actor scans the whole table
-- (measured: 334 ms on 300k rows, vs 0.05 ms with this index).
CREATE INDEX IF NOT EXISTS audit_logs_actor_email_created_idx
  ON public.audit_logs (lower(performed_by_email), created_at DESC, id DESC);

-- Event-type filter, newest first.
CREATE INDEX IF NOT EXISTS audit_logs_activity_created_idx
  ON public.audit_logs (activity, created_at DESC, id DESC);

-- Free-text search over the four human-readable columns only (never over the details JSON).
-- One trigram index serves ILIKE '%term%' on the same expression.
CREATE INDEX IF NOT EXISTS audit_logs_search_trgm_idx
  ON public.audit_logs USING gin (
    (COALESCE(organization, '') || ' ' || COALESCE(performed_by_email, '') || ' ' ||
     COALESCE(record_label, '') || ' ' || activity) gin_trgm_ops
  );

-- ---------------------------------------------------------------------------
-- Redaction of secrets in audit metadata (recursive, keys only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redact_audit_details(_details JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  result JSONB;
BEGIN
  IF _details IS NULL THEN
    RETURN NULL;
  END IF;

  IF jsonb_typeof(_details) = 'object' THEN
    SELECT COALESCE(jsonb_object_agg(
      e.key,
      CASE
        WHEN e.key ~* '(token|secret|password|passwd|authorization|api[_-]?key|service[_-]?role|smtp|credential|private[_-]?key|bearer|cookie)'
          THEN '"[redacted]"'::JSONB
        ELSE public.redact_audit_details(e.value)
      END
    ), '{}'::JSONB)
    INTO result
    FROM jsonb_each(_details) AS e;
    RETURN result;
  END IF;

  IF jsonb_typeof(_details) = 'array' THEN
    SELECT COALESCE(jsonb_agg(public.redact_audit_details(x)), '[]'::JSONB)
    INTO result
    FROM jsonb_array_elements(_details) AS x;
    RETURN result;
  END IF;

  RETURN _details;
END;
$$;

-- ---------------------------------------------------------------------------
-- Activity list (keyset pagination, server-side filters)
-- Returns up to p_limit + 1 rows so the caller can tell whether another page exists.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_activity(
  p_search TEXT DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_activity TEXT DEFAULT NULL,
  p_organization TEXT DEFAULT NULL,
  p_org_type TEXT DEFAULT NULL,
  p_actor TEXT DEFAULT NULL,
  p_range TEXT DEFAULT NULL,
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_cursor_created_at TIMESTAMPTZ DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  created_at TIMESTAMPTZ,
  activity TEXT,
  organization TEXT,
  performed_by_email TEXT,
  record_type TEXT,
  record_id UUID,
  record_label TEXT,
  details JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
  v_where TEXT[] := ARRAY[]::TEXT[];
  v_patterns TEXT[];
  v_term TEXT := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_sql TEXT;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view the activity log.';
  END IF;

  -- Free-text search: 2+ characters, matched against organization, actor, record and event.
  IF v_term IS NOT NULL THEN
    IF length(v_term) < 2 THEN
      RAISE EXCEPTION 'Search needs at least 2 characters.';
    END IF;
    v_where := array_append(v_where, $c$(COALESCE(a.organization, '') || ' ' || COALESCE(a.performed_by_email, '') || ' ' || COALESCE(a.record_label, '') || ' ' || a.activity) ILIKE '%' || $1 || '%'$c$);
    v_term := replace(replace(replace(v_term, '\', '\\'), '%', '\%'), '_', '\_');
  END IF;

  IF NULLIF(p_category, '') IS NOT NULL THEN
    v_patterns := CASE lower(p_category)
      WHEN 'verification' THEN ARRAY['Pharmacy submitted', 'Wholesaler submitted', 'Business approved', 'Business rejected', 'Business verification updated', 'Verification resubmitted']
      WHEN 'orders'       THEN ARRAY['Order placed', 'Order pending', 'Order accepted', 'Order packed', 'Order dispatched', 'Order delivered', 'Order cancelled']
      WHEN 'payments'     THEN ARRAY['Payment unpaid', 'Payment paid', 'Payment refunded', 'Payment failed']
      WHEN 'staff'        THEN ARRAY['Business staff invited', 'Business staff updated', 'Platform staff invited', 'Platform staff updated']
      WHEN 'inventory'    THEN ARRAY['Inventory imported']
      ELSE NULL
    END;
    IF v_patterns IS NULL THEN
      RAISE EXCEPTION 'Unknown activity category.';
    END IF;
    v_where := array_append(v_where, 'a.activity = ANY ($2)');
  END IF;

  IF NULLIF(p_activity, '') IS NOT NULL THEN
    v_where := array_append(v_where, 'a.activity = $3');
  END IF;

  IF NULLIF(p_organization, '') IS NOT NULL THEN
    v_where := array_append(v_where, 'a.organization = $4');
  END IF;

  IF NULLIF(p_org_type, '') IS NOT NULL THEN
    IF p_org_type NOT IN ('pharmacy', 'wholesaler') THEN
      RAISE EXCEPTION 'Unknown organization type.';
    END IF;
    v_where := array_append(v_where, 'a.organization IN (SELECT b.name FROM public.businesses b WHERE b.type = $5::public.business_type)');
  END IF;

  IF NULLIF(p_actor, '') IS NOT NULL THEN
    IF lower(p_actor) = 'system' THEN
      v_where := array_append(v_where, 'a.performed_by IS NULL');
    ELSE
      v_where := array_append(v_where, 'lower(a.performed_by_email) = lower($6)');
    END IF;
  END IF;

  -- Date range from database time (Africa/Accra is UTC+0, so UTC day boundaries are local days).
  IF p_range = 'today' THEN
    v_where := array_append(v_where, $c$a.created_at >= date_trunc('day', now())$c$);
  ELSIF p_range = '7d' THEN
    v_where := array_append(v_where, $c$a.created_at >= now() - interval '7 days'$c$);
  ELSIF p_range = '30d' THEN
    v_where := array_append(v_where, $c$a.created_at >= now() - interval '30 days'$c$);
  ELSIF p_range = 'custom' THEN
    IF p_from IS NOT NULL THEN v_where := array_append(v_where, 'a.created_at >= $7'); END IF;
    IF p_to IS NOT NULL THEN v_where := array_append(v_where, 'a.created_at < $8'); END IF;
  END IF;

  -- Keyset cursor: strictly older than the last row of the previous page.
  IF p_cursor_created_at IS NOT NULL AND p_cursor_id IS NOT NULL THEN
    v_where := array_append(v_where, '(a.created_at, a.id) < ($9, $10)');
  END IF;

  v_sql := 'SELECT a.id, a.created_at, a.activity, a.organization, a.performed_by_email, '
    || 'a.record_type, a.record_id, a.record_label, public.redact_audit_details(a.details) '
    || 'FROM public.audit_logs a '
    || CASE WHEN cardinality(v_where) > 0 THEN 'WHERE ' || array_to_string(v_where, ' AND ') ELSE '' END
    || ' ORDER BY a.created_at DESC, a.id DESC LIMIT ' || (v_limit + 1);

  RETURN QUERY EXECUTE v_sql
    USING v_term, v_patterns, p_activity, p_organization, p_org_type, p_actor,
          p_from, p_to, p_cursor_created_at, p_cursor_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- One full activity record (detail drawer)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_activity(p_id UUID)
RETURNS TABLE (
  id UUID,
  created_at TIMESTAMPTZ,
  activity TEXT,
  organization TEXT,
  performed_by UUID,
  performed_by_email TEXT,
  record_type TEXT,
  record_id UUID,
  record_label TEXT,
  ip_address TEXT,
  details JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view the activity log.';
  END IF;

  RETURN QUERY
  SELECT a.id, a.created_at, a.activity, a.organization, a.performed_by, a.performed_by_email,
         a.record_type, a.record_id, a.record_label, a.ip_address,
         public.redact_audit_details(a.details)
  FROM public.audit_logs a
  WHERE a.id = p_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Dashboard KPIs (aggregates only; SECURITY DEFINER so RLS cannot hide rows from the count,
-- with the admin check made explicit)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_platform_summary()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view the platform summary.';
  END IF;

  SELECT jsonb_build_object(
    'pharmacies', jsonb_build_object(
      'total', COUNT(*) FILTER (WHERE b.type = 'pharmacy'),
      'approved', COUNT(*) FILTER (WHERE b.type = 'pharmacy' AND b.verification_status = 'approved'),
      'pending', COUNT(*) FILTER (WHERE b.type = 'pharmacy' AND b.verification_status = 'pending'),
      'rejected', COUNT(*) FILTER (WHERE b.type = 'pharmacy' AND b.verification_status = 'rejected')
    ),
    'wholesalers', jsonb_build_object(
      'total', COUNT(*) FILTER (WHERE b.type = 'wholesaler'),
      'approved', COUNT(*) FILTER (WHERE b.type = 'wholesaler' AND b.verification_status = 'approved'),
      'pending', COUNT(*) FILTER (WHERE b.type = 'wholesaler' AND b.verification_status = 'pending'),
      'rejected', COUNT(*) FILTER (WHERE b.type = 'wholesaler' AND b.verification_status = 'rejected')
    ),
    'resubmitted_pending', COUNT(*) FILTER (
      WHERE b.verification_status = 'pending'
        AND EXISTS (
          SELECT 1 FROM public.audit_logs a
          WHERE a.record_type = 'business' AND a.record_id = b.id AND a.activity = 'Verification resubmitted'
        )
    )
  )
  INTO v_result
  FROM public.businesses b;

  RETURN v_result || (
    SELECT jsonb_build_object(
      'orders_total', COUNT(*),
      'gmv_ghs', COALESCE(SUM(o.total_ghs), 0)
    )
    FROM public.orders o
  );
END;
$$;

-- Only signed-in users can call these; each function also checks the admin role itself.
-- (Supabase grants new functions to anon by default, so it is revoked explicitly.)
-- redact_audit_details is a pure helper called by the INVOKER functions below, so signed-in users need EXECUTE.
REVOKE ALL ON FUNCTION public.redact_audit_details(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redact_audit_details(JSONB) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_list_activity(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, UUID, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_get_activity(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_platform_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_activity(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_activity(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_platform_summary() TO authenticated;
