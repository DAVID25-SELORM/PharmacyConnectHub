-- Additive, tenant-scoped presentation settings for commercial documents.
-- Legal and verified identity remains on businesses; these settings cannot replace it.
BEGIN;
CREATE TABLE IF NOT EXISTS public.business_document_branding (
  business_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  display_name TEXT NULL CHECK (display_name IS NULL OR char_length(btrim(display_name)) BETWEEN 1 AND 160),
  logo_path TEXT NULL CHECK (logo_path IS NULL OR logo_path !~ '[[:cntrl:]]'),
  accent_color TEXT NOT NULL DEFAULT '#0f766e' CHECK (accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  show_license BOOLEAN NOT NULL DEFAULT true,
  show_secondary_contact BOOLEAN NOT NULL DEFAULT true,
  footer_note TEXT NULL CHECK (footer_note IS NULL OR char_length(footer_note) <= 500),
  signatory_name TEXT NULL CHECK (signatory_name IS NULL OR char_length(signatory_name) <= 160),
  signatory_title TEXT NULL CHECK (signatory_title IS NULL OR char_length(signatory_title) <= 160),
  payment_instructions TEXT NULL CHECK (payment_instructions IS NULL OR char_length(payment_instructions) <= 1000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.business_document_branding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.business_document_branding FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.business_document_branding TO authenticated;

-- Policies execute as the caller. Keep the general internal authorization helper
-- private and expose only this narrowly scoped, read-only predicate.
CREATE FUNCTION public.can_read_business_document_branding(p_business_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT auth.uid() IS NOT NULL AND (
    public.can_act_for_business(p_business_id, 'read') OR EXISTS (
      SELECT 1 FROM public.orders o
      WHERE (o.wholesaler_id=p_business_id OR o.pharmacy_id=p_business_id)
      AND (public.can_act_for_business(o.wholesaler_id,'read') OR public.can_act_for_business(o.pharmacy_id,'read'))
    )
  );
$$;
REVOKE ALL ON FUNCTION public.can_read_business_document_branding(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_read_business_document_branding(UUID) TO authenticated;

CREATE POLICY "Authorized parties read document branding"
  ON public.business_document_branding FOR SELECT TO authenticated
  USING (
    public.can_read_business_document_branding(business_id)
  );

DROP TRIGGER IF EXISTS trg_business_document_branding_updated ON public.business_document_branding;
CREATE TRIGGER trg_business_document_branding_updated
  BEFORE UPDATE ON public.business_document_branding
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Logos are intentionally limited to inert image formats.  The public object contains only a
-- business mark; ownership and replacement remain restricted to that business's managers.
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES ('business-document-logos','business-document-logos',true,2097152,ARRAY['image/png','image/jpeg','image/webp'])
ON CONFLICT(id) DO UPDATE SET public=true,file_size_limit=2097152,allowed_mime_types=ARRAY['image/png','image/jpeg','image/webp'];

CREATE OR REPLACE FUNCTION public.business_document_logo_write_access(p_name TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE bid UUID;
BEGIN
  IF array_length(string_to_array(p_name, '/'), 1) <> 2 THEN RETURN false; END IF;
  BEGIN bid := split_part(p_name, '/', 1)::UUID; EXCEPTION WHEN invalid_text_representation THEN RETURN false; END;
  RETURN public.can_act_for_business(bid, 'manage');
END $$;
REVOKE ALL ON FUNCTION public.business_document_logo_write_access(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.business_document_logo_write_access(TEXT) TO authenticated;

CREATE POLICY "Business managers upload document logos" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id='business-document-logos' AND public.business_document_logo_write_access(name));
CREATE POLICY "Business managers replace document logos" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id='business-document-logos' AND public.business_document_logo_write_access(name))
  WITH CHECK (bucket_id='business-document-logos' AND public.business_document_logo_write_access(name));
CREATE POLICY "Business managers remove document logos" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id='business-document-logos' AND public.business_document_logo_write_access(name));

-- Server-side guard: the caller can only write its own managed business and no arbitrary markup.
CREATE OR REPLACE FUNCTION public.save_business_document_branding(
  p_business_id UUID,
  p_display_name TEXT DEFAULT NULL,
  p_logo_path TEXT DEFAULT NULL,
  p_accent_color TEXT DEFAULT '#0f766e',
  p_show_license BOOLEAN DEFAULT true,
  p_show_secondary_contact BOOLEAN DEFAULT true,
  p_footer_note TEXT DEFAULT NULL,
  p_signatory_name TEXT DEFAULT NULL,
  p_signatory_title TEXT DEFAULT NULL,
  p_payment_instructions TEXT DEFAULT NULL
) RETURNS public.business_document_branding
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE result public.business_document_branding;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_business_id, 'manage') THEN
    RAISE EXCEPTION 'Business manager permission is required.';
  END IF;
  IF p_accent_color IS NULL OR p_accent_color !~ '^#[0-9A-Fa-f]{6}$' THEN RAISE EXCEPTION 'Accent color must be a six-digit hex color.'; END IF;
  p_logo_path := NULLIF(btrim(p_logo_path), '');
  IF p_logo_path IS NOT NULL AND (p_logo_path ~ '[[:cntrl:]]' OR p_logo_path LIKE '/%' OR p_logo_path LIKE '%..%') THEN
    RAISE EXCEPTION 'Invalid logo path.';
  END IF;
  IF p_logo_path IS NOT NULL AND (
    split_part(p_logo_path,'/',1) <> p_business_id::text
    OR NOT public.business_document_logo_write_access(p_logo_path)
    OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='business-document-logos' AND name=p_logo_path)
  ) THEN RAISE EXCEPTION 'Upload a logo owned by this business first.'; END IF;
  INSERT INTO public.business_document_branding(
    business_id, display_name, logo_path, accent_color, show_license, show_secondary_contact,
    footer_note, signatory_name, signatory_title, payment_instructions
  ) VALUES (
    p_business_id, NULLIF(btrim(p_display_name), ''), NULLIF(btrim(p_logo_path), ''), p_accent_color,
    COALESCE(p_show_license, true), COALESCE(p_show_secondary_contact, true), NULLIF(btrim(p_footer_note), ''),
    NULLIF(btrim(p_signatory_name), ''), NULLIF(btrim(p_signatory_title), ''), NULLIF(btrim(p_payment_instructions), '')
  ) ON CONFLICT (business_id) DO UPDATE SET
    display_name = EXCLUDED.display_name, logo_path = EXCLUDED.logo_path, accent_color = EXCLUDED.accent_color,
    show_license = EXCLUDED.show_license, show_secondary_contact = EXCLUDED.show_secondary_contact,
    footer_note = EXCLUDED.footer_note, signatory_name = EXCLUDED.signatory_name,
    signatory_title = EXCLUDED.signatory_title, payment_instructions = EXCLUDED.payment_instructions
  RETURNING * INTO result;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.save_business_document_branding(UUID,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_business_document_branding(UUID,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,TEXT,TEXT,TEXT,TEXT) TO authenticated;
COMMIT;
