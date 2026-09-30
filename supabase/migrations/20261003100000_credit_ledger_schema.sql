-- Credit ledger, part 1: schema. Phase 2 of the procurement/credit/RFQ expansion.
--
-- Design notes:
--   * credit_ledger_entries is the append-only source of truth. Corrections are new rows
--     (entry_type='reversal', linked via reverses_entry_id) -- a posted entry is NEVER updated
--     or deleted (the brief's explicit rule: never treat deletion as the correction mechanism).
--   * No separate "invoice" table. A credit order (orders.is_credit_order) already carries
--     everything an invoice needs (number, items, totals, dates) -- see the architecture review:
--     "don't create a shadow object". An invoice's ledger lines are just
--     credit_ledger_entries WHERE order_id = <that order>; its status is computed from them
--     (see credit_invoice_status() in the next migration), not stored redundantly.
--   * credit_payments is a receipt header ("I received GHS X on this date, by this method");
--     credit_payment_allocations splits one payment across one or more invoices (or an invoice
--     across several payments) -- both directions the brief requires, via one join table rather
--     than a bespoke structure per direction.
--   * amount_ghs is always positive; direction ('debit'/'credit') carries the sign, matching the
--     vocabulary customer_statement() already uses.
--   * RLS follows this codebase's established pattern for financial tables (see
--     wholesaler_credit_terms): enabled, admin-only direct SELECT policy, no write grants at all
--     -- every read/write goes through a SECURITY DEFINER RPC that checks the caller explicitly.

-- Credit orders can be disputed independent of their balance (a fully-outstanding invoice can be
-- disputed with zero money movement) -- extends orders directly, matching how is_credit_order/
-- credit_due_date were added, rather than a new table for two columns.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS credit_disputed_at TIMESTAMPTZ;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS credit_dispute_reason TEXT
  CHECK (credit_dispute_reason IS NULL OR char_length(credit_dispute_reason) <= 500);

CREATE TABLE public.credit_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  amount_ghs NUMERIC(12,2) NOT NULL CHECK (amount_ghs > 0),
  method TEXT NOT NULL CHECK (method IN ('cash', 'bank_transfer', 'mobile_money', 'cheque', 'online', 'other')),
  reference TEXT CHECK (reference IS NULL OR char_length(reference) <= 100),
  paid_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  proof_url TEXT,
  notes TEXT CHECK (notes IS NULL OR char_length(notes) <= 1000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX credit_payments_wholesaler_pharmacy_idx ON public.credit_payments (wholesaler_id, pharmacy_id, paid_at DESC);
ALTER TABLE public.credit_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read credit payments" ON public.credit_payments FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.credit_payments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.credit_payments TO authenticated;

CREATE TABLE public.credit_ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT, -- NULL = unallocated (e.g. credit on account)
  entry_type TEXT NOT NULL CHECK (entry_type IN ('invoice', 'payment', 'adjustment', 'credit_note', 'debit_note', 'write_off', 'reversal')),
  direction TEXT NOT NULL CHECK (direction IN ('debit', 'credit')),
  amount_ghs NUMERIC(12,2) NOT NULL CHECK (amount_ghs > 0),
  payment_id UUID REFERENCES public.credit_payments(id) ON DELETE RESTRICT,
  reverses_entry_id UUID REFERENCES public.credit_ledger_entries(id) ON DELETE RESTRICT,
  note TEXT CHECK (note IS NULL OR char_length(note) <= 500),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((entry_type = 'reversal') = (reverses_entry_id IS NOT NULL))
);
CREATE INDEX credit_ledger_entries_pair_idx ON public.credit_ledger_entries (wholesaler_id, pharmacy_id, created_at);
CREATE INDEX credit_ledger_entries_order_idx ON public.credit_ledger_entries (order_id);
CREATE INDEX credit_ledger_entries_payment_idx ON public.credit_ledger_entries (payment_id);
ALTER TABLE public.credit_ledger_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read credit ledger" ON public.credit_ledger_entries FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.credit_ledger_entries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.credit_ledger_entries TO authenticated;

CREATE TABLE public.credit_payment_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id UUID NOT NULL REFERENCES public.credit_payments(id) ON DELETE CASCADE,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  amount_ghs NUMERIC(12,2) NOT NULL CHECK (amount_ghs > 0),
  ledger_entry_id UUID NOT NULL REFERENCES public.credit_ledger_entries(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (payment_id, order_id)
);
CREATE INDEX credit_payment_allocations_order_idx ON public.credit_payment_allocations (order_id);
ALTER TABLE public.credit_payment_allocations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read credit payment allocations" ON public.credit_payment_allocations FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.credit_payment_allocations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.credit_payment_allocations TO authenticated;
