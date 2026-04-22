-- Allow business owners to replace onboarding documents cleanly and keep
-- exactly one row per business/document type.

WITH ranked_docs AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY business_id, doc_type
      ORDER BY uploaded_at DESC, id DESC
    ) AS row_rank
  FROM public.license_documents
)
DELETE FROM public.license_documents AS d
USING ranked_docs
WHERE d.id = ranked_docs.id
  AND ranked_docs.row_rank > 1;

CREATE UNIQUE INDEX IF NOT EXISTS license_documents_business_doc_type_uniq
  ON public.license_documents (business_id, doc_type);

DROP POLICY IF EXISTS "Owners update own docs" ON public.license_documents;
CREATE POLICY "Owners update own docs"
  ON public.license_documents
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses AS b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses AS b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Users delete own license docs" ON storage.objects;
CREATE POLICY "Users delete own license docs"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'licenses'
    AND auth.uid()::TEXT = (storage.foldername(name))[1]
  );
