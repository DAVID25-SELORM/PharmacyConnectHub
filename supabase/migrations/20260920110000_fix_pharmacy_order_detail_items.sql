-- Return pharmacy order items from the authorized detail RPC. The explicit
-- ownership/staff check remains the authorization boundary; SECURITY DEFINER
-- prevents nested order_items RLS from incorrectly hiding the rows.
CREATE OR REPLACE FUNCTION public.get_pharmacy_order_detail(p_order_id UUID)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'order', to_jsonb(o) || jsonb_build_object(
      'wholesaler', jsonb_build_object('name', w.name, 'city', w.city, 'region', w.region),
      'items', COALESCE((
        SELECT jsonb_agg(to_jsonb(oi) ORDER BY oi.id)
        FROM public.order_items oi
        WHERE oi.order_id = o.id
      ), '[]'::JSONB)
    )
  )
  FROM public.orders o
  JOIN public.businesses w ON w.id = o.wholesaler_id
  WHERE o.id = p_order_id
    AND EXISTS (
      SELECT 1 FROM public.businesses pb
      WHERE pb.id = o.pharmacy_id
        AND (
          pb.owner_id = auth.uid()
          OR public.is_business_staff(auth.uid(), pb.id)
        )
        AND pb.type = 'pharmacy'
    );
$$;

REVOKE ALL ON FUNCTION public.get_pharmacy_order_detail(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_pharmacy_order_detail(UUID) TO authenticated;
