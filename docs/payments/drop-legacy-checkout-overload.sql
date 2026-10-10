-- Removes a leftover, superseded version of the checkout function that exists only in production:
--   public.create_marketplace_orders(_caller_id uuid, _pharmacy_id uuid, _items jsonb, _request_id uuid)
-- It comes from an early checkout-replay design (it uses the table public.checkout_requests). It was replaced by create_marketplace_orders_once +
-- the six-argument create_marketplace_orders, but no migration ever dropped it. It has no discounts, minimum order value, delivery fee, credit
-- check or purchase classification, always stores payment method 'cod', and cannot be called by signed-in users (service role only). Nothing in the
-- app, the API or any migration calls it.
--
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). Safe to run: it first refuses (changing
-- nothing) if any function other than create_marketplace_orders_once mentions create_marketplace_orders, and it only removes that one version. The table public.checkout_requests and its rows are NOT touched.
-- Its full text is kept in docs/payments/legacy-create-marketplace-orders-4arg.sql in case it is ever wanted back.
DO $$
DECLARE v_users TEXT;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_users
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.oid <> to_regprocedure('public.create_marketplace_orders(uuid,uuid,jsonb,uuid)')
    AND p.proname <> 'create_marketplace_orders_once'
    AND p.prosrc ILIKE '%create_marketplace_orders%';
  IF v_users IS NOT NULL THEN
    RAISE EXCEPTION 'Another function refers to create_marketplace_orders (%), so the leftover version may be in use. Nothing was changed.', v_users;
  END IF;
  IF to_regprocedure('public.create_marketplace_orders(uuid,uuid,jsonb,uuid)') IS NULL THEN
    RAISE NOTICE 'The four-argument version is already gone. Nothing to do.';
    RETURN;
  END IF;
  DROP FUNCTION public.create_marketplace_orders(uuid, uuid, jsonb, uuid);
  RAISE NOTICE 'Dropped create_marketplace_orders(uuid,uuid,jsonb,uuid).';
END $$;

-- Afterwards exactly one version of create_marketplace_orders should remain (the six-argument one):
SELECT p.oid::regprocedure::text AS remaining_versions FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'create_marketplace_orders';
