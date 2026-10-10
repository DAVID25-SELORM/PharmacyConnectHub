-- Read-only DRY RUN for the Pay Now P5 patch (20261111120000_payments_settlement_patches.sql). Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION
-- badge first). It changes nothing. It shows, for the checkout function the patch rewrites and the functions the migration replaces, what production really has:
--   create_marketplace_orders:  versions of that exact six-argument form must be 1; matches must be 1 (or already_patched = true once the patch has been applied).
--   replaced functions:         the "looks like the version I expect" column must be true for each (they are replaced whole, so a different production version would be lost).
-- If any row is not as expected, DO NOT run the migration: tell me which row, and I will adapt it to what production really has.
WITH defs AS (
  SELECT p.proname::text AS fn, pg_get_function_identity_arguments(p.oid) AS args, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
), six AS (
  SELECT def FROM defs WHERE fn = 'create_marketplace_orders'
    AND args = '_caller_id uuid, _pharmacy_id uuid, _items jsonb, _credit_wholesaler_ids uuid[], _require_classification boolean, _settlement_methods jsonb'
)
SELECT 'create_marketplace_orders (six arguments)' AS what,
       (SELECT count(*) FROM six) AS versions,
       (SELECT count(*) FROM six, regexp_matches(six.def, 'RAISE EXCEPTION ''Online payment is not available yet\. Choose another payment method\.'';\s+END IF;', 'g')) AS matches,
       EXISTS (SELECT 1 FROM six WHERE position('payout_account_ready(m.key' IN six.def) > 0) AS already_patched,
       NULL::boolean AS looks_like_expected
UNION ALL
SELECT '_request_refund', (SELECT count(*) FROM defs WHERE fn = '_request_refund'), NULL, NULL,
       EXISTS (SELECT 1 FROM defs WHERE fn = '_request_refund' AND def LIKE '%s.auto_refunds%' AND def LIKE '%amendment_reduction%')
UNION ALL
SELECT 'record_attempt_authorization', (SELECT count(*) FROM defs WHERE fn = 'record_attempt_authorization'), NULL, NULL,
       EXISTS (SELECT 1 FROM defs WHERE fn = 'record_attempt_authorization' AND def LIKE '%attempt_authorized%' AND def LIKE '%The provider returned no secure checkout address%')
UNION ALL
SELECT 'online_payments_status', (SELECT count(*) FROM defs WHERE fn = 'online_payments_status'), NULL, NULL,
       EXISTS (SELECT 1 FROM defs WHERE fn = 'online_payments_status' AND def LIKE '%enabled%' AND def LIKE '%mode%')
UNION ALL
SELECT 'order_payment_attempts_protect', (SELECT count(*) FROM defs WHERE fn = 'order_payment_attempts_protect'), NULL, NULL,
       EXISTS (SELECT 1 FROM defs WHERE fn = 'order_payment_attempts_protect' AND def LIKE '%purpose%')
UNION ALL
SELECT 'payments_settings single row', (SELECT count(*) FROM public.payments_settings), NULL, NULL, TRUE;
