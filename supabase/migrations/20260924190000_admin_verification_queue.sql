-- Admin verification queue: one paged, server-side list of businesses that still need a decision.
--
-- Includes pending and rejected businesses (approved ones are out of the queue). For each row:
--   * submitted_at = the latest "Verification resubmitted" event, else the business's creation time,
--     so a resubmission goes to the back of the line by date but is flagged as resubmitted;
--   * waiting_days for pending rows = whole days since submitted_at;
--   * docs_uploaded / docs_required using the same required-document lists as the onboarding page:
--       pharmacy   : pharmacy_council, business_registration
--       wholesaler : wholesale_license, fda_certificate, business_registration
-- Approve / reject still go through the existing verification controls on businesses (admin only,
-- audit-logged); this function only reads. Every row also carries whole-queue summary counts.

CREATE OR REPLACE FUNCTION public.admin_verification_queue(
  p_status TEXT DEFAULT 'pending',
  p_type TEXT DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_sort TEXT DEFAULT 'oldest',
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  business_id UUID,
  business_name TEXT,
  business_type TEXT,
  city TEXT,
  region TEXT,
  license_number TEXT,
  status TEXT,
  is_resubmitted BOOLEAN,
  submitted_at TIMESTAMPTZ,
  first_submitted_at TIMESTAMPTZ,
  waiting_days INTEGER,
  docs_uploaded INTEGER,
  docs_required INTEGER,
  rejection_reason TEXT,
  summary_pending BIGINT,
  summary_new BIGINT,
  summary_resubmitted BIGINT,
  summary_rejected BIGINT,
  summary_longest_wait_days INTEGER,
  total_count BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  v_search TEXT := NULLIF(btrim(COALESCE(p_search, '')), '');
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view the verification queue.';
  END IF;
  IF p_status NOT IN ('pending', 'new', 'resubmitted', 'rejected', 'all') THEN
    RAISE EXCEPTION 'Unknown queue status.';
  END IF;
  IF p_type IS NOT NULL AND p_type NOT IN ('pharmacy', 'wholesaler') THEN
    RAISE EXCEPTION 'Unknown business type.';
  END IF;
  IF p_sort NOT IN ('oldest', 'newest', 'name') THEN
    RAISE EXCEPTION 'Unknown sort order.';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      b.id AS bid, b.name AS bname, b.type::TEXT AS btype, b.city AS bcity, b.region AS bregion, b.license_number AS blic,
      b.verification_status::TEXT AS bstatus, b.rejection_reason AS breason, b.created_at AS created,
      r.last_resubmitted,
      COALESCE(r.last_resubmitted, b.created_at) AS submitted,
      (r.last_resubmitted IS NOT NULL) AS resub,
      d.uploaded,
      CASE WHEN b.type::TEXT = 'pharmacy' THEN 2 ELSE 3 END AS required
    FROM public.businesses b
    LEFT JOIN LATERAL (
      SELECT MAX(a.created_at) AS last_resubmitted FROM public.audit_logs a
      WHERE a.record_type = 'business' AND a.record_id = b.id AND a.activity = 'Verification resubmitted'
    ) r ON TRUE
    LEFT JOIN LATERAL (
      SELECT COUNT(DISTINCT ld.doc_type)::INTEGER AS uploaded FROM public.license_documents ld
      WHERE ld.business_id = b.id
        AND ld.doc_type = ANY (CASE WHEN b.type::TEXT = 'pharmacy'
          THEN ARRAY['pharmacy_council', 'business_registration']
          ELSE ARRAY['wholesale_license', 'fda_certificate', 'business_registration'] END)
    ) d ON TRUE
    WHERE b.verification_status::TEXT IN ('pending', 'rejected')
  ),
  summary AS (
    SELECT base.*,
      COUNT(*) FILTER (WHERE base.bstatus = 'pending') OVER () AS s_pending,
      COUNT(*) FILTER (WHERE base.bstatus = 'pending' AND NOT base.resub) OVER () AS s_new,
      COUNT(*) FILTER (WHERE base.bstatus = 'pending' AND base.resub) OVER () AS s_resub,
      COUNT(*) FILTER (WHERE base.bstatus = 'rejected') OVER () AS s_rejected,
      MAX(floor(extract(epoch FROM (now() - base.submitted)) / 86400)::INTEGER) FILTER (WHERE base.bstatus = 'pending') OVER () AS s_longest
    FROM base
  ),
  filtered AS (
    SELECT s.* FROM summary s
    WHERE (p_type IS NULL OR s.btype = p_type)
      AND (v_search IS NULL OR s.bname ILIKE '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%'
           OR COALESCE(s.blic, '') ILIKE '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      AND CASE p_status
            WHEN 'pending' THEN s.bstatus = 'pending'
            WHEN 'new' THEN s.bstatus = 'pending' AND NOT s.resub
            WHEN 'resubmitted' THEN s.bstatus = 'pending' AND s.resub
            WHEN 'rejected' THEN s.bstatus = 'rejected'
            ELSE TRUE END
  )
  SELECT f.bid, f.bname, f.btype, f.bcity, f.bregion, f.blic, f.bstatus, f.resub, f.submitted, f.created,
    CASE WHEN f.bstatus = 'pending' THEN floor(extract(epoch FROM (now() - f.submitted)) / 86400)::INTEGER END,
    COALESCE(f.uploaded, 0), f.required, f.breason,
    f.s_pending, f.s_new, f.s_resub, f.s_rejected, COALESCE(f.s_longest, 0), COUNT(*) OVER ()
  FROM filtered f
  ORDER BY
    CASE WHEN p_sort = 'oldest' THEN f.submitted END ASC,
    CASE WHEN p_sort = 'newest' THEN f.submitted END DESC,
    CASE WHEN p_sort = 'name' THEN lower(f.bname) END ASC,
    f.bid ASC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_verification_queue(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_verification_queue(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
