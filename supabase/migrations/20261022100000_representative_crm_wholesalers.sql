-- The same private representative CRM is available to verified pharmacies and wholesalers.
CREATE OR REPLACE FUNCTION public.can_manage_pharmacy_crm(p_pharmacy_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = p_pharmacy_id
        AND b.type::text IN ('pharmacy', 'wholesaler')
        AND b.verification_status = 'approved'
    )
    AND public.can_act_for_business(p_pharmacy_id, 'manage')
$$;

COMMENT ON FUNCTION public.can_manage_pharmacy_crm(UUID)
IS 'Allows verified pharmacy or wholesaler owners and managers to manage private representative CRM records.';
