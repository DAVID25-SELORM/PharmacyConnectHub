-- Audit Centre, part 1: schema.
--
-- Gap being closed: audit_logs has no reliable way to answer "show me everything relevant to
-- business X" -- the existing `organization` column is the business's NAME (a free-text snapshot
-- at write time, not a stable identifier: renames break it, and two businesses can share a name).
-- `record_id` sometimes IS a business id (e.g. the business-verification trigger) but usually
-- isn't (it's an order id, a product id, a ledger entry id...), so it can't be used as a reliable
-- filter either. Adds a proper business_id column instead.
--
-- Deliberately additive and backward compatible: business_id is nullable, every existing caller of
-- write_audit_log keeps working unchanged (the new parameter is optional and defaults to NULL), and
-- historical rows are left as NULL except the one case that can be safely backfilled for free (see
-- below). This migration does NOT retrofit every pre-existing write_audit_log call site in the
-- codebase -- only the ones this phase's Audit Centre UI is built to show (RFQ actions, credit
-- ledger actions, and the two product-catalog import flows) are updated, in the next migration.
-- Older call sites (business verification, order returns/deliveries, batches, discounts, order
-- terms) still log successfully, just without business_id, so their entries won't appear in the
-- new per-business Audit Centre view -- a known, documented scope cut, not a silent gap.

ALTER TABLE public.audit_logs ADD COLUMN IF NOT EXISTS business_id UUID REFERENCES public.businesses(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_business ON public.audit_logs(business_id, created_at DESC) WHERE business_id IS NOT NULL;

-- Free, safe backfill: every existing 'business' record_type row already has the business's own id
-- as record_id (see audit_business_changes below), so business_id = record_id is exact, not a guess.
UPDATE public.audit_logs SET business_id = record_id WHERE record_type = 'business' AND business_id IS NULL;

-- CREATE OR REPLACE cannot change a function's parameter COUNT -- adding _business_id as a 10th
-- parameter would otherwise create a second overload alongside the original 9-parameter version
-- (same name, different arity, both valid), and every existing call site that omits the trailing
-- optional arguments (i.e. nearly all of them) would then fail with "is not unique" ambiguity.
-- Drop the old signature explicitly first so there is only ever one write_audit_log.
DROP FUNCTION IF EXISTS public.write_audit_log(TEXT, TEXT, TEXT, UUID, TEXT, JSONB, UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.write_audit_log(
  _activity TEXT,
  _organization TEXT,
  _record_type TEXT,
  _record_id UUID,
  _record_label TEXT,
  _details JSONB DEFAULT '{}'::JSONB,
  _performed_by UUID DEFAULT auth.uid(),
  _performed_by_email TEXT DEFAULT public.current_actor_email(),
  _ip_address TEXT DEFAULT public.current_request_ip_address(),
  _business_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.audit_logs (
    activity, organization, performed_by, performed_by_email, record_type, record_id, record_label, ip_address, details, business_id
  )
  VALUES (
    _activity, _organization, _performed_by, _performed_by_email, _record_type, _record_id, _record_label, _ip_address,
    COALESCE(_details, '{}'::JSONB), _business_id
  );
END;
$$;

-- The business-verification trigger already has the business id on hand (NEW.id) -- pass it
-- through explicitly now that there's somewhere for it to go, instead of relying on the backfill
-- convention for rows written from here on. Rebuilt on the exact prior body
-- (20260505090000_add_audit_logs.sql lines 120-168) -- only the two write_audit_log calls gain a
-- trailing _business_id argument; nothing else changes.
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
      public.current_request_ip_address(),
      NEW.id
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
      ),
      _business_id => NEW.id
    );
  END IF;

  RETURN NEW;
END;
$$;
