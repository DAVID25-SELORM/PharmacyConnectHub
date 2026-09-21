-- Service-only SECURITY DEFINER functions were intended to be callable only by the server
-- (service_role), but earlier migrations used `REVOKE ALL ... FROM PUBLIC`. Supabase grants
-- EXECUTE on new public functions directly to anon and authenticated (default privileges), so
-- that REVOKE never removed those grants.
--   * create_marketplace_orders(_caller_id, ...) trusts its _caller_id argument, so any signed-in
--     (or anonymous) API client could place an order in another pharmacy's name. Confirmed on a
--     local stack AND on production, where the 3-argument overload is executable by anon and
--     authenticated (the 4-argument overload with _request_id is already service-only).
--   * write_audit_log() and lookup_user_id_by_email() showed the same weakness on a fresh local
--     stack; production already has them locked down, so revoking here is a no-op there.
-- Server code uses the service-role client for all of these (api/orders/create.ts,
-- api/staff/invite.ts, api/platform-staff/invite.ts). Trigger functions that call
-- write_audit_log() are SECURITY DEFINER and run as the function owner, so they are unaffected.
--
-- Revoke only: no GRANT is issued, so no privilege is widened. service_role keeps whatever
-- access it already has (verified: it can execute create_marketplace_orders).
-- Every overload is covered, so a differently-shaped copy cannot stay exposed.

DO $$
DECLARE fn regprocedure;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('create_marketplace_orders', 'write_audit_log', 'lookup_user_id_by_email')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
  END LOOP;
END $$;
