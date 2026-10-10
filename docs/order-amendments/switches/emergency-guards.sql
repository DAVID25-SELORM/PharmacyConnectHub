-- Order amendments: EMERGENCY ONLY. Every statement below is commented out on purpose.
--
-- The amendment features add three guards on the orders table. They exist to protect money and stock, so switching one off is
-- a last resort: use it only to unblock real work while a defect is being fixed, tell the platform owner, and switch it back on
-- the same day (the matching ENABLE line). Prefer the switches in this folder, which stop new work without removing any guard.
-- Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first), one line at a time.

-- 1. "No dispatch while a proposal is open" (a supply-change or price proposal waiting for the pharmacy blocks dispatch).
--    A stuck proposal is normally closed by withdrawing it (wholesaler) or by the pharmacy answering; use this only if neither can happen.
-- ALTER TABLE public.orders DISABLE TRIGGER trg_block_dispatch_during_amendment;
-- ALTER TABLE public.orders ENABLE TRIGGER trg_block_dispatch_during_amendment;

-- 2. "A cash order collected portion by portion cannot be marked paid by a direct update" (only confirm_cash_collection can).
--    Disabling it lets staff mark such an order paid without recording which portion was collected.
-- ALTER TABLE public.orders DISABLE TRIGGER trg_guard_cash_portion_payment;
-- ALTER TABLE public.orders ENABLE TRIGGER trg_guard_cash_portion_payment;

-- 3. "The order total only changes through an approved amendment or shipment". NEVER disable this to work around a screen: with
--    it off, any staff member can change what a pharmacy owes without its approval. Only on the platform owner's instruction.
-- ALTER TABLE public.orders DISABLE TRIGGER trg_protect_effective_total;
-- ALTER TABLE public.orders ENABLE TRIGGER trg_protect_effective_total;
