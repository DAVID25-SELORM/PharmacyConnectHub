-- Turns AUTOMATIC REFUNDS off: from now on every refund waits for a platform administrator's approval. Safe to run at any time.
-- Refunds already approved are still sent; to stop one, cancel it on Admin > Payments.
UPDATE public.payments_settings SET auto_refunds = FALSE, updated_at = now(), updated_by = 'SQL Editor' WHERE id;
SELECT online_enabled, mode, auto_refunds FROM public.payments_settings;
