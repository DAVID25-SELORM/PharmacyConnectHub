-- Order amendments: what is still in progress (read-only).
-- Run it before switching anything off, and again afterwards, to see how much is still open. Switching "new work" off never blocks
-- the items counted here: each can still be answered, withdrawn, decided, shipped or collected. Writes nothing.
SELECT item, count
FROM (
  SELECT 1 AS ord, 'supply-change proposals waiting for the pharmacy' AS item, count(*) AS count
  FROM public.order_amendments WHERE kind = 'partial_fulfilment' AND status IN ('proposed', 'clarification_requested')
  UNION ALL
  SELECT 2, 'price proposals waiting for the pharmacy', count(*)
  FROM public.order_amendments WHERE kind = 'price_change' AND status IN ('proposed', 'clarification_requested')
  UNION ALL
  SELECT 3, 'delivery reports waiting for the wholesaler''s decision', count(*)
  FROM public.order_delivery_reports WHERE status = 'submitted'
  UNION ALL
  SELECT 4, 'orders with goods still waiting in a back-order', count(*)
  FROM public.orders o
  WHERE EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = o.id AND a.status = 'accepted' AND a.response_choice = 'accept_backorder')
    AND o.status <> 'cancelled'
    AND COALESCE((public.order_backorder_state(o.id)->>'outstanding')::INTEGER, 0) > 0
  UNION ALL
  SELECT 5, 'back-order shipments not yet delivered (being prepared, packed or on their way)', count(*)
  FROM public.order_shipments WHERE status IN ('pending', 'packed', 'dispatched')
  UNION ALL
  SELECT 6, 'cash orders with a back-order whose main delivery is delivered but not yet collected', count(*)
  FROM public.orders o
  WHERE public.order_has_cash_portions(o.id) AND o.status = 'delivered'
    AND NOT EXISTS (SELECT 1 FROM public.order_collections c WHERE c.order_id = o.id AND c.shipment_id IS NULL)
  UNION ALL
  SELECT 7, 'delivered cash back-order shipments whose cash has not been collected', count(*)
  FROM public.order_shipments s JOIN public.orders o ON o.id = s.order_id
  WHERE s.status = 'delivered' AND NOT o.is_credit_order
    AND NOT EXISTS (SELECT 1 FROM public.order_collections c WHERE c.shipment_id = s.id)
) q
ORDER BY ord;
