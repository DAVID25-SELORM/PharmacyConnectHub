-- Online payments (Pay Now), phase P5 part 1: SETTLEMENT (where a payment's money ends up) and the controls for going live. Nothing here changes how any order or
-- payment behaves while the new settings keep their defaults. See docs/pay-now-paystack-plan.md (section 17).
--
--   payments_settings        split_mode           'none' (the platform's own Paystack account receives everything: test mode) or 'subaccount' (each payment is split at the moment of
--                                                 payment and the supplier's share settles to the supplier's own bank or mobile money account).
--                            platform_fee_bps     the platform's commission in basis points (100 = 1%) of each payment, 0 for none.
--                            fee_bearer           who bears Paystack's own fee on a split payment: 'account' (the platform) or 'subaccount' (the supplier; the default, so the platform's share can never be less than nothing).
--                            max_order_ghs        the most one online payment may be (the pilot's low cap); empty means no cap.
--                            split_refunds_confirmed   set by a person only once Paystack has confirmed in writing how a refund of a split payment is taken; until then a refund of a
--                                                 split payment is never approved automatically.
--                            reconciler_*_at      when each reconciler job last ran (so "is the scheduler running" can be checked before going live).
--   supplier_payout_accounts one row per supplier and mode: the supplier's Paystack subaccount code and which bank it settles to. The full account number is NEVER stored here
--                            (it is sent to Paystack once and only its last four digits are kept).
--   order_payment_attempts   split_subaccount / split_charge_minor / split_bearer record what each payment was split with, and prepared_at that it passed the last check before
--                            being sent to the provider. They are written once and never changed.

ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS split_mode TEXT NOT NULL DEFAULT 'none';
ALTER TABLE public.payments_settings DROP CONSTRAINT IF EXISTS payments_settings_split_mode_check;
ALTER TABLE public.payments_settings ADD CONSTRAINT payments_settings_split_mode_check CHECK (split_mode IN ('none', 'subaccount'));
ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS platform_fee_bps INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.payments_settings DROP CONSTRAINT IF EXISTS payments_settings_platform_fee_bps_check;
ALTER TABLE public.payments_settings ADD CONSTRAINT payments_settings_platform_fee_bps_check CHECK (platform_fee_bps BETWEEN 0 AND 5000);
ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS fee_bearer TEXT NOT NULL DEFAULT 'subaccount';
ALTER TABLE public.payments_settings DROP CONSTRAINT IF EXISTS payments_settings_fee_bearer_check;
ALTER TABLE public.payments_settings ADD CONSTRAINT payments_settings_fee_bearer_check CHECK (fee_bearer IN ('account', 'subaccount'));
ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS max_order_ghs NUMERIC(12,2);
ALTER TABLE public.payments_settings DROP CONSTRAINT IF EXISTS payments_settings_max_order_ghs_check;
ALTER TABLE public.payments_settings ADD CONSTRAINT payments_settings_max_order_ghs_check CHECK (max_order_ghs IS NULL OR max_order_ghs > 0);
ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS split_refunds_confirmed BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS reconciler_frequent_at TIMESTAMPTZ;
ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS reconciler_daily_at TIMESTAMPTZ;

-- ---------------------------------------------------------------------------
-- Payout accounts
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.supplier_payout_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  provider TEXT NOT NULL DEFAULT 'paystack' CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  mode TEXT NOT NULL CHECK (mode IN ('test', 'live')),
  business_name TEXT NOT NULL CHECK (length(btrim(business_name)) BETWEEN 2 AND 120),
  settlement_bank_code TEXT NOT NULL CHECK (settlement_bank_code ~ '^[A-Za-z0-9_-]{1,20}$'),
  account_last4 TEXT NOT NULL CHECK (account_last4 ~ '^[0-9]{2,4}$'),
  -- pending: being created at the provider; active: usable; inactive: switched off by an administrator; failed: the provider refused (or the answer was lost)
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'inactive', 'failed')),
  provider_subaccount_code TEXT CHECK (provider_subaccount_code IS NULL OR provider_subaccount_code ~ '^[A-Za-z0-9_-]{3,60}$'),
  failure_reason TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status <> 'active' OR provider_subaccount_code IS NOT NULL)
);
-- A supplier has at most one usable (or being-made) account per provider and mode; failed and switched-off ones are kept as history.
CREATE UNIQUE INDEX IF NOT EXISTS supplier_payout_accounts_one_live_idx
  ON public.supplier_payout_accounts (wholesaler_id, provider, mode) WHERE status IN ('pending', 'active');
CREATE UNIQUE INDEX IF NOT EXISTS supplier_payout_accounts_code_idx
  ON public.supplier_payout_accounts (provider, provider_subaccount_code) WHERE provider_subaccount_code IS NOT NULL;

ALTER TABLE public.supplier_payout_accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read payout accounts" ON public.supplier_payout_accounts;
CREATE POLICY "Admins read payout accounts" ON public.supplier_payout_accounts FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.supplier_payout_accounts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.supplier_payout_accounts TO authenticated;

-- What a payout account was made for never changes (only its status and the provider's answer do).
CREATE OR REPLACE FUNCTION public.supplier_payout_accounts_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Payout accounts are never deleted.'; END IF;
  IF NEW.wholesaler_id <> OLD.wholesaler_id OR NEW.provider <> OLD.provider OR NEW.mode <> OLD.mode OR NEW.settlement_bank_code <> OLD.settlement_bank_code
     OR NEW.account_last4 <> OLD.account_last4 OR NEW.business_name <> OLD.business_name THEN
    RAISE EXCEPTION 'What a payout account was made for cannot be changed.';
  END IF;
  IF OLD.provider_subaccount_code IS NOT NULL AND NEW.provider_subaccount_code IS DISTINCT FROM OLD.provider_subaccount_code THEN
    RAISE EXCEPTION 'The provider''s account code cannot be changed.';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_supplier_payout_accounts_protect ON public.supplier_payout_accounts;
CREATE TRIGGER trg_supplier_payout_accounts_protect BEFORE UPDATE OR DELETE ON public.supplier_payout_accounts
  FOR EACH ROW EXECUTE FUNCTION public.supplier_payout_accounts_protect();

-- ---------------------------------------------------------------------------
-- What each payment was split with
-- ---------------------------------------------------------------------------
ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS split_subaccount TEXT;
ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS split_charge_minor BIGINT;
ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS split_bearer TEXT;
ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS prepared_at TIMESTAMPTZ;
ALTER TABLE public.order_payment_attempts DROP CONSTRAINT IF EXISTS order_payment_attempts_split_check;
ALTER TABLE public.order_payment_attempts ADD CONSTRAINT order_payment_attempts_split_check CHECK (
  (split_subaccount IS NULL AND split_charge_minor IS NULL AND split_bearer IS NULL)
  OR (split_subaccount IS NOT NULL AND split_charge_minor IS NOT NULL AND split_charge_minor >= 0 AND split_charge_minor <= amount_minor
      AND split_bearer IN ('account', 'subaccount')));

-- The P4b protection, with the split and the preparation step added: once set they never change.
CREATE OR REPLACE FUNCTION public.order_payment_attempts_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Payment attempts are never deleted.'; END IF;
  IF NEW.order_id <> OLD.order_id OR NEW.provider <> OLD.provider OR NEW.mode <> OLD.mode OR NEW.reference <> OLD.reference
     OR NEW.amount_ghs <> OLD.amount_ghs OR NEW.amount_minor <> OLD.amount_minor OR NEW.currency <> OLD.currency
     OR NEW.initiated_at <> OLD.initiated_at OR NEW.purpose <> OLD.purpose THEN
    RAISE EXCEPTION 'What was asked of the provider cannot be changed.';
  END IF;
  IF OLD.prepared_at IS NOT NULL AND (NEW.prepared_at IS DISTINCT FROM OLD.prepared_at OR NEW.split_subaccount IS DISTINCT FROM OLD.split_subaccount
     OR NEW.split_charge_minor IS DISTINCT FROM OLD.split_charge_minor OR NEW.split_bearer IS DISTINCT FROM OLD.split_bearer) THEN
    RAISE EXCEPTION 'How a payment was split cannot be changed.';
  END IF;
  RETURN NEW;
END;
$$;
