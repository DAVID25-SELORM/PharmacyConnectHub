-- Privacy and data rights.
--
--   * consent_records   - proof that a person accepted the Privacy Notice and Terms, and which version.
--   * data_requests     - a person's request to have their account's personal data deleted (or another
--                         privacy request), handled by a platform admin within a deadline.
--   * export_my_data()  - the person downloads the personal data held about them (self-service).
--   * admin_anonymise_user() - removes a person's personal details and sign-in, keeping the business
--                         records the law requires (orders, invoices, audit trail) under a neutral name.
--   * run_data_retention() - removes data that has no reason to be kept (stale push devices, old
--                         notifications). Not scheduled by this file; see docs/security-to-apply.
--
-- Nothing here changes what existing screens do. New tables are empty until used.
-- Run docs/security-to-apply/verify-privacy.sql afterwards.

-- 1. Consent records -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.consent_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  document TEXT NOT NULL CHECK (document IN ('privacy_notice', 'terms')),
  version TEXT NOT NULL CHECK (char_length(version) BETWEEN 1 AND 40),
  source TEXT NOT NULL DEFAULT 'app' CHECK (source IN ('signup', 'app')),
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, document, version)
);

CREATE INDEX IF NOT EXISTS consent_records_user_idx ON public.consent_records (user_id, accepted_at DESC);

ALTER TABLE public.consent_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.consent_records FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.consent_records TO authenticated;
DROP POLICY IF EXISTS consent_records_own_read ON public.consent_records;
CREATE POLICY consent_records_own_read ON public.consent_records
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.record_consent(p_version TEXT, p_source TEXT DEFAULT 'app')
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_version TEXT := NULLIF(btrim(COALESCE(p_version, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.';
  END IF;
  IF v_version IS NULL OR char_length(v_version) > 40 THEN
    RAISE EXCEPTION 'A document version is required.';
  END IF;
  IF p_source NOT IN ('signup', 'app') THEN
    RAISE EXCEPTION 'Unknown source.';
  END IF;

  INSERT INTO public.consent_records (user_id, document, version, source)
  SELECT auth.uid(), d, v_version, p_source
  FROM unnest(ARRAY['privacy_notice', 'terms']) AS d
  ON CONFLICT (user_id, document, version) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.record_consent(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_consent(TEXT, TEXT) TO authenticated;

-- 2. Data requests -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.data_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  requester_email TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('deletion', 'correction', 'other')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'completed', 'declined')),
  reason TEXT CHECK (reason IS NULL OR char_length(reason) <= 1000),
  resolution_note TEXT CHECK (resolution_note IS NULL OR char_length(resolution_note) <= 1000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- A reply is due within 30 days of the request.
  due_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '30 days'),
  handled_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  handled_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS data_requests_one_open_per_kind
  ON public.data_requests (user_id, kind) WHERE status IN ('open', 'in_progress');
CREATE INDEX IF NOT EXISTS data_requests_status_idx ON public.data_requests (status, created_at);

ALTER TABLE public.data_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.data_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.data_requests TO authenticated;
DROP POLICY IF EXISTS data_requests_own_read ON public.data_requests;
CREATE POLICY data_requests_own_read ON public.data_requests
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.request_data_action(p_kind TEXT, p_reason TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_email TEXT;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in first.';
  END IF;
  IF p_kind NOT IN ('deletion', 'correction', 'other') THEN
    RAISE EXCEPTION 'Unknown request type.';
  END IF;
  IF v_reason IS NOT NULL AND char_length(v_reason) > 1000 THEN
    RAISE EXCEPTION 'Please keep the reason under 1000 characters.';
  END IF;
  IF p_kind IN ('correction', 'other') AND v_reason IS NULL THEN
    RAISE EXCEPTION 'Tell us what you need.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.data_requests
    WHERE user_id = auth.uid() AND kind = p_kind AND status IN ('open', 'in_progress')
  ) THEN
    RAISE EXCEPTION 'You already have an open request of this kind. We will reply by email.';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();

  INSERT INTO public.data_requests (user_id, requester_email, kind, reason)
  VALUES (auth.uid(), v_email, p_kind, v_reason)
  RETURNING id INTO v_id;

  PERFORM public.write_audit_log(
    'Privacy request submitted',
    NULL,
    'data_request',
    v_id,
    p_kind,
    jsonb_build_object('kind', p_kind)
  );

  -- Tell the platform admins; a failure to notify must never lose the request.
  BEGIN
    INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
    SELECT DISTINCT ur.user_id, 'privacy_request', 'New privacy request',
      'A user asked for ' || CASE p_kind WHEN 'deletion' THEN 'their data to be deleted' ELSE 'a privacy change' END
        || '. A reply is due within 30 days.',
      '/admin/privacy', jsonb_build_object('data_request_id', v_id)
    FROM public.user_roles ur WHERE ur.role = 'admin';
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'privacy request notification failed: %', SQLERRM;
  END;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.request_data_action(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_data_action(TEXT, TEXT) TO authenticated;

-- 3. Self-service export ---------------------------------------------------------------------
-- Personal data about the signed-in person. Business records (orders, invoices, stock) belong to
-- the business and are not part of one person's export.
CREATE OR REPLACE FUNCTION public.export_my_data()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in first.';
  END IF;

  RETURN jsonb_build_object(
    'generated_at', now(),
    'note', 'This file holds the personal data Drugxone keeps about you. Business records such as orders, invoices and stock belong to the business and are not included.',
    'account', (
      SELECT jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at)
      FROM auth.users u WHERE u.id = v_uid
    ),
    'profile', (
      SELECT jsonb_build_object('full_name', p.full_name, 'phone', p.phone, 'created_at', p.created_at, 'updated_at', p.updated_at)
      FROM public.profiles p WHERE p.id = v_uid
    ),
    'roles', COALESCE((SELECT jsonb_agg(ur.role) FROM public.user_roles ur WHERE ur.user_id = v_uid), '[]'::JSONB),
    'businesses_you_own', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'name', b.name, 'type', b.type, 'licence_number', b.license_number, 'phone', b.phone,
          'public_email', b.public_email, 'address', b.address, 'city', b.city, 'region', b.region,
          'verification_status', b.verification_status, 'created_at', b.created_at,
          'private_contacts', (
            SELECT jsonb_build_object(
              'owner_full_name', c.owner_full_name, 'owner_phone', c.owner_phone, 'owner_email', c.owner_email,
              'superintendent_full_name', c.superintendent_full_name,
              'superintendent_phone', c.superintendent_phone, 'superintendent_email', c.superintendent_email
            )
            FROM public.business_private_contacts c WHERE c.business_id = b.id
          )
        ) ORDER BY b.created_at
      )
      FROM public.businesses b WHERE b.owner_id = v_uid
    ), '[]'::JSONB),
    'staff_memberships', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('business', b.name, 'role', s.role, 'status', s.status, 'invited_at', s.invited_at, 'joined_at', s.joined_at)
        ORDER BY s.created_at
      )
      FROM public.business_staff s JOIN public.businesses b ON b.id = s.business_id
      WHERE s.user_id = v_uid
    ), '[]'::JSONB),
    'consents', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('document', c.document, 'version', c.version, 'source', c.source, 'accepted_at', c.accepted_at)
        ORDER BY c.accepted_at
      )
      FROM public.consent_records c WHERE c.user_id = v_uid
    ), '[]'::JSONB),
    'privacy_requests', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('kind', r.kind, 'status', r.status, 'reason', r.reason, 'created_at', r.created_at, 'resolution_note', r.resolution_note, 'handled_at', r.handled_at)
        ORDER BY r.created_at
      )
      FROM public.data_requests r WHERE r.user_id = v_uid
    ), '[]'::JSONB),
    'notification_devices', (SELECT count(*) FROM public.push_subscriptions s WHERE s.user_id = v_uid)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.export_my_data() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.export_my_data() TO authenticated;

-- 4. Admin: work the request queue --------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_data_requests(p_status TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can see this.';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(t)::JSONB ORDER BY t.created_at DESC)
    FROM (
      SELECT
        r.id, r.user_id, COALESCE(u.email, r.requester_email) AS email, r.kind, r.status,
        r.reason, r.resolution_note, r.created_at, r.due_at, r.handled_at,
        COALESCE((SELECT jsonb_agg(b.name) FROM public.businesses b WHERE b.owner_id = r.user_id), '[]'::JSONB) AS owned_businesses,
        EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = r.user_id AND ur.role = 'admin') AS is_admin,
        COALESCE((u.raw_app_meta_data ->> 'anonymised') = 'true', FALSE) AS already_anonymised
      FROM public.data_requests r
      LEFT JOIN auth.users u ON u.id = r.user_id
      WHERE p_status IS NULL OR r.status = p_status
      ORDER BY r.created_at DESC
      LIMIT 200
    ) t
  ), '[]'::JSONB);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_data_requests(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_data_requests(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_resolve_data_request(p_id UUID, p_status TEXT, p_note TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req public.data_requests%ROWTYPE;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can change this.';
  END IF;
  IF p_status NOT IN ('in_progress', 'completed', 'declined') THEN
    RAISE EXCEPTION 'Unknown status.';
  END IF;
  IF p_status = 'declined' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Write the reason for declining; the person will be told.';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 1000 THEN
    RAISE EXCEPTION 'Please keep the note under 1000 characters.';
  END IF;

  SELECT * INTO v_req FROM public.data_requests WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found.';
  END IF;
  IF v_req.status IN ('completed', 'declined') THEN
    RAISE EXCEPTION 'This request is already closed.';
  END IF;

  UPDATE public.data_requests
  SET status = p_status,
      resolution_note = COALESCE(v_note, resolution_note),
      handled_by = auth.uid(),
      handled_at = CASE WHEN p_status IN ('completed', 'declined') THEN now() ELSE handled_at END
  WHERE id = p_id;

  PERFORM public.write_audit_log(
    'Privacy request ' || p_status,
    NULL,
    'data_request',
    p_id,
    v_req.kind,
    jsonb_build_object('kind', v_req.kind, 'status', p_status)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_resolve_data_request(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_resolve_data_request(UUID, TEXT, TEXT) TO authenticated;

-- 5. Anonymise a person ---------------------------------------------------------------------------
-- Removes the person's identity and ability to sign in. It deliberately does NOT delete the
-- records the business must keep (orders, invoices, stock movements, the audit trail): those stay,
-- attached to a neutral "Deleted user". Refuses while the person still owns a business, because
-- closing or handing over a business is a decision for its owner, not a side effect.
CREATE OR REPLACE FUNCTION public.admin_anonymise_user(p_user_id UUID, p_request_id UUID DEFAULT NULL, p_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owned TEXT;
  v_email TEXT;
  v_notifications INT;
  v_devices INT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can do this.';
  END IF;
  IF p_user_id IS NULL OR p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot remove your own account here.';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Person not found.';
  END IF;
  IF EXISTS (SELECT 1 FROM auth.users WHERE id = p_user_id AND (raw_app_meta_data ->> 'anonymised') = 'true') THEN
    RAISE EXCEPTION 'This person has already been removed.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = p_user_id AND role = 'admin')
     OR EXISTS (SELECT 1 FROM public.platform_staff WHERE user_id = p_user_id AND status <> 'inactive') THEN
    RAISE EXCEPTION 'This person is platform staff. Remove their platform access first.';
  END IF;

  SELECT string_agg(name, ', ' ORDER BY name) INTO v_owned FROM public.businesses WHERE owner_id = p_user_id;
  IF v_owned IS NOT NULL THEN
    RAISE EXCEPTION 'This person owns: %. Hand over or close the business first.', v_owned;
  END IF;

  UPDATE public.profiles SET full_name = 'Deleted user', phone = NULL WHERE id = p_user_id;
  UPDATE public.business_staff SET status = 'inactive' WHERE user_id = p_user_id;
  DELETE FROM public.push_subscriptions WHERE user_id = p_user_id;
  GET DIAGNOSTICS v_devices = ROW_COUNT;
  DELETE FROM public.notifications WHERE user_id = p_user_id;
  GET DIAGNOSTICS v_notifications = ROW_COUNT;

  -- Sign-in: no sessions, no authenticator apps, no linked identities, no way back in.
  DELETE FROM auth.sessions WHERE user_id = p_user_id;
  DELETE FROM auth.refresh_tokens WHERE user_id = p_user_id::TEXT;
  DELETE FROM auth.mfa_factors WHERE user_id = p_user_id;
  DELETE FROM auth.identities WHERE user_id = p_user_id;
  UPDATE auth.users
  SET email = 'deleted-' || p_user_id::TEXT || '@deleted.invalid',
      phone = NULL,
      raw_user_meta_data = '{}'::JSONB,
      raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::JSONB) || '{"anonymised": true}'::JSONB,
      encrypted_password = NULL,
      banned_until = 'infinity'::TIMESTAMPTZ
  WHERE id = p_user_id;

  -- Requests this person made keep their history but lose the contact address.
  UPDATE public.data_requests SET requester_email = NULL WHERE user_id = p_user_id;

  IF p_request_id IS NOT NULL THEN
    UPDATE public.data_requests
    SET status = 'completed', handled_by = auth.uid(), handled_at = now(),
        resolution_note = COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), 'Personal details removed.')
    WHERE id = p_request_id AND user_id = p_user_id AND status IN ('open', 'in_progress');
  END IF;

  -- The audit trail is immutable and is kept as the legal record of what happened.
  PERFORM public.write_audit_log(
    'User anonymised',
    NULL,
    'user',
    p_user_id,
    'anonymised user',
    jsonb_build_object('request_id', p_request_id, 'push_devices_removed', v_devices, 'notifications_removed', v_notifications)
  );

  RETURN jsonb_build_object('user_id', p_user_id, 'push_devices_removed', v_devices, 'notifications_removed', v_notifications);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_anonymise_user(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_anonymise_user(UUID, UUID, TEXT) TO authenticated;

-- 6. Retention ---------------------------------------------------------------------------------------
-- Stale push devices (not seen for 90 days), notifications read more than 180 days ago, and any
-- notification older than a year. Records the business must keep are never touched here.
CREATE OR REPLACE FUNCTION public.run_data_retention()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_devices INT;
  v_read INT;
  v_old INT;
BEGIN
  DELETE FROM public.push_subscriptions WHERE last_seen_at < now() - INTERVAL '90 days';
  GET DIAGNOSTICS v_devices = ROW_COUNT;

  DELETE FROM public.notifications WHERE read AND created_at < now() - INTERVAL '180 days';
  GET DIAGNOSTICS v_read = ROW_COUNT;

  DELETE FROM public.notifications WHERE created_at < now() - INTERVAL '365 days';
  GET DIAGNOSTICS v_old = ROW_COUNT;

  RETURN jsonb_build_object('push_devices', v_devices, 'read_notifications', v_read, 'old_notifications', v_old);
END;
$$;

REVOKE ALL ON FUNCTION public.run_data_retention() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_data_retention() TO service_role;
