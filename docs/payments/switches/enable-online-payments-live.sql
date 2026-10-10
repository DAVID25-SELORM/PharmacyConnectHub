-- Turns online payments ON in LIVE mode: REAL MONEY. Run in the SQL Editor of the PRODUCTION project only after the readiness check on Admin > Payments says "Ready" and you have read
-- the go-live section of docs/pay-now-paystack-plan.md.
--
-- The database REFUSES this unless every blocking item is met (it names what is missing): payments split to each supplier's own account, a limit for one payment, the
-- reconciler running, a live settlement account, Paystack's refund behaviour for split payments confirmed (confirm-split-refunds.sql), and no open critical alert.
-- The server must ALSO be set for live (PAYMENTS_MODE=live, the live key, PAYMENTS_LIVE_ENABLED=yes); both halves must agree before a payment can start.
--
-- Undo it, instantly and safely, with disable-online-payments.sql (it is never blocked). Payments already in flight are still verified and recorded.
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'live', updated_at = now(), updated_by = 'SQL Editor' WHERE id;
SELECT online_enabled, mode, split_mode, max_order_ghs, updated_at FROM public.payments_settings;
