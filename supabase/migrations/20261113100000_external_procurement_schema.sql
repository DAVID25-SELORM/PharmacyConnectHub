-- External procurement is a pharmacy-private record, never a marketplace seller/order.
-- Additive: existing stock and historical orders are not reclassified or rewritten.
CREATE TABLE public.external_procurement_settings (
  pharmacy_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE RESTRICT,
  collect_identity BOOLEAN NOT NULL DEFAULT false
);
CREATE TABLE public.external_procurement_reviewers (
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  assigned_by UUID NOT NULL REFERENCES auth.users(id), assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY(pharmacy_id,user_id)
);
CREATE FUNCTION public.can_review_external_purchase(p_pharmacy_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.businesses b
 WHERE b.id=p_pharmacy_id AND b.type='pharmacy' AND b.verification_status='approved'
 AND (b.owner_id=auth.uid() OR public.is_business_staff(auth.uid(),b.id)))
 AND EXISTS(SELECT 1 FROM public.external_procurement_reviewers r WHERE r.pharmacy_id=p_pharmacy_id AND r.user_id=auth.uid())
$$;
CREATE FUNCTION public.can_access_external_procurement(p_pharmacy_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.businesses b
 WHERE b.id=p_pharmacy_id AND b.type='pharmacy' AND b.verification_status='approved')
 AND (public.can_act_for_business(p_pharmacy_id,'process') OR public.can_view_accounting(p_pharmacy_id)
 OR public.can_review_external_purchase(p_pharmacy_id))
$$;

-- Existing contacts remain private CRM records. No user/account/business is created.
ALTER TABLE public.pharmacy_crm_representatives ADD COLUMN alternate_phone TEXT,
 ADD COLUMN location TEXT, ADD COLUMN identity_type TEXT, ADD COLUMN identity_reference TEXT;
ALTER TABLE public.pharmacy_crm_companies ADD COLUMN phone TEXT, ADD COLUMN location TEXT,
 ADD COLUMN license_reference TEXT;

CREATE TABLE public.external_purchases (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
 reference TEXT NOT NULL DEFAULT ('EXT-' || upper(replace(gen_random_uuid()::text,'-',''))),
 purchase_date DATE NOT NULL, channel TEXT NOT NULL CHECK(channel IN ('external_licensed','intermediary','unknown')),
 seller_contact_id UUID, seller_company_id UUID, source_company_id UUID,
 seller_snapshot JSONB NOT NULL DEFAULT '{}', source_snapshot JSONB NOT NULL DEFAULT '{}',
 source_type TEXT NOT NULL CHECK(source_type IN ('platform_wholesaler','external_wholesaler','pharmacy','manufacturer','health_facility','other','unknown')),
 source_wholesaler_id UUID REFERENCES public.businesses(id),
 invoice_number TEXT, receipt_number TEXT, notes TEXT,
 total_ghs NUMERIC(14,2) NOT NULL CHECK(total_ghs>=0 AND total_ghs<1000000000000),
 payment_method TEXT NOT NULL DEFAULT 'cash' CHECK(payment_method IN ('cash','bank_transfer','mobile_money','cheque','other')),
 due_date DATE,
 review_status TEXT NOT NULL DEFAULT 'draft' CHECK(review_status IN ('draft','awaiting_review','needs_information','approved','quarantined','rejected')),
 verification_status TEXT NOT NULL DEFAULT 'unverified' CHECK(verification_status IN ('verified','partially_verified','unverified','rejected','quarantined')),
 reviewed_by UUID REFERENCES auth.users(id), reviewed_at TIMESTAMPTZ, review_notes TEXT,
 posted_at TIMESTAMPTZ, received_by UUID NOT NULL REFERENCES auth.users(id), created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), version INTEGER NOT NULL DEFAULT 1,
 request_id UUID NOT NULL, request_hash TEXT NOT NULL,
 UNIQUE(pharmacy_id,id), UNIQUE(pharmacy_id,reference), UNIQUE(pharmacy_id,request_id),
 FOREIGN KEY(pharmacy_id,seller_contact_id) REFERENCES public.pharmacy_crm_representatives(pharmacy_id,id),
 FOREIGN KEY(pharmacy_id,seller_company_id) REFERENCES public.pharmacy_crm_companies(pharmacy_id,id),
 FOREIGN KEY(pharmacy_id,source_company_id) REFERENCES public.pharmacy_crm_companies(pharmacy_id,id),
 CHECK(channel<>'intermediary' OR seller_contact_id IS NOT NULL),
 CHECK(channel<>'external_licensed' OR seller_company_id IS NOT NULL),
 CHECK(source_type<>'platform_wholesaler' OR source_wholesaler_id IS NOT NULL),
 CHECK(source_type='unknown' OR NULLIF(btrim(source_snapshot->>'name'),'') IS NOT NULL)
);
CREATE INDEX external_purchase_date ON public.external_purchases(pharmacy_id,purchase_date DESC,id);
ALTER TABLE public.pharmacy_inventory_items ADD CONSTRAINT pharmacy_inventory_tenant_id UNIQUE(pharmacy_id,id);
CREATE TABLE public.external_purchase_items (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL, purchase_id UUID NOT NULL,
 master_product_id UUID REFERENCES public.master_products(id), inventory_item_id UUID,
 product_snapshot JSONB NOT NULL, quantity INTEGER NOT NULL CHECK(quantity>0),
 unit_cost_ghs NUMERIC(12,2) NOT NULL CHECK(unit_cost_ghs>=0 AND unit_cost_ghs<10000000000),
 UNIQUE(pharmacy_id,id), FOREIGN KEY(pharmacy_id,purchase_id) REFERENCES public.external_purchases(pharmacy_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(pharmacy_id,inventory_item_id) REFERENCES public.pharmacy_inventory_items(pharmacy_id,id) ON DELETE RESTRICT
);
CREATE INDEX external_items_purchase ON public.external_purchase_items(purchase_id);
CREATE TABLE public.external_purchase_batches (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL, item_id UUID NOT NULL,
 batch_number TEXT, expiry_date DATE, quantity INTEGER NOT NULL CHECK(quantity>0),
 remaining INTEGER NOT NULL CHECK(remaining>=0), returned INTEGER NOT NULL DEFAULT 0 CHECK(returned>=0),
 disposition TEXT NOT NULL DEFAULT 'quarantine' CHECK(disposition IN ('quarantine','saleable','rejected')),
 UNIQUE(pharmacy_id,id), CHECK(remaining+returned<=quantity),
 FOREIGN KEY(pharmacy_id,item_id) REFERENCES public.external_purchase_items(pharmacy_id,id) ON DELETE RESTRICT
);
CREATE INDEX external_batches_item ON public.external_purchase_batches(item_id);
CREATE TABLE public.external_purchase_documents (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL, purchase_id UUID NOT NULL,
 document_type TEXT NOT NULL CHECK(document_type IN ('supplier_invoice','receipt','delivery_note','product_invoice','purchase_receipt','other')),
 storage_path TEXT NOT NULL UNIQUE, filename TEXT NOT NULL,
 uploaded_by UUID NOT NULL REFERENCES auth.users(id), uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now(), removed_at TIMESTAMPTZ,
 FOREIGN KEY(pharmacy_id,purchase_id) REFERENCES public.external_purchases(pharmacy_id,id) ON DELETE RESTRICT
);
CREATE INDEX external_documents_purchase ON public.external_purchase_documents(purchase_id);
CREATE TABLE public.external_purchase_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL, purchase_id UUID,
 action TEXT NOT NULL, actor_id UUID NOT NULL REFERENCES auth.users(id), occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 details JSONB NOT NULL DEFAULT '{}', FOREIGN KEY(pharmacy_id,purchase_id) REFERENCES public.external_purchases(pharmacy_id,id)
);
CREATE INDEX external_events_purchase ON public.external_purchase_events(pharmacy_id,purchase_id,occurred_at);
-- Finance is separate from source verification. Append-only payments and signed corrections.
CREATE TABLE public.external_purchase_payments (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL, purchase_id UUID NOT NULL,
 amount_ghs NUMERIC(14,2) NOT NULL CHECK(amount_ghs<>0 AND abs(amount_ghs)<1000000000000),
 method TEXT NOT NULL CHECK(method IN ('cash','bank_transfer','mobile_money','cheque','other')),
 reference TEXT, paid_at DATE NOT NULL, recorded_by UUID NOT NULL REFERENCES auth.users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), request_id UUID NOT NULL, reverses_id UUID UNIQUE REFERENCES public.external_purchase_payments(id),
 UNIQUE(pharmacy_id,request_id), FOREIGN KEY(pharmacy_id,purchase_id) REFERENCES public.external_purchases(pharmacy_id,id),
 CHECK((amount_ghs<0)=(reverses_id IS NOT NULL))
);
CREATE TABLE public.external_purchase_returns (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL, batch_id UUID NOT NULL,
 quantity INTEGER NOT NULL CHECK(quantity>0), reason TEXT NOT NULL CHECK(length(btrim(reason))>0),
 returned_to TEXT NOT NULL, returned_at DATE NOT NULL, processed_by UUID NOT NULL REFERENCES auth.users(id),
 kind TEXT NOT NULL CHECK(kind IN ('return','correction','write_off')),
 credit_ghs NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK(credit_ghs>=0 AND credit_ghs<1000000000000),
 request_id UUID NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(pharmacy_id,request_id), FOREIGN KEY(pharmacy_id,batch_id) REFERENCES public.external_purchase_batches(pharmacy_id,id)
);
ALTER TABLE public.pharmacy_inventory_movements ADD COLUMN external_batch_id UUID REFERENCES public.external_purchase_batches(id),
 ADD COLUMN external_return_id UUID UNIQUE REFERENCES public.external_purchase_returns(id);
CREATE UNIQUE INDEX external_batch_receive_once ON public.pharmacy_inventory_movements(external_batch_id)
 WHERE external_batch_id IS NOT NULL AND kind='receive';

DO $$ DECLARE t TEXT; BEGIN
 FOREACH t IN ARRAY ARRAY['external_procurement_settings','external_procurement_reviewers','external_purchases',
 'external_purchase_items','external_purchase_batches','external_purchase_documents','external_purchase_events',
 'external_purchase_payments','external_purchase_returns'] LOOP
 EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
 EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
 EXECUTE format('CREATE POLICY tenant_read ON public.%I FOR SELECT TO authenticated USING(public.can_access_external_procurement(pharmacy_id))',t);
 END LOOP;
END $$;
-- Detailed payment receipts remain finance-only (purchase balances are operational).
DROP POLICY tenant_read ON public.external_purchase_payments;
CREATE POLICY finance_read ON public.external_purchase_payments FOR SELECT TO authenticated
 USING(public.can_access_external_procurement(pharmacy_id) AND public.can_view_accounting(pharmacy_id));

INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 VALUES('external-procurement','external-procurement',false,10485760,ARRAY['application/pdf','image/jpeg','image/png','image/webp']);
CREATE FUNCTION public.can_access_external_document(p_path TEXT,p_write BOOLEAN DEFAULT false)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.external_purchases p
 WHERE p.pharmacy_id::text=split_part(p_path,'/',1) AND p.id::text=split_part(p_path,'/',2)
 AND public.can_access_external_procurement(p.pharmacy_id)
 AND (NOT p_write OR (public.can_act_for_business(p.pharmacy_id,'process') AND p.posted_at IS NULL AND p.review_status<>'rejected')))
$$;
CREATE POLICY external_document_read ON storage.objects FOR SELECT TO authenticated
 USING(bucket_id='external-procurement' AND public.can_access_external_document(name));
CREATE POLICY external_document_upload ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(bucket_id='external-procurement' AND public.can_access_external_document(name,true));
-- No overwrite/delete policy: evidence is immutable; removal is a logged metadata operation.
REVOKE ALL ON FUNCTION public.can_review_external_purchase(UUID), public.can_access_external_procurement(UUID), public.can_access_external_document(TEXT,BOOLEAN) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_review_external_purchase(UUID), public.can_access_external_procurement(UUID), public.can_access_external_document(TEXT,BOOLEAN) TO authenticated;
