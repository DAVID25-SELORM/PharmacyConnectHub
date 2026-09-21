-- Let the owner of a rejected business resubmit it for review.
-- rejected -> pending is the ONLY status change a non-admin may cause, and only through
-- resubmit_business_verification(). Admins remain the only way to reach approved/rejected.
-- Change detection: resubmission is only allowed if a required document was uploaded/replaced,
-- or the business record was edited, after the latest "Business rejected" audit event.
-- If that event cannot be found (rejected before audit logging existed) the change cannot be
-- proven either way, so resubmission is allowed rather than guessing.
-- History: every transition is written to audit_logs (the rejection itself, with its reason,
-- is already logged when the admin rejects; the resubmission logs the reason it replaces).

CREATE OR REPLACE FUNCTION public.enforce_business_verification_controls()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  is_resubmission BOOLEAN;
BEGIN
  -- Service-role operations (auth.uid() IS NULL) bypass RLS but still fire triggers.
  -- Allow them through unconditionally; RLS is what restricts regular users.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  is_resubmission :=
    COALESCE(current_setting('app.business_resubmission', true), '') = 'on'
    AND OLD.verification_status = 'rejected'
    AND NEW.verification_status = 'pending'
    AND OLD.owner_id = auth.uid();

  IF NOT public.has_role(auth.uid(), 'admin') AND NOT is_resubmission THEN
    IF NEW.verification_status IS DISTINCT FROM OLD.verification_status
      OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason
      OR NEW.verified_at IS DISTINCT FROM OLD.verified_at THEN
      RAISE EXCEPTION 'Only admins can change verification status.';
    END IF;
  END IF;

  IF NEW.verification_status = 'approved' THEN
    NEW.rejection_reason := NULL;
    NEW.verified_at := COALESCE(NEW.verified_at, OLD.verified_at, now());
  ELSIF NEW.verification_status = 'rejected' THEN
    NEW.verified_at := NULL;
  ELSE
    NEW.rejection_reason := NULL;
    NEW.verified_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.resubmit_business_verification(_business_id UUID)
RETURNS public.verification_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_required TEXT[];
  v_rejected_at TIMESTAMPTZ;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to resubmit verification.';
  END IF;

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = _business_id AND b.owner_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only the business owner can resubmit verification.';
  END IF;

  IF v_business.verification_status = 'pending' THEN
    RETURN 'pending';
  END IF;

  IF v_business.verification_status <> 'rejected' THEN
    RAISE EXCEPTION 'Only a rejected business can be resubmitted for review.';
  END IF;

  -- Mirrors the required documents shown on the onboarding page.
  v_required := CASE v_business.type::TEXT
    WHEN 'pharmacy' THEN ARRAY['pharmacy_council', 'business_registration']
    ELSE ARRAY['wholesale_license', 'fda_certificate', 'business_registration']
  END;

  IF (
    SELECT COUNT(DISTINCT d.doc_type)
    FROM public.license_documents d
    WHERE d.business_id = _business_id AND d.doc_type = ANY (v_required)
  ) < array_length(v_required, 1) THEN
    RAISE EXCEPTION 'Upload all required documents before resubmitting.';
  END IF;

  SELECT MAX(a.created_at) INTO v_rejected_at
  FROM public.audit_logs a
  WHERE a.record_type = 'business'
    AND a.record_id = _business_id
    AND a.activity = 'Business rejected';

  IF v_rejected_at IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.license_documents d
      WHERE d.business_id = _business_id
        AND d.doc_type = ANY (v_required)
        AND d.uploaded_at > v_rejected_at
    )
    AND NOT (v_business.updated_at > v_rejected_at)
  THEN
    RAISE EXCEPTION 'Update at least one required document or your business details before resubmitting.';
  END IF;

  PERFORM public.write_audit_log(
    'Verification resubmitted',
    v_business.name,
    'business',
    v_business.id,
    COALESCE(v_business.license_number, v_business.id::TEXT),
    jsonb_build_object(
      'from_status', 'rejected',
      'to_status', 'pending',
      'previous_rejection_reason', v_business.rejection_reason
    )
  );

  PERFORM set_config('app.business_resubmission', 'on', true);
  UPDATE public.businesses SET verification_status = 'pending' WHERE id = _business_id;
  PERFORM set_config('app.business_resubmission', 'off', true);

  RETURN 'pending';
END;
$$;

REVOKE ALL ON FUNCTION public.resubmit_business_verification(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resubmit_business_verification(UUID) TO authenticated;

-- Authoritative upload time. The onboarding client used to send uploaded_at itself when replacing
-- a document, so a wrong or manipulated device clock could satisfy (or defeat) the
-- "changed since rejection" check above. The database now stamps the time and ignores any
-- client-supplied value: new rows and replaced files (storage_path changed) get now();
-- every other update keeps the existing timestamp.
CREATE OR REPLACE FUNCTION public.stamp_license_document_upload_time()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.storage_path IS DISTINCT FROM OLD.storage_path THEN
    NEW.uploaded_at := now();
  ELSE
    NEW.uploaded_at := OLD.uploaded_at;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_license_documents_stamp_upload_time ON public.license_documents;
CREATE TRIGGER trg_license_documents_stamp_upload_time
  BEFORE INSERT OR UPDATE ON public.license_documents
  FOR EACH ROW
  EXECUTE FUNCTION public.stamp_license_document_upload_time();
