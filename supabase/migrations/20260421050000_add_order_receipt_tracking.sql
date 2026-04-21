-- Track wholesaler payment confirmation and pharmacy receipt delivery for orders.
-- Receipt emails are sent only after the seller confirms money has been received.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS payment_confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS payment_confirmed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS receipt_sent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS receipt_sent_to TEXT;

CREATE INDEX IF NOT EXISTS idx_orders_payment_confirmed_by
  ON public.orders(payment_confirmed_by)
  WHERE payment_confirmed_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_orders_receipt_sent_at
  ON public.orders(receipt_sent_at)
  WHERE receipt_sent_at IS NOT NULL;
