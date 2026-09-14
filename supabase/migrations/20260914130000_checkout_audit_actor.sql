-- Forward correction: attribute generic checkout audit events using the already validated
-- service-only checkout caller. No new caller-controlled RPC parameters or grants.
BEGIN;
DO $migration$
DECLARE definition TEXT; marker TEXT := '    INSERT INTO public.orders (';
BEGIN
  SELECT pg_get_functiondef('public.create_marketplace_orders(uuid,uuid,jsonb,uuid)'::regprocedure) INTO definition;
  IF position(marker IN definition)=0 OR position('    RETURNING id INTO v_order_id;' IN definition)=0 THEN
    RAISE EXCEPTION 'Unexpected checkout definition; review before applying audit correction.';
  END IF;
  definition := replace(definition, marker,
    '    INSERT INTO public.server_audit_context(transaction_id,actor_id) VALUES(txid_current(),_caller_id);' || chr(10) || marker);
  definition := replace(definition, '    RETURNING id INTO v_order_id;',
    '    RETURNING id INTO v_order_id;' || chr(10) || '    DELETE FROM public.server_audit_context WHERE transaction_id=txid_current();');
  EXECUTE definition;
END $migration$;
COMMIT;
