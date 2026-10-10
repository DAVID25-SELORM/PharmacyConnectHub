-- Sets HOW A PAYMENT IS SPLIT and THE LIMIT for one online payment. Run in the SQL Editor of the PRODUCTION project only when you mean it. Edit the three values below first.
--
--   split_mode         'subaccount'  each payment is split at the moment of payment: the supplier's share settles to the supplier's own account (they must have an active
--                                    settlement account, see Admin > Payments > Supplier settlement accounts), the platform keeps the commission.
--                      'none'        the platform's own Paystack account receives the whole payment (test mode only; live payments need 'subaccount').
--   platform_fee_bps   the platform's commission as basis points of each payment: 100 = 1%, 250 = 2.5%, 0 = none.
--   fee_bearer         'subaccount' the supplier bears Paystack's own fee (the platform's share is exactly the commission), 'account' the platform bears it.
--   max_order_ghs      the most one online payment may be, in cedis (the pilot's low limit). NULL means no limit; live payments need one.
--
-- Takes effect for payments STARTED after this. A payment already started keeps the split it was started with. While live payments are on, the split and the limit cannot be
-- removed (switch online payments off first); a limit can be lowered or raised.
UPDATE public.payments_settings
SET split_mode = 'subaccount',
    platform_fee_bps = 0,
    fee_bearer = 'subaccount',
    max_order_ghs = 500,
    updated_at = now(), updated_by = 'SQL Editor'
WHERE id;
SELECT online_enabled, mode, split_mode, platform_fee_bps, fee_bearer, max_order_ghs FROM public.payments_settings;
