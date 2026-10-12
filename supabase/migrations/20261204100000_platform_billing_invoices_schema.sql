-- Platform billing, Phase 4 (part 1): invoices, invoice lines and payment records.
-- Additive and inert: nothing here charges, issues or changes anything by itself. Real billing periods exist only while billing is ACTIVE, and `active` cannot be switched on yet,
-- so in production these tables stay empty until the final rollout phase.
--
-- An invoice is the bill for ONE real billing period. Its figures and lines are written once, when it is issued, and never edited: only its payment status moves. Payments are
-- append-only records (a mistake is corrected by a reversal, never by deleting). The status of a period and its paid amount are kept in step by the billing functions and checked by the
-- reconciliation. Billing and payment stay separate: nothing in the fee calculation depends on a payment.

-- ---------------------------------------------------------------------------
-- 1. Settings for invoicing
-- ---------------------------------------------------------------------------
ALTER TABLE public.billing_settings
  ADD COLUMN IF NOT EXISTS payment_terms_days INTEGER NOT NULL DEFAULT 14 CHECK (payment_terms_days BETWEEN 0 AND 120),
  ADD COLUMN IF NOT EXISTS invoice_delay_hours INTEGER NOT NULL DEFAULT 24 CHECK (invoice_delay_hours BETWEEN 0 AND 720),
  ADD COLUMN IF NOT EXISTS last_invoice_number BIGINT NOT NULL DEFAULT 0 CHECK (last_invoice_number >= 0),
  ADD COLUMN IF NOT EXISTS issuer JSONB NOT NULL DEFAULT '{"name": "DrugXOne"}'::JSONB CHECK (jsonb_typeof(issuer) = 'object' AND char_length(btrim(COALESCE(issuer ->> 'name', ''))) >= 2);

-- ---------------------------------------------------------------------------
-- 2. Invoices
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number TEXT NOT NULL UNIQUE CHECK (invoice_number ~ '^DXB-[0-9]{4}-[0-9]{6,}$'),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  period_id UUID NOT NULL UNIQUE REFERENCES public.billing_periods(id) ON DELETE RESTRICT,
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency ~ '^[A-Z]{3}$'),
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  due_at TIMESTAMPTZ NOT NULL,
  -- The period's figures at the moment of issue. A period never changes after it is invoiced: late entries land in the current period instead.
  subscription_amount NUMERIC(12,2) NOT NULL CHECK (subscription_amount >= 0),
  transaction_fees_amount NUMERIC(12,2) NOT NULL CHECK (transaction_fees_amount >= 0),
  debits_amount NUMERIC(12,2) NOT NULL CHECK (debits_amount >= 0),
  credits_amount NUMERIC(12,2) NOT NULL CHECK (credits_amount >= 0),
  -- Credit left over from earlier periods whose credits were larger than their charges, used up here (never more than this invoice's charges).
  credit_brought_forward NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (credit_brought_forward >= 0),
  total_amount NUMERIC(12,2) GENERATED ALWAYS AS (subscription_amount + transaction_fees_amount + debits_amount - credits_amount - credit_brought_forward) STORED,
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  outstanding_amount NUMERIC(12,2) GENERATED ALWAYS AS (subscription_amount + transaction_fees_amount + debits_amount - credits_amount - credit_brought_forward - amount_paid) STORED,
  status TEXT NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'partially_paid', 'paid', 'overdue')),
  summary JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(summary) = 'object'),
  issuer JSONB NOT NULL CHECK (jsonb_typeof(issuer) = 'object'),
  customer JSONB NOT NULL CHECK (jsonb_typeof(customer) = 'object'),
  paid_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (period_end > period_start),
  CHECK (due_at >= issued_at),
  CHECK (subscription_amount + transaction_fees_amount + debits_amount - credits_amount - credit_brought_forward >= 0),
  CHECK (amount_paid <= subscription_amount + transaction_fees_amount + debits_amount - credits_amount - credit_brought_forward),
  CHECK ((status = 'paid') = (subscription_amount + transaction_fees_amount + debits_amount - credits_amount - credit_brought_forward - amount_paid = 0))
);
CREATE INDEX IF NOT EXISTS billing_invoices_business_idx ON public.billing_invoices (business_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS billing_invoices_status_idx ON public.billing_invoices (status, due_at);

CREATE TABLE IF NOT EXISTS public.billing_invoice_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id UUID NOT NULL REFERENCES public.billing_invoices(id) ON DELETE RESTRICT,
  line_no INTEGER NOT NULL CHECK (line_no > 0),
  kind TEXT NOT NULL CHECK (kind IN ('subscription', 'transaction_fees', 'other_charge', 'fee_credit', 'credit', 'credit_brought_forward')),
  description TEXT NOT NULL CHECK (char_length(btrim(description)) >= 3),
  -- Signed: charges are positive, credits negative. The lines of an invoice always add up to its total.
  amount NUMERIC(12,2) NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  UNIQUE (invoice_id, line_no)
);

-- ---------------------------------------------------------------------------
-- 3. Payments (append-only; a correction is a reversal)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id UUID NOT NULL REFERENCES public.billing_invoices(id) ON DELETE RESTRICT,
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL DEFAULT 'payment' CHECK (kind IN ('payment', 'reversal')),
  amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency ~ '^[A-Z]{3}$'),
  method TEXT NOT NULL CHECK (method IN ('bank_transfer', 'mobile_money', 'cash', 'cheque', 'card', 'other')),
  -- 'manual' for a payment an administrator recorded; a later automatic provider names itself here and puts its own reference below.
  provider TEXT NOT NULL DEFAULT 'manual' CHECK (char_length(provider) BETWEEN 2 AND 40),
  reference TEXT CHECK (reference IS NULL OR char_length(btrim(reference)) BETWEEN 2 AND 120),
  received_at TIMESTAMPTZ NOT NULL,
  note TEXT CHECK (note IS NULL OR char_length(note) <= 500),
  reason TEXT CHECK (reason IS NULL OR char_length(reason) <= 500),
  reverses_payment_id UUID REFERENCES public.billing_payments(id) ON DELETE RESTRICT,
  idempotency_key TEXT NOT NULL UNIQUE CHECK (char_length(idempotency_key) BETWEEN 3 AND 200),
  recorded_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  CHECK ((kind = 'reversal') = (reverses_payment_id IS NOT NULL)),
  CHECK (kind = 'payment' OR char_length(btrim(COALESCE(reason, ''))) >= 5),
  CHECK (kind = 'reversal' OR reason IS NULL OR char_length(btrim(reason)) >= 5)
);
-- A payment can be reversed once, and the same bank/mobile-money reference is never recorded twice for the same method.
CREATE UNIQUE INDEX IF NOT EXISTS billing_payments_reverses_idx ON public.billing_payments (reverses_payment_id) WHERE reverses_payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS billing_payments_reference_idx ON public.billing_payments (provider, method, lower(btrim(reference))) WHERE kind = 'payment' AND reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS billing_payments_invoice_idx ON public.billing_payments (invoice_id, recorded_at);
CREATE INDEX IF NOT EXISTS billing_payments_business_idx ON public.billing_payments (business_id, received_at DESC);

-- ---------------------------------------------------------------------------
-- 4. Integrity: what may change
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_billing_invoice_lines_append_only ON public.billing_invoice_lines;
CREATE TRIGGER trg_billing_invoice_lines_append_only BEFORE UPDATE OR DELETE ON public.billing_invoice_lines FOR EACH ROW EXECUTE FUNCTION public.billing_append_only();
DROP TRIGGER IF EXISTS trg_billing_payments_append_only ON public.billing_payments;
CREATE TRIGGER trg_billing_payments_append_only BEFORE UPDATE OR DELETE ON public.billing_payments FOR EACH ROW EXECUTE FUNCTION public.billing_append_only();

-- An invoice is never deleted and its figures never change; only how much has been paid, its status and when it was settled move.
CREATE OR REPLACE FUNCTION public.billing_invoices_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Billing records are never changed or deleted (billing_invoices). Record a correction instead.'; END IF;
  IF (NEW.id, NEW.invoice_number, NEW.business_id, NEW.period_id, NEW.currency, NEW.period_start, NEW.period_end, NEW.issued_at, NEW.due_at, NEW.subscription_amount, NEW.transaction_fees_amount,
      NEW.debits_amount, NEW.credits_amount, NEW.credit_brought_forward, NEW.summary, NEW.issuer, NEW.customer, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.invoice_number, OLD.business_id, OLD.period_id, OLD.currency, OLD.period_start, OLD.period_end, OLD.issued_at, OLD.due_at, OLD.subscription_amount, OLD.transaction_fees_amount,
      OLD.debits_amount, OLD.credits_amount, OLD.credit_brought_forward, OLD.summary, OLD.issuer, OLD.customer, OLD.created_at) THEN
    RAISE EXCEPTION 'An issued invoice cannot be edited. Record a credit or a correction in a later period instead.';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_invoices_guard ON public.billing_invoices;
CREATE TRIGGER trg_billing_invoices_guard BEFORE UPDATE OR DELETE ON public.billing_invoices FOR EACH ROW EXECUTE FUNCTION public.billing_invoices_guard();

-- ---------------------------------------------------------------------------
-- 5. Access: businesses read their own (never shadow, which has no invoices), administrators read everything, nobody writes directly
-- ---------------------------------------------------------------------------
ALTER TABLE public.billing_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.billing_invoices, public.billing_invoice_lines, public.billing_payments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.billing_invoices, public.billing_invoice_lines, public.billing_payments TO authenticated;

DROP POLICY IF EXISTS "Own business reads its invoices" ON public.billing_invoices;
CREATE POLICY "Own business reads its invoices" ON public.billing_invoices FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.billing_user_can_view(business_id));
DROP POLICY IF EXISTS "Own business reads its invoice lines" ON public.billing_invoice_lines;
CREATE POLICY "Own business reads its invoice lines" ON public.billing_invoice_lines FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR EXISTS (SELECT 1 FROM public.billing_invoices i WHERE i.id = invoice_id AND public.billing_user_can_view(i.business_id)));
DROP POLICY IF EXISTS "Own business reads its payments" ON public.billing_payments;
CREATE POLICY "Own business reads its payments" ON public.billing_payments FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.billing_user_can_view(business_id));
