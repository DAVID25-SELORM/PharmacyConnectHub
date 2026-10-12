-- Platform billing, Phase 5 (part 1): the data behind the administrator's controls and promotions.
-- Additive and inert: nothing here charges or changes anything by itself.
--
--   billing_term_windows            a TEMPORARY change to a business's terms (a discount, a lower fee, a fee waiver for a while). It sits on top of the permanent terms and simply stops applying
--                                   when it ends, so nothing has to be "put back" and a later change to the permanent terms is never undone by it.
--   billing_promotions              a named bundle of benefits (extra trial days, extra free orders, a subscription discount, a lower fee, a fee waiver). Its benefits never change once created.
--   billing_promotion_redemptions   which business received which promotion, and exactly what was done. Once per business, and once per owner and licence number, like the launch free orders.
-- Everything is administrator-only to read and nobody writes directly: all changes go through audited functions.

-- ---------------------------------------------------------------------------
-- 1. Temporary terms
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_term_windows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id UUID NOT NULL REFERENCES public.billing_subscriptions(id) ON DELETE RESTRICT,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  -- Same parameters as the permanent overrides, plus exempt_from_transaction_fees (a temporary fee waiver).
  overrides JSONB NOT NULL CHECK (jsonb_typeof(overrides) = 'object' AND overrides <> '{}'::JSONB),
  source TEXT NOT NULL CHECK (source IN ('promotion', 'admin')),
  promotion_id UUID,
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) >= 5),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  ended_early_at TIMESTAMPTZ,
  CHECK (ends_at > starts_at),
  CHECK (ends_at <= starts_at + interval '3 years'),
  CHECK (source <> 'promotion' OR promotion_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS billing_term_windows_sub_idx ON public.billing_term_windows (subscription_id, starts_at, ends_at);

-- ---------------------------------------------------------------------------
-- 2. Promotions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_promotions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{2,39}$'),
  name TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 2 AND 80),
  description TEXT CHECK (description IS NULL OR char_length(description) <= 1000),
  business_type public.business_type NOT NULL,
  -- Which benefits, from a short fixed list (see the guard): free_trial_days, free_orders, subscription_discount_percent + discount_days, fee_percentage + fee_days, fee_waiver_days.
  benefits JSONB NOT NULL CHECK (jsonb_typeof(benefits) = 'object' AND benefits <> '{}'::JSONB),
  valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until TIMESTAMPTZ,
  max_redemptions INTEGER CHECK (max_redemptions IS NULL OR max_redemptions > 0),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) >= 5),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (valid_until IS NULL OR valid_until > valid_from)
);

CREATE TABLE IF NOT EXISTS public.billing_promotion_redemptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  promotion_id UUID NOT NULL REFERENCES public.billing_promotions(id) ON DELETE RESTRICT,
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  -- What was actually done (grants, windows, trial change), so the redemption explains itself even if the promotion is later switched off.
  applied JSONB NOT NULL CHECK (jsonb_typeof(applied) = 'object'),
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) >= 5),
  licence_key TEXT,
  owner_key UUID,
  redeemed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  redeemed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (promotion_id, business_id)
);
-- A second account for the same licence number, or the same owner, does not earn the same promotion again.
CREATE UNIQUE INDEX IF NOT EXISTS billing_promotion_redemptions_licence_idx ON public.billing_promotion_redemptions (promotion_id, licence_key) WHERE licence_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS billing_promotion_redemptions_owner_idx ON public.billing_promotion_redemptions (promotion_id, owner_key) WHERE owner_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS billing_promotion_redemptions_business_idx ON public.billing_promotion_redemptions (business_id, redeemed_at DESC);

ALTER TABLE public.billing_term_windows DROP CONSTRAINT IF EXISTS billing_term_windows_promotion_fk;
ALTER TABLE public.billing_term_windows ADD CONSTRAINT billing_term_windows_promotion_fk FOREIGN KEY (promotion_id) REFERENCES public.billing_promotions(id) ON DELETE RESTRICT;

-- An administrator's free-order grant carries a request key, so a double click grants once.
CREATE UNIQUE INDEX IF NOT EXISTS billing_allowance_grants_admin_ref_idx ON public.billing_allowance_grants (business_id, source_ref) WHERE source = 'admin' AND source_ref IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Integrity
-- ---------------------------------------------------------------------------
-- A redemption is never changed or deleted (the one exception is the database clearing the link to the administrator's account when that account is deleted).
CREATE OR REPLACE FUNCTION public.billing_redemptions_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.redeemed_by IS NULL
     AND (NEW.id, NEW.promotion_id, NEW.business_id, NEW.applied, NEW.reason, NEW.licence_key, NEW.owner_key, NEW.redeemed_at)
         IS NOT DISTINCT FROM (OLD.id, OLD.promotion_id, OLD.business_id, OLD.applied, OLD.reason, OLD.licence_key, OLD.owner_key, OLD.redeemed_at) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Billing records are never changed or deleted (%). Record a correction instead.', TG_TABLE_NAME;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_redemptions_append_only ON public.billing_promotion_redemptions;
CREATE TRIGGER trg_billing_redemptions_append_only BEFORE UPDATE OR DELETE ON public.billing_promotion_redemptions FOR EACH ROW EXECUTE FUNCTION public.billing_redemptions_guard();

-- The overrides a temporary window may carry: the permanent ones plus a temporary fee waiver.
CREATE OR REPLACE FUNCTION public.billing_validate_overrides(p_overrides JSONB, p_allow_exempt BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_key TEXT;
  v_val JSONB;
BEGIN
  FOR v_key, v_val IN SELECT * FROM jsonb_each(p_overrides) LOOP
    IF v_key = 'exempt_from_transaction_fees' THEN
      IF NOT p_allow_exempt THEN RAISE EXCEPTION 'Unknown price override "%".', v_key; END IF;
      IF v_val <> 'true'::JSONB THEN RAISE EXCEPTION 'A temporary fee waiver is exempt_from_transaction_fees set to true.'; END IF;
      CONTINUE;
    END IF;
    IF v_key NOT IN ('subscription_amount', 'transaction_fee_percentage', 'transaction_fee_min', 'transaction_fee_max', 'transaction_fee_cycle_cap', 'monthly_free_orders', 'min_billable_order_amount') THEN
      RAISE EXCEPTION 'Unknown price override "%".', v_key;
    END IF;
    IF jsonb_typeof(v_val) = 'null' THEN
      IF v_key IN ('subscription_amount', 'transaction_fee_percentage', 'monthly_free_orders') THEN RAISE EXCEPTION 'The override "%" cannot be empty.', v_key; END IF;
    ELSIF jsonb_typeof(v_val) <> 'number' OR (v_val #>> '{}')::NUMERIC < 0 THEN
      RAISE EXCEPTION 'The override "%" must be a number that is not negative.', v_key;
    ELSIF v_key = 'monthly_free_orders' AND (v_val #>> '{}') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'The override "monthly_free_orders" must be a whole number.';
    ELSIF v_key = 'transaction_fee_percentage' AND (v_val #>> '{}')::NUMERIC > 100 THEN
      RAISE EXCEPTION 'A percentage cannot be more than 100.';
    END IF;
  END LOOP;
END;
$$;

-- A window's overrides are checked when it is created; afterwards only its end may move, and only earlier (ending it early). It is never deleted.
CREATE OR REPLACE FUNCTION public.billing_term_windows_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Billing records are never changed or deleted (billing_term_windows). End the window instead.'; END IF;
  IF TG_OP = 'INSERT' THEN
    PERFORM public.billing_validate_overrides(NEW.overrides, TRUE);
    RETURN NEW;
  END IF;
  -- (removing the creator's link when that user account is deleted is the one other change the database itself makes)
  IF (NEW.id, NEW.subscription_id, NEW.starts_at, NEW.overrides, NEW.source, NEW.promotion_id, NEW.reason, NEW.created_at)
     IS DISTINCT FROM (OLD.id, OLD.subscription_id, OLD.starts_at, OLD.overrides, OLD.source, OLD.promotion_id, OLD.reason, OLD.created_at)
     OR (NEW.created_by IS DISTINCT FROM OLD.created_by AND NEW.created_by IS NOT NULL) THEN
    RAISE EXCEPTION 'A temporary window cannot be edited. End it and add another.';
  END IF;
  IF NEW.ends_at = OLD.ends_at AND NEW.ended_early_at IS NOT DISTINCT FROM OLD.ended_early_at THEN RETURN NEW; END IF;
  IF NEW.ends_at >= OLD.ends_at OR NEW.ended_early_at IS NULL THEN RAISE EXCEPTION 'A window can only be ended earlier, never extended.'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_term_windows_guard ON public.billing_term_windows;
CREATE TRIGGER trg_billing_term_windows_guard BEFORE INSERT OR UPDATE OR DELETE ON public.billing_term_windows FOR EACH ROW EXECUTE FUNCTION public.billing_term_windows_guard();

-- A promotion's benefits are fixed when it is created (like a plan version); only whether it is switched on can change. The benefits come from a short fixed list.
CREATE OR REPLACE FUNCTION public.billing_promotions_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_key TEXT;
  v_val JSONB;
  v_n NUMERIC;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A promotion is never deleted. Switch it off instead.'; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.id, NEW.code, NEW.name, NEW.description, NEW.business_type, NEW.benefits, NEW.valid_from, NEW.valid_until, NEW.max_redemptions, NEW.reason, NEW.created_at)
       IS DISTINCT FROM (OLD.id, OLD.code, OLD.name, OLD.description, OLD.business_type, OLD.benefits, OLD.valid_from, OLD.valid_until, OLD.max_redemptions, OLD.reason, OLD.created_at)
       OR (NEW.created_by IS DISTINCT FROM OLD.created_by AND NEW.created_by IS NOT NULL) THEN
      RAISE EXCEPTION 'A promotion cannot be edited. Switch it off and create a new one.';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  FOR v_key, v_val IN SELECT * FROM jsonb_each(NEW.benefits) LOOP
    IF v_key NOT IN ('free_trial_days', 'free_orders', 'subscription_discount_percent', 'discount_days', 'fee_percentage', 'fee_days', 'fee_waiver_days') THEN
      RAISE EXCEPTION 'Unknown promotion benefit "%".', v_key;
    END IF;
    IF jsonb_typeof(v_val) <> 'number' THEN RAISE EXCEPTION 'The benefit "%" must be a number.', v_key; END IF;
    v_n := (v_val #>> '{}')::NUMERIC;
    IF v_key IN ('free_trial_days', 'discount_days', 'fee_days', 'fee_waiver_days') AND (v_n < 1 OR v_n > 730 OR v_n <> trunc(v_n)) THEN RAISE EXCEPTION 'The benefit "%" must be a whole number of days from 1 to 730.', v_key; END IF;
    IF v_key = 'free_orders' AND (v_n < 1 OR v_n > 10000 OR v_n <> trunc(v_n)) THEN RAISE EXCEPTION 'The benefit "free_orders" must be a whole number from 1 to 10,000.'; END IF;
    IF v_key = 'subscription_discount_percent' AND (v_n <= 0 OR v_n > 100) THEN RAISE EXCEPTION 'A subscription discount must be more than 0 and at most 100 percent.'; END IF;
    IF v_key = 'fee_percentage' AND (v_n < 0 OR v_n > 100) THEN RAISE EXCEPTION 'A fee percentage must be between 0 and 100.'; END IF;
  END LOOP;
  IF (NEW.benefits ? 'subscription_discount_percent') <> (NEW.benefits ? 'discount_days') THEN RAISE EXCEPTION 'A subscription discount needs both its percentage and the number of days it lasts.'; END IF;
  IF (NEW.benefits ? 'fee_percentage') <> (NEW.benefits ? 'fee_days') THEN RAISE EXCEPTION 'A lower fee needs both the percentage and the number of days it lasts.'; END IF;
  IF NEW.business_type = 'pharmacy' AND (NEW.benefits ? 'free_orders' OR NEW.benefits ? 'fee_percentage' OR NEW.benefits ? 'fee_waiver_days') THEN
    RAISE EXCEPTION 'A pharmacy pays no transaction fee, so free orders and fee benefits are only for wholesaler promotions.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_promotions_guard ON public.billing_promotions;
CREATE TRIGGER trg_billing_promotions_guard BEFORE INSERT OR UPDATE OR DELETE ON public.billing_promotions FOR EACH ROW EXECUTE FUNCTION public.billing_promotions_guard();

-- ---------------------------------------------------------------------------
-- 4. Access: administrators read; nobody writes directly
-- ---------------------------------------------------------------------------
ALTER TABLE public.billing_term_windows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_promotions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_promotion_redemptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.billing_term_windows, public.billing_promotions, public.billing_promotion_redemptions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.billing_term_windows, public.billing_promotions, public.billing_promotion_redemptions TO authenticated;
REVOKE ALL ON FUNCTION public.billing_validate_overrides(JSONB, BOOLEAN) FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS "Admins read term windows" ON public.billing_term_windows;
CREATE POLICY "Admins read term windows" ON public.billing_term_windows FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read promotions" ON public.billing_promotions;
CREATE POLICY "Admins read promotions" ON public.billing_promotions FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read promotion redemptions" ON public.billing_promotion_redemptions;
CREATE POLICY "Admins read promotion redemptions" ON public.billing_promotion_redemptions FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
