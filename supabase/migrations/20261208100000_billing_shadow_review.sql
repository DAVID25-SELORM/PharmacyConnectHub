-- Shadow billing review: an independent, read-only recalculation of what shadow billing recorded.
-- It writes nothing and changes no billing rule. It exists so that the administrator does not have to check the fee on a few orders by hand:
-- every shadow fee is worked out again from the order value and the terms saved with the assessment, with its own copy of the arithmetic (it does not call the engine's fee function),
-- and anything that differs is listed with both figures.
-- Apply after 20261207100000_platform_billing_audit_fixes.sql. Nothing depends on it: if it is not applied, the Billing Setup page says the review is not available yet.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_billing_shadow_review(p_limit INTEGER DEFAULT 25)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 200);
  v_result JSONB;
BEGIN
  PERFORM public._billing_admin_only();

  WITH s AS (
    -- Every chargeable first assessment of a delivered order, in shadow.
    SELECT a.id, a.order_id, a.business_id, a.billable_gmv, a.percentage, a.calculated_fee, a.fee_after_limits, a.charged_amount, a.cap_adjustment,
           (a.terms_snapshot ->> 'transaction_fee_percentage')::NUMERIC AS snapshot_pct,
           (a.terms_snapshot ->> 'transaction_fee_min')::NUMERIC AS fee_min,
           (a.terms_snapshot ->> 'transaction_fee_max')::NUMERIC AS fee_max,
           o.order_number, b.name AS business_name
    FROM public.order_billing_assessments a
    JOIN public.orders o ON o.id = a.order_id
    JOIN public.businesses b ON b.id = a.business_id
    WHERE a.shadow AND a.kind = 'primary' AND a.outcome = 'chargeable'
  ), calc AS (
    SELECT s.*,
           round(s.billable_gmv * s.percentage / 100, 2) AS re_calculated,
           CASE WHEN s.percentage = 0 OR s.billable_gmv = 0 THEN 0.00
                ELSE round(LEAST(GREATEST(s.billable_gmv * s.percentage / 100, COALESCE(s.fee_min, 0)), COALESCE(s.fee_max, 1000000000000)), 2) END AS re_fee
    FROM s
  ), issues AS (
    SELECT 'fee_formula' AS check_key, c.order_id, c.order_number, c.business_name, c.fee_after_limits AS recorded, c.re_fee AS recalculated,
           'The fee should be ' || c.re_fee || ' for an order value of ' || c.billable_gmv || ' at ' || c.percentage || '%' AS note
    FROM calc c WHERE c.calculated_fee IS DISTINCT FROM c.re_calculated OR c.fee_after_limits IS DISTINCT FROM c.re_fee
    UNION ALL
    SELECT 'terms_used', c.order_id, c.order_number, c.business_name, c.percentage, c.snapshot_pct,
           'The percentage used is not the one saved in the terms for this order'
    FROM calc c WHERE c.percentage IS DISTINCT FROM c.snapshot_pct
    UNION ALL
    SELECT 'charge_split', c.order_id, c.order_number, c.business_name, c.charged_amount + COALESCE(c.cap_adjustment, 0), c.fee_after_limits,
           'The amount charged plus the amount waived by the monthly cap should equal the fee'
    FROM calc c WHERE c.charged_amount + COALESCE(c.cap_adjustment, 0) IS DISTINCT FROM c.fee_after_limits
    UNION ALL
    SELECT 'order_value', x.order_id, o.order_number, b.name, x.assessed, x.current_value,
           'The order value changed after it was assessed; the next billing run adjusts it'
    FROM (
      SELECT a.order_id, a.business_id, sum(a.billable_gmv) AS assessed, public._billing_billable(a.order_id) AS current_value
      FROM public.order_billing_assessments a WHERE a.shadow GROUP BY a.order_id, a.business_id
    ) x
    JOIN public.orders o ON o.id = x.order_id
    JOIN public.businesses b ON b.id = x.business_id
    WHERE x.assessed IS DISTINCT FROM x.current_value
  ), counts AS (
    SELECT check_key, count(*) AS n FROM issues GROUP BY check_key
  )
  SELECT jsonb_build_object(
    'checked_at', now(),
    'assessments_total', (SELECT count(*) FROM public.order_billing_assessments a WHERE a.shadow AND a.kind = 'primary'),
    'recomputed', (SELECT count(*) FROM s),
    'recorded_fee_total', COALESCE((SELECT sum(s.fee_after_limits) FROM s), 0),
    'recalculated_fee_total', COALESCE((SELECT sum(c.re_fee) FROM calc c), 0),
    'checks', jsonb_build_array(
      jsonb_build_object('key', 'fee_formula', 'label', 'Each fee matches the order value and the plan terms', 'severity', 'critical', 'count', COALESCE((SELECT n FROM counts WHERE check_key = 'fee_formula'), 0)),
      jsonb_build_object('key', 'terms_used', 'label', 'Each fee used the percentage saved in its terms', 'severity', 'critical', 'count', COALESCE((SELECT n FROM counts WHERE check_key = 'terms_used'), 0)),
      jsonb_build_object('key', 'charge_split', 'label', 'Each amount charged plus the monthly cap adds up to its fee', 'severity', 'critical', 'count', COALESCE((SELECT n FROM counts WHERE check_key = 'charge_split'), 0)),
      jsonb_build_object('key', 'order_value', 'label', 'No order changed in value without being adjusted', 'severity', 'warning', 'count', COALESCE((SELECT n FROM counts WHERE check_key = 'order_value'), 0))),
    'rows', COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM (
      SELECT i.check_key AS check, i.order_id, i.order_number, i.business_name, i.recorded, i.recalculated, i.recorded - i.recalculated AS difference, i.note
      FROM issues i ORDER BY abs(i.recorded - i.recalculated) DESC, i.order_number LIMIT v_limit) r), '[]'::JSONB))
  INTO v_result;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_shadow_review(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_shadow_review(INTEGER) TO authenticated;

COMMIT;
