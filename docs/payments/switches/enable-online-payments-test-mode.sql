-- Turns online payments (Pay now) ON for the platform, in TEST mode. Run in the SQL Editor of the PRODUCTION project only when you mean it.
--
-- Both halves must agree before anything works: this switch AND the server environment (PAYMENTS_MODE=test with PAYSTACK_SECRET_KEY=sk_test_...).
-- With either one off, "Pay now" stays unavailable and nothing can be charged. While this is on, "Pay now" appears at checkout for every
-- pharmacy; test-mode payments move no real money, but they do create real, unpaid online orders. Use a test pharmacy and a test supplier.
--
-- Undo it with disable-online-payments.sql. Orders already placed with Pay now stay as they are (a paid one stays paid; an unpaid one can
-- still be paid only while this is on, or cancelled by either side).
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test', updated_at = now(), updated_by = 'SQL Editor' WHERE id;
SELECT online_enabled, mode, updated_at FROM public.payments_settings;
