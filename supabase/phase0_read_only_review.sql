-- DrugXone Phase 0: investigation only. Run as an authorized database reviewer.
-- These SELECTs never repair, delete, grant privileges, or infer proven reservations.
-- Run sections 1-8 BEFORE the corrective migration; section 9 AFTER it.

-- 1. Current application administrators (metadata is an investigative clue, not proof).
SELECT u.id, u.email, u.created_at, ur.created_at AS role_created_at,
  u.raw_user_meta_data->>'role' AS requested_signup_role
FROM auth.users u JOIN public.user_roles ur ON ur.user_id=u.id
WHERE ur.role='admin' ORDER BY ur.created_at;

-- 2. Platform owners/admins and role synchronization anomalies.
SELECT ps.*, u.email, EXISTS(SELECT 1 FROM public.user_roles ur WHERE ur.user_id=ps.user_id AND ur.role='admin') AS has_admin_role
FROM public.platform_staff ps JOIN auth.users u ON u.id=ps.user_id ORDER BY ps.created_at;

-- 3. Approved businesses and available evidence.
SELECT b.id,b.owner_id,b.type,b.name,b.verification_status,b.verified_at,b.created_at,
  (SELECT count(*) FROM public.license_documents d WHERE d.business_id=b.id) AS document_count
FROM public.businesses b WHERE b.verification_status='approved' ORDER BY b.created_at;

-- 4. Suspicious approvals: missing timestamps/documents/audit evidence. Not proof of abuse:
-- old legitimate approvals predate audit logging; historic audit records may be unreliable.
SELECT b.id,b.owner_id,b.name,b.verified_at,b.created_at
FROM public.businesses b WHERE b.verification_status='approved' AND (
  b.verified_at IS NULL OR
  NOT EXISTS(SELECT 1 FROM public.license_documents d WHERE d.business_id=b.id) OR
  NOT EXISTS(SELECT 1 FROM public.audit_logs a WHERE a.record_id=b.id AND a.record_type='business')
);

-- 5. Orders outside canonical checkout assumptions; no historical provenance can be proven from these alone.
SELECT o.id,o.order_number,o.status,o.total_ghs,p.type AS buyer_type,w.type AS seller_type,
  count(i.id) AS item_count,coalesce(sum(i.quantity*i.unit_price_ghs),0) AS calculated_total
FROM public.orders o JOIN public.businesses p ON p.id=o.pharmacy_id
JOIN public.businesses w ON w.id=o.wholesaler_id LEFT JOIN public.order_items i ON i.order_id=o.id
GROUP BY o.id,p.type,w.type
HAVING p.type<>'pharmacy' OR w.type<>'wholesaler' OR count(i.id)=0
 OR o.total_ghs<>coalesce(sum(i.quantity*i.unit_price_ghs),0) OR o.total_ghs<0;

-- 6. Existing relationships/prices/duplicates that would conflict with new-write invariants.
SELECT i.id,i.order_id,i.product_id,o.wholesaler_id AS order_supplier,p.wholesaler_id AS product_supplier,
 i.quantity,i.unit_price_ghs FROM public.order_items i JOIN public.orders o ON o.id=i.order_id
JOIN public.products p ON p.id=i.product_id
WHERE o.wholesaler_id<>p.wholesaler_id OR i.quantity<=0 OR i.unit_price_ghs<0;
SELECT order_id,product_id,count(*) AS duplicate_rows,sum(quantity) AS total_quantity
FROM public.order_items GROUP BY order_id,product_id HAVING count(*)>1;
SELECT p.id,p.wholesaler_id,b.type,b.verification_status FROM public.products p
JOIN public.businesses b ON b.id=p.wholesaler_id WHERE b.type<>'wholesaler';
SELECT w.id,w.wholesaler_id AS offer_supplier,p.wholesaler_id AS legacy_supplier
FROM public.wholesaler_products w JOIN public.products p ON p.id=w.id WHERE w.wholesaler_id<>p.wholesaler_id;

-- 7. Repeated/invalid cancellation history. Histories could previously be forged; investigate rather than auto-correct.
SELECT o.id,o.status,count(*) FILTER(WHERE h.to_status='cancelled') AS cancellations,
 bool_or(h.from_status IN ('cancelled','delivered') AND h.to_status<>h.from_status) AS terminal_state_exit
FROM public.orders o JOIN public.order_status_history h ON h.order_id=o.id
GROUP BY o.id HAVING count(*) FILTER(WHERE h.to_status='cancelled')>1
 OR bool_or(h.from_status IN ('cancelled','delivered') AND h.to_status<>h.from_status);

-- 8. Multi-business memberships and suspicious memberships (may be legitimate).
SELECT bs.user_id,u.email,count(DISTINCT bs.business_id) AS business_count,
 array_agg(DISTINCT bs.business_id) AS business_ids
FROM public.business_staff bs JOIN auth.users u ON u.id=bs.user_id
GROUP BY bs.user_id,u.email HAVING count(DISTINCT bs.business_id)>1;
SELECT bs.*,u.email,b.owner_id,
 (bs.role='owner' AND bs.user_id<>b.owner_id) AS invalid_owner,
 (bs.status='active' AND bs.joined_at IS NULL) AS missing_join_evidence,
 EXISTS(SELECT 1 FROM public.platform_staff ps WHERE ps.user_id=bs.user_id AND ps.status IN ('active','pending')) AS platform_overlap
FROM public.business_staff bs JOIN auth.users u ON u.id=bs.user_id JOIN public.businesses b ON b.id=bs.business_id
WHERE (bs.role='owner' AND bs.user_id<>b.owner_id) OR (bs.status='active' AND bs.joined_at IS NULL)
 OR bs.invited_by IS DISTINCT FROM bs.user_id
 OR EXISTS(SELECT 1 FROM public.platform_staff ps WHERE ps.user_id=bs.user_id AND ps.status IN ('active','pending'));

-- 9. POST-MIGRATION ONLY: legacy orders with no trusted deduction evidence.
-- Do not backfill from order_items automatically: older orders may never have deducted stock.
SELECT o.id,o.order_number,o.status,o.created_at FROM public.orders o
WHERE NOT EXISTS(SELECT 1 FROM public.order_stock_deductions d WHERE d.order_id=o.id)
ORDER BY o.created_at;
SELECT d.order_id,d.product_id,d.quantity,d.restored_at,o.status
FROM public.order_stock_deductions d JOIN public.orders o ON o.id=d.order_id
WHERE (d.restored_at IS NOT NULL) <> (o.status='cancelled');
