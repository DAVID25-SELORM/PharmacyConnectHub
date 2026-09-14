-- Investigation only. Run sections separately: preflight works before Phase 2; postflight requires it.
-- PRE-FLIGHT: platform authority, conflicts, and a protected active owner.
SELECT p.*,u.email FROM public.platform_staff p LEFT JOIN auth.users u ON u.id=p.user_id;
SELECT u.user_id,u.role,p.role platform_role,p.status FROM public.user_roles u
LEFT JOIN public.platform_staff p ON p.user_id=u.user_id WHERE u.role='admin';
SELECT p.user_id,p.role,p.status,b.id business_id,s.id tenant_membership
FROM public.platform_staff p LEFT JOIN public.businesses b ON b.owner_id=p.user_id
LEFT JOIN public.business_staff s ON s.user_id=p.user_id AND s.status IN ('active','pending')
WHERE b.id IS NOT NULL OR s.id IS NOT NULL;
SELECT count(*) active_owners FROM public.platform_staff WHERE role='owner' AND status='active';
-- Missing objects, and objects never attached to current metadata (some are retained versions).
SELECT d.* FROM public.license_documents d WHERE NOT EXISTS
(SELECT 1 FROM storage.objects o WHERE o.bucket_id='licenses' AND o.name=d.storage_path);
-- Conservative prospective identity conflicts; works before changing normalization.
SELECT wholesaler_id,lower(regexp_replace(btrim(name),'\s+',' ','g')) name,
 lower(regexp_replace(btrim(coalesce(brand,'')),'\s+',' ','g')) brand,
 lower(regexp_replace(btrim(coalesce(form,'')),'\s+',' ','g')) form,
 lower(regexp_replace(btrim(coalesce(pack_size,'')),'\s+',' ','g')) pack_size,
 array_agg(id) ids,count(*) FROM public.products GROUP BY 1,2,3,4,5 HAVING count(*)>1;
SELECT p.id,p.wholesaler_id product_seller,w.wholesaler_id offer_seller FROM public.products p
JOIN public.wholesaler_products w ON w.id=p.id WHERE p.wholesaler_id<>w.wholesaler_id;
SELECT i.id,i.order_id,i.product_id FROM public.order_items i LEFT JOIN public.products p ON p.id=i.product_id
LEFT JOIN public.orders o ON o.id=i.order_id WHERE p.id IS NULL OR o.id IS NULL OR p.wholesaler_id<>o.wholesaler_id;
SELECT id,payment_status,status,paid_at,payment_confirmed_at,payment_confirmed_by,receipt_sent_at
FROM public.orders WHERE (payment_status='paid' AND (paid_at IS NULL OR status<>'delivered'))
OR (receipt_sent_at IS NOT NULL AND payment_status<>'paid');
-- Seed candidates are not proof of seeded data; compare names/UUIDs against excluded source files and backups.
SELECT id,name,wholesaler_id,created_at,stock,price_ghs FROM public.products
WHERE created_at::date BETWEEN DATE '2026-04-19' AND DATE '2026-04-22';
-- Effective policies/grants, including PUBLIC grants. Review against the migration allowlist.
SELECT schemaname,tablename,policyname,roles,cmd,qual,with_check FROM pg_policies
WHERE schemaname IN ('public','storage') ORDER BY 1,2,3;
SELECT p.oid::regprocedure function,r.rolname,
 has_function_privilege(r.oid,p.oid,'EXECUTE') can_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
CROSS JOIN pg_roles r WHERE n.nspname='public' AND p.prosecdef
AND r.rolname IN ('anon','authenticated','service_role') ORDER BY 1,2;
-- POST-FLIGHT: evidence reviewed vs currently approved business.
SELECT b.id,d.id document_id,d.version_id,d.review_status,d.reviewed_at,d.reviewed_by
FROM public.businesses b JOIN public.license_documents d ON d.business_id=b.id
WHERE b.verification_status='approved' AND (d.review_status<>'approved' OR d.reviewed_at IS NULL OR d.reviewed_by IS NULL);
SELECT o.id,o.name,o.created_at FROM storage.objects o WHERE o.bucket_id='licenses'
AND NOT EXISTS(SELECT 1 FROM public.license_documents d WHERE d.storage_path=o.name)
AND NOT EXISTS(SELECT 1 FROM public.license_document_versions v WHERE v.storage_path=o.name);
SELECT w.id,m.id master_id FROM public.wholesaler_products w JOIN public.products p ON p.id=w.id
JOIN public.master_products m ON m.id=w.product_id
WHERE public.product_import_identity(p.name,p.brand,p.form,p.pack_size)
<>public.product_import_identity(m.name,m.brand_name,m.dosage_form,m.pack_size);
SELECT * FROM public.receipt_outbox WHERE status IN ('failed','uncertain') OR (status='sending' AND lease_until<now());
SELECT provider_id,count(*),array_agg(order_id) FROM public.receipt_outbox
WHERE provider_id IS NOT NULL GROUP BY provider_id HAVING count(*)>1;
SELECT record_id,count(*) FROM public.audit_logs WHERE activity='Receipt sent'
GROUP BY record_id HAVING count(*)>1;
-- Deleted historical duplicates cannot be reconstructed from live tables: review backups and migration logs.
-- Also run phase0_read_only_review.sql and phase1_read_only_review.sql; no automated repair is authorized.
