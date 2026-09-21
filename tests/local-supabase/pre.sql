-- PRE: previous (production-equivalent) definitions. Everything here is EXPECTED to be exploitable.
SELECT 'null logic: NOT (false OR NULL IN (...)) evaluates to' AS note, (NOT (false OR (NULL::text) IN ('owner','manager'))) IS NULL AS is_null;
SELECT substring(pg_get_functiondef('public.upsert_customer_discount(uuid,uuid,text,numeric,numeric,numeric,timestamptz,timestamptz,text)'::regprocedure) from '[^\n]*get_staff_role[^\n]*') AS old_guard_line;

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  r TEXT;
BEGIN
  r := zz.run_as((SELECT id FROM zz.u WHERE k='nobody'),
    format('SELECT public.upsert_customer_discount(%L, %L, ''percentage'', 99)', alpha, good));
  PERFORM zz.check('OLD: user with no memberships CAN create discounts for another wholesaler (vulnerable)', r = 'OK', r);

  r := zz.run_as((SELECT id FROM zz.u WHERE k='ph_other'),
    format('SELECT public.upsert_customer_discount(%L, %L, ''percentage'', 98)', alpha, good));
  PERFORM zz.check('OLD: unrelated pharmacy CAN create discounts for another wholesaler (vulnerable)', r = 'OK', r);

  r := zz.run_as((SELECT id FROM zz.u WHERE k='w_other'),
    format('SELECT public.upsert_customer_discount(%L, %L, ''percentage'', 97)', alpha, good));
  PERFORM zz.check('OLD: unrelated wholesaler CAN create discounts for another wholesaler (vulnerable)', r = 'OK', r);

  r := zz.run_as((SELECT id FROM zz.u WHERE k='w_pending'),
    format('SELECT public.upsert_customer_discount(%L, %L, ''percentage'', 10)', (SELECT id FROM zz.b WHERE name='Pending Wholesale'), good));
  PERFORM zz.check('OLD: pending wholesaler CAN create discounts (no approval check)', r = 'OK', r);

  PERFORM zz.check('OLD: pending pharmacy receives negotiated terms via get_my_customer_discount',
    zz.count_as((SELECT id FROM zz.u WHERE k='ph_pending'), format('SELECT * FROM public.get_my_customer_discount(%L)', alpha)) >= 1);
END $$;

SELECT wholesaler_id = (SELECT id FROM zz.b WHERE name='Alpha Wholesale') AS alpha_rows, count(*) FROM public.customer_discounts WHERE discount_percent IN (99,98,97) GROUP BY 1;
