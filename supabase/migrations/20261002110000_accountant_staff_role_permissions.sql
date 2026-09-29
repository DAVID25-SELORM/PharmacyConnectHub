-- Accountant staff role, part 2: wire it into the base read tier.
--
-- Scope (deliberately narrow, matching the warehouse/finance rollout):
--   - accountant joins the DEFAULT read tier of can_act_for_business only -- the same tier
--     cashier/assistant/warehouse/finance are already in. This is a foundation migration: it
--     does not grant any write capability. Payment recording, credit-limit changes, etc. get
--     their own explicit checks in the RPCs that implement them (not yet built).
--   - accountant does NOT join 'manage' (owner/manager) or 'process' (fulfilment) tiers, matching
--     the brief's "no order creation, no stock changes, no staff/profile management by default".
--   - Most VIEW-level access in this codebase (orders SELECT, reports, statements, credit-terms-
--     adjacent RPCs that use is_business_staff rather than can_act_for_business) is already
--     role-agnostic -- any active staff row passes -- so an accountant automatically gets order
--     visibility, report access and statement access the moment they're invited. No RLS policy
--     changes are needed for that; this migration only widens can_act_for_business itself, for
--     future accountant-specific RPCs that want a narrower-than-"any staff" but broader-than-
--     "process" check (the read tier).
--   - accountant is valid on both pharmacy and wholesaler businesses (see the enum migration's
--     comment) -- enforce_staff_role_business_type is untouched, since it only restricts
--     warehouse/finance to wholesalers and never restricted accountant.

CREATE OR REPLACE FUNCTION public.can_act_for_business(p_business_id UUID, p_level TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR (
      public.is_business_staff(auth.uid(), p_business_id)
      AND public.get_staff_role(auth.uid(), p_business_id)::TEXT = ANY (
        CASE p_level
          WHEN 'manage' THEN ARRAY['owner', 'manager']
          WHEN 'process' THEN ARRAY['owner', 'manager', 'cashier', 'warehouse']
          ELSE ARRAY['owner', 'manager', 'cashier', 'assistant', 'warehouse', 'finance', 'accountant']
        END
      )
    )
$$;
REVOKE ALL ON FUNCTION public.can_act_for_business(UUID, TEXT) FROM PUBLIC, anon, authenticated;
