-- READ ONLY. Sections 1-4 can run before Phase 1; sections 5-8 require Phase 1.
-- 1. Existing stock conflicts; do not repair automatically.
SELECT id,wholesaler_id,name,stock,updated_at FROM public.products WHERE stock IS NULL OR stock<0;
SELECT conname,pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid='public.products'::regclass AND contype='c';
-- 2. Stock in inappropriate business workspaces (investigation, not proof of abuse).
SELECT p.id,p.name,p.stock,b.type,b.verification_status FROM public.products p
JOIN public.businesses b ON b.id=p.wholesaler_id
WHERE b.type<>'wholesaler' OR (p.active AND b.verification_status<>'approved');
-- 3. Cancelled orders lacking verified deduction evidence.
SELECT o.id,o.created_at,o.cancelled_at FROM public.orders o WHERE o.status='cancelled'
AND NOT EXISTS(SELECT 1 FROM public.order_stock_deductions d WHERE d.order_id=o.id);
-- 4. Similar orders close in time. A candidate pair is not proof of a duplicate.
WITH carts AS (SELECT o.id,o.pharmacy_id,o.wholesaler_id,o.created_at,
  jsonb_agg(jsonb_build_array(i.product_id,i.quantity,i.unit_price_ghs) ORDER BY i.product_id,i.quantity,i.unit_price_ghs) cart
  FROM public.orders o JOIN public.order_items i ON i.order_id=o.id GROUP BY o.id)
SELECT a.id first_order,b.id next_order,a.pharmacy_id,a.created_at,b.created_at
FROM carts a JOIN carts b ON a.pharmacy_id=b.pharmacy_id AND a.wholesaler_id=b.wholesaler_id
AND a.cart=b.cart AND a.id<b.id AND abs(extract(epoch FROM(a.created_at-b.created_at)))<=300;
-- 5. Opening balance plus all movements must match the current balance.
SELECT p.id,p.stock,b.quantity opening_quantity,coalesce(sum(m.quantity_delta),0) movement_delta
FROM public.products p LEFT JOIN public.inventory_opening_balances b ON b.product_id=p.id
LEFT JOIN public.inventory_movements m ON m.product_id=p.id
GROUP BY p.id,b.quantity HAVING b.quantity IS NULL OR p.stock<>b.quantity+coalesce(sum(m.quantity_delta),0);
-- 6. Orders/evidence without movement records: legacy operations must remain distinguishable.
SELECT o.id,o.created_at,d.product_id,d.quantity,d.restored_at
FROM public.orders o LEFT JOIN public.order_stock_deductions d ON d.order_id=o.id
WHERE NOT EXISTS(SELECT 1 FROM public.inventory_movements m WHERE m.order_id=o.id AND m.movement_type='checkout_deduction');
SELECT d.* FROM public.order_stock_deductions d WHERE d.restored_at IS NOT NULL
AND NOT EXISTS(SELECT 1 FROM public.inventory_movements m WHERE m.order_id=d.order_id AND m.product_id=d.product_id
  AND m.movement_type='order_cancellation_restore');
-- 7. Unattributed maintenance, large values for review (no arbitrary anomaly cutoff).
SELECT * FROM public.inventory_movements WHERE actor_id IS NULL OR source_operation='database_maintenance' ORDER BY created_at DESC;
SELECT id,wholesaler_id,name,stock,updated_at FROM public.products ORDER BY stock DESC LIMIT 100;
-- 8. Manual stock operations near checkout. Historical updated_at is only the last edit,
-- so it cannot prove an earlier metadata edit or identify its actor.
SELECT a.product_id,a.id manual_movement,b.order_id,a.created_at,b.created_at
FROM public.inventory_movements a JOIN public.inventory_movements b ON a.product_id=b.product_id
WHERE a.movement_type IN ('manual_add','manual_remove','manual_reconciliation')
AND b.movement_type='checkout_deduction' AND abs(extract(epoch FROM(a.created_at-b.created_at)))<=300;
SELECT p.id,p.updated_at,o.id order_id,o.created_at FROM public.products p
JOIN public.order_items i ON i.product_id=p.id JOIN public.orders o ON o.id=i.order_id
WHERE abs(extract(epoch FROM(p.updated_at-o.created_at)))<=300;
