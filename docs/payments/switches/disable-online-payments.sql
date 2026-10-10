-- Turns online payments (Pay now) OFF for the platform. Safe to run at any time, and the first thing to do if something looks wrong.
--
-- Effect: "Pay now" is no longer offered at checkout, checkout refuses it (the same message as before online payments existed), and no new payment
-- can be started. Payments that are already in flight are still verified and recorded when the provider confirms them (the webhook and the
-- return page keep working), so money that was taken is never lost track of. Orders already paid stay paid.
UPDATE public.payments_settings SET online_enabled = FALSE, updated_at = now(), updated_by = 'SQL Editor' WHERE id;
SELECT online_enabled, mode, updated_at FROM public.payments_settings;
