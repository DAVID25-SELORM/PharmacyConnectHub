-- Read-only checks after applying 20261207100000_platform_billing_audit_fixes.sql.
-- A nonzero historical finding requires an audited correction, not deletion or rewriting.
SELECT 'conflicting_revenue_settings' AS check_name,count(*) AS findings
FROM public.billing_settings b CROSS JOIN public.payments_settings p
WHERE b.id AND p.id AND b.mode='active' AND p.platform_fee_bps<>0;
SELECT 'real_period_without_activation' AS check_name,count(*) AS findings
FROM public.billing_periods p JOIN public.billing_subscriptions s ON s.id=p.subscription_id
WHERE NOT p.shadow AND (s.activated_at IS NULL OR p.period_start<s.activated_at);
SELECT 'order_fee_overcredited' AS check_name,count(*) AS findings FROM (
 SELECT order_id,shadow FROM public.billing_ledger_entries
 WHERE order_id IS NOT NULL AND entry_type IN ('transaction_fee','refund','fee_waiver')
 GROUP BY order_id,shadow HAVING sum(credit_amount)>sum(charged_amount)
) x;
SELECT tgrelid::regclass AS settings_table,tgname,tgenabled
FROM pg_trigger WHERE tgname IN ('billing_revenue_policy_lock','billing_revenue_policy_guard') ORDER BY 1,2;
