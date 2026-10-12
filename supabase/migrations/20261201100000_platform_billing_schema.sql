-- Platform billing, Phase 1 part 1: the SCHEMA. Nothing here charges anyone: there is no billing engine yet (Phase 2), billing_settings.mode is 'disabled', and no business has a
-- subscription. The tables are the foundation the later phases write into. See docs/platform-billing.md.
--
-- Conventions
--   * A "business" (public.businesses, type pharmacy or wholesaler) is the organization that is billed.
--   * Money is NUMERIC, never floating point, with a currency column (GHS now; nothing assumes it stays so). Percentages are NUMERIC(7,4) "percent" values (0.7500 = 0.75%).
--   * Time: timestamptz everywhere. Billing periods are half-open [start, end), rolling monthly from each business's own anchor date.
--   * Every table has RLS on and no direct write grants to signed-in users: ALL writes go through SECURITY DEFINER functions (next migration) that check who is calling.
--   * Plan prices are IMMUTABLE VERSIONS: a price change publishes a new version; subscriptions pin a version; each assessment (Phase 2) snapshots the terms it used. History is
--     never recalculated.
--   * Append-only: plan versions' terms, subscription terms, allowance grants, the ledger and order assessments can never be updated or deleted.
--   * Shadow billing: rows with shadow = TRUE are "what it would have been". They never touch real counters, are hidden from organizations, and are never invoiced.

-- ---------------------------------------------------------------------------
-- 1. Settings (one row): the platform-wide switch
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_settings (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  -- disabled: nothing is calculated. shadow: calculated but never charged or shown to organizations. active: real billing (never before Phase 6).
  mode TEXT NOT NULL DEFAULT 'disabled' CHECK (mode IN ('disabled', 'shadow', 'active')),
  timezone TEXT NOT NULL DEFAULT 'Africa/Accra',
  grace_days INTEGER NOT NULL DEFAULT 7 CHECK (grace_days BETWEEN 0 AND 90),
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency ~ '^[A-Z]{3}$'),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by TEXT
);
INSERT INTO public.billing_settings (id, mode) VALUES (TRUE, 'disabled') ON CONFLICT (id) DO NOTHING;

-- An unknown timezone name is refused rather than failing later in the middle of a billing run.
CREATE OR REPLACE FUNCTION public.billing_settings_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM now() AT TIME ZONE NEW.timezone;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_settings_check ON public.billing_settings;
CREATE TRIGGER trg_billing_settings_check BEFORE INSERT OR UPDATE ON public.billing_settings FOR EACH ROW EXECUTE FUNCTION public.billing_settings_check();

-- ---------------------------------------------------------------------------
-- 2. The feature catalog (what a plan may grant) and the plans
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_feature_catalog (
  key TEXT PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]{1,59}$'),
  label TEXT NOT NULL CHECK (char_length(btrim(label)) BETWEEN 2 AND 80),
  description TEXT,
  value_type TEXT NOT NULL CHECK (value_type IN ('boolean', 'integer')),
  business_type public.business_type,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.billing_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE CHECK (code ~ '^[a-z][a-z0-9_-]{1,39}$'),
  business_type public.business_type NOT NULL,
  -- standard: offered to any business of the type. custom: agreed with one business (enterprise).
  kind TEXT NOT NULL DEFAULT 'standard' CHECK (kind IN ('standard', 'custom')),
  name TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 2 AND 80),
  description TEXT CHECK (description IS NULL OR char_length(description) <= 1000),
  -- active: new subscriptions may be started on it. publicly_visible: shown to businesses choosing a plan.
  active BOOLEAN NOT NULL DEFAULT FALSE,
  publicly_visible BOOLEAN NOT NULL DEFAULT FALSE,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per published price/terms version. The commercial parameters are IMMUTABLE once the row exists; only its status (published -> retired) can change.
CREATE TABLE IF NOT EXISTS public.billing_plan_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id UUID NOT NULL REFERENCES public.billing_plans(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL CHECK (version > 0),
  status TEXT NOT NULL DEFAULT 'published' CHECK (status IN ('published', 'retired')),
  billing_interval_months INTEGER NOT NULL DEFAULT 1 CHECK (billing_interval_months BETWEEN 1 AND 12),
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency ~ '^[A-Z]{3}$'),
  subscription_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (subscription_amount >= 0),
  free_trial_days INTEGER NOT NULL DEFAULT 0 CHECK (free_trial_days BETWEEN 0 AND 730),
  -- Lifetime free orders granted once when the subscription starts, and free orders that renew every billing period. Separate concepts.
  onboarding_free_orders INTEGER NOT NULL DEFAULT 0 CHECK (onboarding_free_orders BETWEEN 0 AND 10000),
  monthly_free_orders INTEGER NOT NULL DEFAULT 0 CHECK (monthly_free_orders BETWEEN 0 AND 10000),
  -- Percent of the billable order value (0.7500 = 0.75%). NULL limits below mean "no limit".
  transaction_fee_percentage NUMERIC(7,4) NOT NULL DEFAULT 0 CHECK (transaction_fee_percentage BETWEEN 0 AND 100),
  transaction_fee_min NUMERIC(12,2) CHECK (transaction_fee_min IS NULL OR transaction_fee_min >= 0),
  transaction_fee_max NUMERIC(12,2) CHECK (transaction_fee_max IS NULL OR transaction_fee_max >= 0),
  transaction_fee_cycle_cap NUMERIC(12,2) CHECK (transaction_fee_cycle_cap IS NULL OR transaction_fee_cycle_cap >= 0),
  -- Orders worth less than this are not fee-eligible and do not use a free order (a guard against wash orders). NULL: no minimum.
  min_billable_order_amount NUMERIC(12,2) CHECK (min_billable_order_amount IS NULL OR min_billable_order_amount >= 0),
  max_users INTEGER CHECK (max_users IS NULL OR max_users > 0),
  max_branches INTEGER CHECK (max_branches IS NULL OR max_branches > 0),
  entitlements JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(entitlements) = 'object'),
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  effective_from TIMESTAMPTZ NOT NULL DEFAULT now(),
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) >= 3),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  retired_at TIMESTAMPTZ,
  UNIQUE (plan_id, version),
  CHECK (transaction_fee_min IS NULL OR transaction_fee_max IS NULL OR transaction_fee_max >= transaction_fee_min),
  CHECK ((status = 'retired') = (retired_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS billing_plan_versions_plan_idx ON public.billing_plan_versions (plan_id, version DESC);

-- ---------------------------------------------------------------------------
-- 3. A business's subscription, and the append-only history of its terms
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL UNIQUE REFERENCES public.businesses(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('trialing', 'active', 'past_due', 'grace_period', 'suspended', 'cancelled')),
  -- NULL: follow the platform setting. Otherwise this business can be held back (disabled / shadow) while the platform is further ahead; it can never be ahead of the platform.
  billing_mode TEXT CHECK (billing_mode IS NULL OR billing_mode IN ('disabled', 'shadow', 'active')),
  -- Orders delivered before this moment are NEVER assessed (no historical charges). Periods roll monthly from period_anchor_at.
  billing_starts_at TIMESTAMPTZ NOT NULL,
  period_anchor_at TIMESTAMPTZ NOT NULL,
  activated_at TIMESTAMPTZ,
  trial_start TIMESTAMPTZ,
  trial_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
  cancelled_at TIMESTAMPTZ,
  ended_at TIMESTAMPTZ,
  billing_paused BOOLEAN NOT NULL DEFAULT FALSE,
  paused_at TIMESTAMPTZ,
  paused_reason TEXT,
  exempt_from_transaction_fees BOOLEAN NOT NULL DEFAULT FALSE,
  exempt_reason TEXT,
  grace_until TIMESTAMPTZ,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (trial_end IS NULL OR trial_start IS NULL OR trial_end >= trial_start),
  CHECK (NOT exempt_from_transaction_fees OR exempt_reason IS NOT NULL),
  CHECK (NOT billing_paused OR paused_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS billing_subscriptions_status_idx ON public.billing_subscriptions (status);

-- What a subscription is charged under, from a given moment: the pinned plan version plus any explicit overrides. Append-only, so custom pricing keeps its history.
-- overrides is a JSON object whose keys are the parameters being overridden (present with a null value means "no limit"; absent means "inherit from the plan version").
CREATE TABLE IF NOT EXISTS public.billing_subscription_terms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id UUID NOT NULL REFERENCES public.billing_subscriptions(id) ON DELETE RESTRICT,
  effective_from TIMESTAMPTZ NOT NULL,
  plan_version_id UUID NOT NULL REFERENCES public.billing_plan_versions(id) ON DELETE RESTRICT,
  overrides JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(overrides) = 'object'),
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) >= 3),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (subscription_id, effective_from)
);
CREATE INDEX IF NOT EXISTS billing_subscription_terms_sub_idx ON public.billing_subscription_terms (subscription_id, effective_from DESC);

-- ---------------------------------------------------------------------------
-- 4. Free-order allowances granted (the evidence of use is on the order assessments, never a bare counter)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_allowance_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL DEFAULT 'onboarding_free_orders' CHECK (kind IN ('onboarding_free_orders')),
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  source TEXT NOT NULL CHECK (source IN ('plan', 'promotion', 'admin')),
  source_ref TEXT,
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) >= 3),
  -- The launch grant that comes with a plan is given ONCE per licence number and once per owner, so opening more accounts cannot earn it again.
  licence_key TEXT,
  owner_key UUID,
  expires_at TIMESTAMPTZ,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (source <> 'plan' OR owner_key IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS billing_allowance_grants_business_idx ON public.billing_allowance_grants (business_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS billing_allowance_grants_plan_licence_idx ON public.billing_allowance_grants (kind, licence_key) WHERE source = 'plan' AND licence_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS billing_allowance_grants_plan_owner_idx ON public.billing_allowance_grants (kind, owner_key) WHERE source = 'plan' AND owner_key IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Billing periods
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  subscription_id UUID REFERENCES public.billing_subscriptions(id) ON DELETE RESTRICT,
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  shadow BOOLEAN NOT NULL DEFAULT FALSE,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'invoiced', 'partially_paid', 'paid', 'overdue', 'closed')),
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency ~ '^[A-Z]{3}$'),
  -- Totals below are maintained only by the billing functions and can always be re-derived from the ledger (the reconciliation checks compare them).
  subscription_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (subscription_amount >= 0),
  transaction_fees_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (transaction_fees_amount >= 0),
  debits_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (debits_amount >= 0),
  credits_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (credits_amount >= 0),
  amount_due NUMERIC(12,2) GENERATED ALWAYS AS (subscription_amount + transaction_fees_amount + debits_amount - credits_amount) STORED,
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  outstanding_amount NUMERIC(12,2) GENERATED ALWAYS AS (subscription_amount + transaction_fees_amount + debits_amount - credits_amount - amount_paid) STORED,
  billable_gmv NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (billable_gmv >= 0),
  eligible_orders INTEGER NOT NULL DEFAULT 0 CHECK (eligible_orders >= 0),
  free_onboarding_orders INTEGER NOT NULL DEFAULT 0 CHECK (free_onboarding_orders >= 0),
  free_monthly_orders INTEGER NOT NULL DEFAULT 0 CHECK (free_monthly_orders >= 0),
  chargeable_orders INTEGER NOT NULL DEFAULT 0 CHECK (chargeable_orders >= 0),
  fees_before_cap NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (fees_before_cap >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (period_end > period_start),
  UNIQUE (business_id, period_start)
);
CREATE INDEX IF NOT EXISTS billing_periods_business_idx ON public.billing_periods (business_id, period_start DESC);
CREATE INDEX IF NOT EXISTS billing_periods_status_idx ON public.billing_periods (status, period_end);

-- ---------------------------------------------------------------------------
-- 6. Per-order assessments (immutable snapshot of how an order was billed)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_billing_assessments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  retailer_business_id UUID REFERENCES public.businesses(id) ON DELETE RESTRICT,
  -- primary: the assessment when the order was delivered. adjustment: a later change in the order's value (a delivery credit, a back-order shipment, a returned item).
  kind TEXT NOT NULL DEFAULT 'primary' CHECK (kind IN ('primary', 'adjustment')),
  adjustment_seq INTEGER NOT NULL DEFAULT 0 CHECK (adjustment_seq >= 0),
  shadow BOOLEAN NOT NULL DEFAULT FALSE,
  period_id UUID REFERENCES public.billing_periods(id) ON DELETE RESTRICT,
  subscription_terms_id UUID REFERENCES public.billing_subscription_terms(id) ON DELETE RESTRICT,
  plan_version_id UUID REFERENCES public.billing_plan_versions(id) ON DELETE RESTRICT,
  delivered_at TIMESTAMPTZ,
  assessed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency ~ '^[A-Z]{3}$'),
  -- The value the fee is based on: goods after discounts and accepted shortages, without the delivery fee. For an adjustment: the change (may be negative).
  billable_gmv NUMERIC(14,2) NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('exempt', 'excluded', 'below_minimum', 'free_onboarding', 'free_monthly', 'chargeable')),
  free_source TEXT CHECK (free_source IS NULL OR free_source IN ('onboarding', 'monthly')),
  free_seq INTEGER CHECK (free_seq IS NULL OR free_seq > 0),
  grant_id UUID REFERENCES public.billing_allowance_grants(id) ON DELETE RESTRICT,
  percentage NUMERIC(7,4),
  calculated_fee NUMERIC(12,2),
  fee_after_limits NUMERIC(12,2),
  cap_adjustment NUMERIC(12,2),
  charged_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  -- Every parameter used (plan version values with any overrides applied) and the version of the rules that calculated it, so history stays explainable after prices change.
  terms_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(terms_snapshot) = 'object'),
  rule_version TEXT NOT NULL DEFAULT 'unversioned',
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CHECK ((kind = 'primary') = (adjustment_seq = 0)),
  CHECK ((outcome = 'free_onboarding') = (COALESCE(free_source, '') = 'onboarding')),
  CHECK ((outcome = 'free_monthly') = (COALESCE(free_source, '') = 'monthly')),
  CHECK (free_source IS NULL OR free_seq IS NOT NULL),
  CHECK (COALESCE(free_source, '') <> 'onboarding' OR grant_id IS NOT NULL),
  CHECK (outcome = 'chargeable' OR charged_amount = 0)
);
-- One primary assessment per order (separately for shadow and real), and each adjustment number once.
CREATE UNIQUE INDEX IF NOT EXISTS order_billing_primary_real_idx ON public.order_billing_assessments (order_id) WHERE kind = 'primary' AND NOT shadow;
CREATE UNIQUE INDEX IF NOT EXISTS order_billing_primary_shadow_idx ON public.order_billing_assessments (order_id) WHERE kind = 'primary' AND shadow;
CREATE UNIQUE INDEX IF NOT EXISTS order_billing_adjustment_idx ON public.order_billing_assessments (order_id, adjustment_seq, shadow) WHERE kind = 'adjustment';
-- Each free-order number is consumed by exactly one order: onboarding numbers per grant, monthly numbers per period.
CREATE UNIQUE INDEX IF NOT EXISTS order_billing_onboarding_seq_idx ON public.order_billing_assessments (grant_id, free_seq) WHERE free_source = 'onboarding' AND NOT shadow;
CREATE UNIQUE INDEX IF NOT EXISTS order_billing_monthly_seq_idx ON public.order_billing_assessments (period_id, free_seq) WHERE free_source = 'monthly' AND NOT shadow;
CREATE INDEX IF NOT EXISTS order_billing_business_idx ON public.order_billing_assessments (business_id, assessed_at DESC);
CREATE INDEX IF NOT EXISTS order_billing_period_idx ON public.order_billing_assessments (period_id);
CREATE INDEX IF NOT EXISTS order_billing_order_idx ON public.order_billing_assessments (order_id);

-- ---------------------------------------------------------------------------
-- 7. The ledger (append-only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  period_id UUID REFERENCES public.billing_periods(id) ON DELETE RESTRICT,
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT,
  assessment_id UUID REFERENCES public.order_billing_assessments(id) ON DELETE RESTRICT,
  entry_type TEXT NOT NULL CHECK (entry_type IN ('subscription_charge', 'transaction_fee', 'free_order', 'fee_cap_adjustment', 'promotional_credit', 'manual_credit', 'manual_debit',
                                                   'refund', 'reversal', 'fee_waiver')),
  shadow BOOLEAN NOT NULL DEFAULT FALSE,
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency ~ '^[A-Z]{3}$'),
  gross_amount NUMERIC(14,2),
  percentage NUMERIC(7,4),
  calculated_fee NUMERIC(12,2),
  -- What the business is charged (adds to what it owes) or credited (reduces it). Never both on one entry.
  charged_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (charged_amount >= 0),
  credit_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (credit_amount >= 0),
  reason TEXT,
  source TEXT NOT NULL DEFAULT 'engine' CHECK (source IN ('engine', 'admin', 'system', 'promotion')),
  reverses_entry_id UUID REFERENCES public.billing_ledger_entries(id) ON DELETE RESTRICT,
  idempotency_key TEXT NOT NULL UNIQUE CHECK (char_length(idempotency_key) BETWEEN 3 AND 200),
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  CHECK (NOT (charged_amount > 0 AND credit_amount > 0)),
  -- Manual and corrective entries must say why.
  CHECK (entry_type NOT IN ('manual_credit', 'manual_debit', 'promotional_credit', 'fee_waiver', 'refund', 'reversal') OR char_length(btrim(COALESCE(reason, ''))) >= 3),
  CHECK (entry_type <> 'reversal' OR reverses_entry_id IS NOT NULL)
);
-- An entry can be reversed once.
CREATE UNIQUE INDEX IF NOT EXISTS billing_ledger_reverses_idx ON public.billing_ledger_entries (reverses_entry_id) WHERE reverses_entry_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS billing_ledger_business_idx ON public.billing_ledger_entries (business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS billing_ledger_period_idx ON public.billing_ledger_entries (period_id);
CREATE INDEX IF NOT EXISTS billing_ledger_order_idx ON public.billing_ledger_entries (order_id) WHERE order_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS billing_ledger_type_idx ON public.billing_ledger_entries (entry_type, created_at DESC);

-- ---------------------------------------------------------------------------
-- 8. Integrity triggers
-- ---------------------------------------------------------------------------
-- Append-only tables: never updated, never deleted.
CREATE OR REPLACE FUNCTION public.billing_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'Billing records are never changed or deleted (%). Record a correction instead.', TG_TABLE_NAME;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_terms_append_only ON public.billing_subscription_terms;
CREATE TRIGGER trg_billing_terms_append_only BEFORE UPDATE OR DELETE ON public.billing_subscription_terms FOR EACH ROW EXECUTE FUNCTION public.billing_append_only();
DROP TRIGGER IF EXISTS trg_billing_grants_append_only ON public.billing_allowance_grants;
CREATE TRIGGER trg_billing_grants_append_only BEFORE UPDATE OR DELETE ON public.billing_allowance_grants FOR EACH ROW EXECUTE FUNCTION public.billing_append_only();
DROP TRIGGER IF EXISTS trg_billing_ledger_append_only ON public.billing_ledger_entries;
CREATE TRIGGER trg_billing_ledger_append_only BEFORE UPDATE OR DELETE ON public.billing_ledger_entries FOR EACH ROW EXECUTE FUNCTION public.billing_append_only();
DROP TRIGGER IF EXISTS trg_billing_assessments_append_only ON public.order_billing_assessments;
CREATE TRIGGER trg_billing_assessments_append_only BEFORE UPDATE OR DELETE ON public.order_billing_assessments FOR EACH ROW EXECUTE FUNCTION public.billing_append_only();

-- Plan versions: the terms never change; only published -> retired. Entitlements must be features that exist in the catalog, with the right kind of value.
CREATE OR REPLACE FUNCTION public.billing_plan_versions_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_key TEXT;
  v_val JSONB;
  v_type TEXT;
  v_plan_type public.business_type;
  v_feature_type public.business_type;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A published plan version is never deleted. Retire it instead.'; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.plan_id <> OLD.plan_id OR NEW.version <> OLD.version OR NEW.billing_interval_months <> OLD.billing_interval_months OR NEW.currency <> OLD.currency
       OR NEW.subscription_amount <> OLD.subscription_amount OR NEW.free_trial_days <> OLD.free_trial_days OR NEW.onboarding_free_orders <> OLD.onboarding_free_orders
       OR NEW.monthly_free_orders <> OLD.monthly_free_orders OR NEW.transaction_fee_percentage <> OLD.transaction_fee_percentage
       OR NEW.transaction_fee_min IS DISTINCT FROM OLD.transaction_fee_min OR NEW.transaction_fee_max IS DISTINCT FROM OLD.transaction_fee_max
       OR NEW.transaction_fee_cycle_cap IS DISTINCT FROM OLD.transaction_fee_cycle_cap OR NEW.min_billable_order_amount IS DISTINCT FROM OLD.min_billable_order_amount
       OR NEW.max_users IS DISTINCT FROM OLD.max_users OR NEW.max_branches IS DISTINCT FROM OLD.max_branches OR NEW.entitlements <> OLD.entitlements
       OR NEW.metadata <> OLD.metadata OR NEW.effective_from <> OLD.effective_from OR NEW.reason <> OLD.reason OR NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'The terms of a published plan version never change. Publish a new version instead.';
    END IF;
    IF OLD.status = 'retired' AND NEW.status <> 'retired' THEN RAISE EXCEPTION 'A retired plan version cannot be published again.'; END IF;
    RETURN NEW;
  END IF;
  -- INSERT: validate the entitlements against the catalog.
  SELECT p.business_type INTO v_plan_type FROM public.billing_plans p WHERE p.id = NEW.plan_id;
  FOR v_key, v_val IN SELECT * FROM jsonb_each(NEW.entitlements) LOOP
    SELECT c.value_type, c.business_type INTO v_type, v_feature_type FROM public.billing_feature_catalog c WHERE c.key = v_key AND c.active;
    IF v_type IS NULL THEN RAISE EXCEPTION 'Unknown plan feature "%". Add it to the feature catalog first.', v_key; END IF;
    IF v_feature_type IS NOT NULL AND v_feature_type <> v_plan_type THEN RAISE EXCEPTION 'The feature "%" is not available to this kind of business.', v_key; END IF;
    IF v_type = 'boolean' AND jsonb_typeof(v_val) <> 'boolean' THEN RAISE EXCEPTION 'The feature "%" must be true or false.', v_key; END IF;
    IF v_type = 'integer' AND NOT (jsonb_typeof(v_val) = 'number' AND (v_val #>> '{}') ~ '^[0-9]+$') THEN RAISE EXCEPTION 'The feature "%" must be a whole number.', v_key; END IF;
  END LOOP;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_plan_versions_guard ON public.billing_plan_versions;
CREATE TRIGGER trg_billing_plan_versions_guard BEFORE INSERT OR UPDATE OR DELETE ON public.billing_plan_versions FOR EACH ROW EXECUTE FUNCTION public.billing_plan_versions_guard();

-- A plan's identity (code, kind, business type) never changes.
CREATE OR REPLACE FUNCTION public.billing_plans_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A plan is never deleted. Switch it off instead.'; END IF;
  IF NEW.code <> OLD.code OR NEW.business_type <> OLD.business_type OR NEW.kind <> OLD.kind THEN RAISE EXCEPTION 'A plan''s code, kind and business type never change.'; END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_plans_guard ON public.billing_plans;
CREATE TRIGGER trg_billing_plans_guard BEFORE UPDATE OR DELETE ON public.billing_plans FOR EACH ROW EXECUTE FUNCTION public.billing_plans_guard();

-- Subscription terms: the overrides may only name known parameters with the right kind of value; the plan version must belong to a plan for this kind of business; a new row
-- cannot start before an earlier one.
CREATE OR REPLACE FUNCTION public.billing_subscription_terms_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_key TEXT;
  v_val JSONB;
  v_biz_type public.business_type;
  v_plan_type public.business_type;
BEGIN
  FOR v_key, v_val IN SELECT * FROM jsonb_each(NEW.overrides) LOOP
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
  SELECT b.type INTO v_biz_type FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id WHERE s.id = NEW.subscription_id;
  SELECT p.business_type INTO v_plan_type FROM public.billing_plan_versions v JOIN public.billing_plans p ON p.id = v.plan_id WHERE v.id = NEW.plan_version_id;
  IF v_biz_type IS DISTINCT FROM v_plan_type THEN RAISE EXCEPTION 'This plan is for a different kind of business.'; END IF;
  IF EXISTS (SELECT 1 FROM public.billing_subscription_terms t WHERE t.subscription_id = NEW.subscription_id AND t.effective_from > NEW.effective_from) THEN
    RAISE EXCEPTION 'New terms cannot start before terms that already exist.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_subscription_terms_guard ON public.billing_subscription_terms;
CREATE TRIGGER trg_billing_subscription_terms_guard BEFORE INSERT ON public.billing_subscription_terms FOR EACH ROW EXECUTE FUNCTION public.billing_subscription_terms_guard();

-- Subscriptions: the business never changes, and only a wholesaler or pharmacy business can be subscribed.
CREATE OR REPLACE FUNCTION public.billing_subscriptions_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A subscription is never deleted. Cancel it instead.'; END IF;
  IF NEW.business_id <> OLD.business_id OR NEW.billing_starts_at <> OLD.billing_starts_at OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'A subscription''s business and billing start date never change.';
  END IF;
  IF OLD.status = 'cancelled' AND NEW.status <> 'cancelled' THEN RAISE EXCEPTION 'A cancelled subscription cannot be reopened. Start a new one.'; END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_subscriptions_guard ON public.billing_subscriptions;
CREATE TRIGGER trg_billing_subscriptions_guard BEFORE UPDATE OR DELETE ON public.billing_subscriptions FOR EACH ROW EXECUTE FUNCTION public.billing_subscriptions_guard();

-- Periods: identity never changes, they never overlap for one business and kind (real or shadow), and they are never deleted.
CREATE OR REPLACE FUNCTION public.billing_periods_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A billing period is never deleted.'; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.business_id <> OLD.business_id OR NEW.period_start <> OLD.period_start OR NEW.period_end <> OLD.period_end OR NEW.shadow <> OLD.shadow
       OR NEW.subscription_id IS DISTINCT FROM OLD.subscription_id OR NEW.currency <> OLD.currency THEN
      RAISE EXCEPTION 'A billing period''s business, dates and kind never change.';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  IF EXISTS (SELECT 1 FROM public.billing_periods p WHERE p.business_id = NEW.business_id AND p.shadow = NEW.shadow AND p.period_start < NEW.period_end AND p.period_end > NEW.period_start) THEN
    RAISE EXCEPTION 'Billing periods for one business cannot overlap.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_periods_guard ON public.billing_periods;
CREATE TRIGGER trg_billing_periods_guard BEFORE INSERT OR UPDATE OR DELETE ON public.billing_periods FOR EACH ROW EXECUTE FUNCTION public.billing_periods_guard();

-- ---------------------------------------------------------------------------
-- 9. Who may read what (RLS). Nobody writes directly: no INSERT, UPDATE or DELETE grant exists for signed-in users.
-- ---------------------------------------------------------------------------
-- Owner, managers and finance/accounting staff of a business may see its billing.
CREATE OR REPLACE FUNCTION public.billing_user_can_view(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR (public.is_business_staff(auth.uid(), p_business_id) AND public.get_staff_role(auth.uid(), p_business_id)::TEXT IN ('owner', 'manager', 'finance', 'accountant'))
  )
$$;
REVOKE ALL ON FUNCTION public.billing_user_can_view(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.billing_user_can_view(UUID) TO authenticated, service_role;

ALTER TABLE public.billing_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_feature_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_plan_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_subscription_terms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_allowance_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_billing_assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_ledger_entries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.billing_settings, public.billing_feature_catalog, public.billing_plans, public.billing_plan_versions, public.billing_subscriptions, public.billing_subscription_terms,
  public.billing_allowance_grants, public.billing_periods, public.order_billing_assessments, public.billing_ledger_entries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.billing_settings, public.billing_feature_catalog, public.billing_plans, public.billing_plan_versions, public.billing_subscriptions, public.billing_subscription_terms,
  public.billing_allowance_grants, public.billing_periods, public.order_billing_assessments, public.billing_ledger_entries TO authenticated;

DROP POLICY IF EXISTS "Admins read billing settings" ON public.billing_settings;
CREATE POLICY "Admins read billing settings" ON public.billing_settings FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Signed-in users read the feature catalog" ON public.billing_feature_catalog;
CREATE POLICY "Signed-in users read the feature catalog" ON public.billing_feature_catalog FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS "Admins read plans, everyone sees visible plans" ON public.billing_plans;
CREATE POLICY "Admins read plans, everyone sees visible plans" ON public.billing_plans FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR (active AND publicly_visible));
DROP POLICY IF EXISTS "Admins read plan versions, everyone sees visible ones" ON public.billing_plan_versions;
CREATE POLICY "Admins read plan versions, everyone sees visible ones" ON public.billing_plan_versions FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR (status = 'published' AND EXISTS (SELECT 1 FROM public.billing_plans p WHERE p.id = plan_id AND p.active AND p.publicly_visible)));

DROP POLICY IF EXISTS "Own business reads its subscription" ON public.billing_subscriptions;
CREATE POLICY "Own business reads its subscription" ON public.billing_subscriptions FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.billing_user_can_view(business_id));
DROP POLICY IF EXISTS "Own business reads its terms" ON public.billing_subscription_terms;
CREATE POLICY "Own business reads its terms" ON public.billing_subscription_terms FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR EXISTS (SELECT 1 FROM public.billing_subscriptions s WHERE s.id = subscription_id AND public.billing_user_can_view(s.business_id)));
DROP POLICY IF EXISTS "Own business reads its grants" ON public.billing_allowance_grants;
CREATE POLICY "Own business reads its grants" ON public.billing_allowance_grants FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.billing_user_can_view(business_id));
-- Shadow rows ("what it would have been") are for the platform only until a later phase deliberately shows an estimate.
DROP POLICY IF EXISTS "Own business reads its periods" ON public.billing_periods;
CREATE POLICY "Own business reads its periods" ON public.billing_periods FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR (NOT shadow AND public.billing_user_can_view(business_id)));
DROP POLICY IF EXISTS "Own business reads its assessments" ON public.order_billing_assessments;
CREATE POLICY "Own business reads its assessments" ON public.order_billing_assessments FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR (NOT shadow AND public.billing_user_can_view(business_id)));
DROP POLICY IF EXISTS "Own business reads its ledger" ON public.billing_ledger_entries;
CREATE POLICY "Own business reads its ledger" ON public.billing_ledger_entries FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR (NOT shadow AND public.billing_user_can_view(business_id)));
