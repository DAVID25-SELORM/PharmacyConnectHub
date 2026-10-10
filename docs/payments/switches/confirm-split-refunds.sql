-- Records that Paystack has CONFIRMED, in writing, how a refund of a split payment is taken (from the platform's balance, from the supplier's, or shared), and that you
-- are content with it. Run in the SQL Editor of the PRODUCTION project only after you have that confirmation.
--
-- Until this is run, a refund of a split payment is never approved automatically, even with automatic refunds on: it always waits for a platform administrator. Live
-- payments cannot be switched on until it has been run (it is one of the go-live checks on Admin > Payments).
--
-- Undo it with the second statement.
UPDATE public.payments_settings SET split_refunds_confirmed = TRUE, updated_at = now(), updated_by = 'SQL Editor' WHERE id;
-- UPDATE public.payments_settings SET split_refunds_confirmed = FALSE, updated_at = now(), updated_by = 'SQL Editor' WHERE id;
SELECT online_enabled, mode, split_mode, auto_refunds, split_refunds_confirmed FROM public.payments_settings;
