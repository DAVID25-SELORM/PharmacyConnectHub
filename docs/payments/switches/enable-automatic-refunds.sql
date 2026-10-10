-- Turns AUTOMATIC REFUNDS on. Run in the SQL Editor of the PRODUCTION project only when you mean it.
--
-- With this on, refunds that are not in doubt (a payment that arrived after the order was cancelled, a second payment for the same order, an order cancelled after it was paid) are
-- approved the moment they are requested, and the reconciler sends them to the provider on its next run. With it off (the default), every refund waits for a platform administrator
-- to approve it on Admin > Payments. An uncertain refund (outcome unknown) is NEVER retried automatically whatever this says.
--
-- Do this only after you have watched refunds work, with administrator approval, in test mode. Undo it with disable-automatic-refunds.sql.
UPDATE public.payments_settings SET auto_refunds = TRUE, updated_at = now(), updated_by = 'SQL Editor' WHERE id;
SELECT online_enabled, mode, auto_refunds FROM public.payments_settings;
