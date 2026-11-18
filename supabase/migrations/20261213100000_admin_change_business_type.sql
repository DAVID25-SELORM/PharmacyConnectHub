-- Let a platform admin correct a business that registered as the wrong type
-- (pharmacy <-> wholesaler). It is a correction tool for a business that is still empty, not a way
-- to convert a trading business:
--
--   * Admin only (has_role 'admin'); every call is audit-logged with the old type, new type and reason.
--   * A business that already has ANY data cannot be switched. "Data" is found by scanning every
--     table that has a foreign key to businesses(id), so tables added later are covered
--     automatically. Only registration paperwork is ignored: the audit trail, private contacts,
--     uploaded licence documents, staff rows and document branding.
--   * An approved business goes back to 'pending' after the switch, because the required documents
--     differ per type (pharmacy: pharmacy_council + business_registration; wholesaler:
--     wholesale_license + fda_certificate + business_registration) and the licence that was
--     verified belongs to the old type. An admin re-approves it from the normal queue.
--   * The owner's app_role row follows the type: the new role is added, and the old one is removed
--     only when the owner has no other business of the old type.
--
-- A business that needs to be BOTH is not a switch: one login can own several businesses
-- (create_additional_business), so register a second business of the other type instead.

-- 1) Why can't this business be switched? One row per table/column that holds data for it.
CREATE OR REPLACE FUNCTION public.admin_business_type_blockers(p_business_id UUID)
RETURNS TABLE (source_table TEXT, source_column TEXT, row_count BIGINT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fk RECORD;
  v_count BIGINT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can check a business type change.';
  END IF;

  FOR v_fk IN
    SELECT cls.relname::TEXT AS table_name, att.attname::TEXT AS column_name
    FROM pg_constraint con
    JOIN pg_class cls ON cls.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = cls.relnamespace
    JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
    WHERE con.contype = 'f'
      AND con.confrelid = 'public.businesses'::regclass
      AND array_length(con.conkey, 1) = 1
      AND ns.nspname = 'public'
      AND cls.relkind IN ('r', 'p')
      AND cls.relname NOT IN (
        'audit_logs',
        'business_private_contacts',
        'license_documents',
        'business_staff',
        'business_document_branding',
        'document_branding_assets',
        'document_branding_events'
      )
    ORDER BY cls.relname, att.attname
  LOOP
    EXECUTE format(
      'SELECT count(*) FROM (SELECT 1 FROM public.%I WHERE %I = $1 LIMIT 1000) capped',
      v_fk.table_name, v_fk.column_name
    ) INTO v_count USING p_business_id;

    IF v_count > 0 THEN
      source_table := v_fk.table_name;
      source_column := v_fk.column_name;
      row_count := v_count;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

-- 2) Do the switch.
CREATE OR REPLACE FUNCTION public.admin_change_business_type(
  p_business_id UUID,
  p_new_type TEXT,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_biz public.businesses%ROWTYPE;
  v_old_type public.business_type;
  v_new_type public.business_type;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_blockers TEXT;
  v_new_status public.verification_status;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can change a business type.';
  END IF;

  IF p_new_type IS NULL OR p_new_type NOT IN ('pharmacy', 'wholesaler') THEN
    RAISE EXCEPTION 'Choose Pharmacy or Wholesaler.';
  END IF;
  v_new_type := p_new_type::public.business_type;

  -- FOR UPDATE conflicts with the key-share lock every foreign-key insert takes on this row, so
  -- nothing can attach new data to the business between the check below and the update.
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found.';
  END IF;
  v_old_type := v_biz.type;

  IF v_old_type = v_new_type THEN
    RAISE EXCEPTION 'This business is already a %.', v_old_type;
  END IF;

  SELECT string_agg(b.source_table || ' (' || b.row_count || CASE WHEN b.row_count >= 1000 THEN '+' ELSE '' END || ')', ', ' ORDER BY b.source_table)
    INTO v_blockers
  FROM public.admin_business_type_blockers(p_business_id) b;

  IF v_blockers IS NOT NULL THEN
    RAISE EXCEPTION 'This business already has data, so its type cannot be changed: %.', v_blockers;
  END IF;

  v_new_status := CASE WHEN v_biz.verification_status = 'approved' THEN 'pending'::public.verification_status ELSE v_biz.verification_status END;

  UPDATE public.businesses
  SET type = v_new_type,
      verification_status = v_new_status
  WHERE id = p_business_id;

  -- Keep the owner's app_role in step with the business type.
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_biz.owner_id, v_new_type::TEXT::public.app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  IF NOT EXISTS (
    SELECT 1 FROM public.businesses o
    WHERE o.owner_id = v_biz.owner_id AND o.type = v_old_type
  ) THEN
    DELETE FROM public.user_roles
    WHERE user_id = v_biz.owner_id AND role = v_old_type::TEXT::public.app_role;
  END IF;

  PERFORM public.write_audit_log(
    'Business type changed',
    v_biz.name,
    'business',
    v_biz.id,
    COALESCE(v_biz.license_number, v_biz.id::TEXT),
    jsonb_build_object(
      'from_type', v_old_type,
      'to_type', v_new_type,
      'from_status', v_biz.verification_status,
      'to_status', v_new_status,
      'reason', v_reason
    )
  );

  RETURN jsonb_build_object(
    'business_id', v_biz.id,
    'from_type', v_old_type,
    'to_type', v_new_type,
    'verification_status', v_new_status
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_business_type_blockers(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_business_type_blockers(UUID) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_change_business_type(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_change_business_type(UUID, TEXT, TEXT) TO authenticated;
