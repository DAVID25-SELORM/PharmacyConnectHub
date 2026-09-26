-- Delivery details + proof of delivery: permissions, status rules, validation, audit log.
-- Run after setup.sql + migrations (through 20260924150000_order_deliveries.sql).
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

SELECT zz.mkuser('10000000-0000-0000-0000-0000000000a1', 'wa@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000012"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now());

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other'); u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  o_acc UUID; o_disp UUID; o_del UUID; o_pend UUID; o_canc UUID;
  r TEXT;
BEGIN
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'accepted', 1, 1, 0, 'unpaid', 'cod') RETURNING id INTO o_acc;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'dispatched', 1, 1, 0, 'unpaid', 'cod') RETURNING id INTO o_disp;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'delivered', 1, 1, 0, 'paid', 'cod') RETURNING id INTO o_del;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'pending', 1, 1, 0, 'unpaid', 'cod') RETURNING id INTO o_pend;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'cancelled', 1, 1, 0, 'unpaid', 'cod') RETURNING id INTO o_canc;

  UPDATE public.orders SET created_at = now() - interval '5 hours' WHERE id IN (o_disp, o_del);

  -- dispatch details
  r := zz.val_as(u_wc, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', ''+233 24 555 0101'', ''DEL-77'', now() + interval ''1 day'')::text', o_acc));
  PERFORM zz.check('cashier can record dispatch details on an accepted order', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_pend));
  PERFORM zz.check('pending order cannot get dispatch details', r LIKE 'ERR: Delivery details can only%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_del));
  PERFORM zz.check('delivered order cannot get dispatch details', r LIKE 'ERR: Delivery details can only%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_canc));
  PERFORM zz.check('cancelled order cannot get dispatch details', r LIKE 'ERR: Delivery details can only%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, NULL, NULL, NULL, NULL)::text', o_acc));
  PERFORM zz.check('at least one detail is required', r LIKE 'ERR: Enter at least one%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''K'', NULL, NULL, NULL)::text', o_acc));
  PERFORM zz.check('one-character driver name rejected', r LIKE 'ERR: The driver name%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi'', ''call me maybe'', NULL, NULL)::text', o_acc));
  PERFORM zz.check('invalid phone rejected', r LIKE 'ERR: Enter a valid phone%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi'', NULL, NULL, now() - interval ''5 days'')::text', o_acc));
  PERFORM zz.check('expected time before the order rejected', r LIKE 'ERR: The expected delivery time%', r);
  r := zz.val_as(u_wa, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_acc));
  PERFORM zz.check('wholesaler assistant cannot write', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wx, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_acc));
  PERFORM zz.check('another wholesaler cannot write', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_acc));
  PERFORM zz.check('the pharmacy cannot write dispatch details', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Ama Rider'', ''0245550202'', ''DEL-78'', NULL)::text', o_acc));
  PERFORM zz.check('details can be corrected (overwrite)', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT driver_name FROM public.order_deliveries WHERE order_id = %L', o_acc));
  PERFORM zz.check('direct table read is hidden by RLS', r IS NULL, r);

  -- reading
  r := zz.val_as(u_po, format('SELECT public.get_order_delivery(%L)->>''driver_name''', o_acc));
  PERFORM zz.check('the pharmacy can read the driver', r = 'Ama Rider', r);
  r := zz.val_as(u_wo, format('SELECT public.get_order_delivery(%L)->>''delivery_reference''', o_acc));
  PERFORM zz.check('the wholesaler can read the reference', r = 'DEL-78', r);
  r := zz.val_as(u_wa, format('SELECT public.get_order_delivery(%L)->>''driver_name''', o_acc));
  PERFORM zz.check('wholesaler assistant can read', r = 'Ama Rider', r);
  r := zz.val_as(u_px, format('SELECT public.get_order_delivery(%L)::text', o_acc));
  PERFORM zz.check('another pharmacy cannot read', r LIKE 'ERR: You do not have access%', r);
  r := zz.val_as(u_wx, format('SELECT public.get_order_delivery(%L)::text', o_acc));
  PERFORM zz.check('another wholesaler cannot read', r LIKE 'ERR: You do not have access%', r);
  r := zz.val_as(u_nb, format('SELECT public.get_order_delivery(%L)::text', o_acc));
  PERFORM zz.check('unrelated user cannot read', r LIKE 'ERR: You do not have access%', r);
  r := zz.val_as(u_po, format('SELECT public.get_order_delivery(%L)::text', o_pend));
  PERFORM zz.check('an order with no details reads as an empty object', r = '{}', r);

  -- proof of delivery
  r := zz.val_as(u_wo, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', now(), NULL)::text', o_acc));
  PERFORM zz.check('proof of delivery not allowed before dispatch', r LIKE 'ERR: Proof of delivery can only%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_proof_of_delivery(%L, '''', now(), NULL)::text', o_disp));
  PERFORM zz.check('receiver name is required', r LIKE 'ERR: Enter the name%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', NULL, NULL)::text', o_disp));
  PERFORM zz.check('received time is required', r LIKE 'ERR: Enter when%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', now() + interval ''2 days'', NULL)::text', o_disp));
  PERFORM zz.check('received time in the future rejected', r LIKE 'ERR: The received time cannot be in the future%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', now() - interval ''30 days'', NULL)::text', o_disp));
  PERFORM zz.check('received time before the order rejected', r LIKE 'ERR: The received time cannot be before%', r);
  r := zz.val_as(u_wa, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', now(), NULL)::text', o_disp));
  PERFORM zz.check('wholesaler assistant cannot record proof', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', now(), NULL)::text', o_disp));
  PERFORM zz.check('the pharmacy cannot record its own proof of delivery', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wc, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', now() - interval ''1 hour'', ''Left with the pharmacist'')::text', o_disp));
  PERFORM zz.check('cashier can record proof on a dispatched order', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT public.get_order_delivery(%L)->>''received_by_name''', o_disp));
  PERFORM zz.check('the pharmacy sees who received the goods', r = 'John Mensah', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_proof_of_delivery(%L, ''Grace Owusu'', now(), NULL)::text', o_del));
  PERFORM zz.check('proof can be recorded on a delivered order', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi'', NULL, NULL, NULL)::text', o_disp));
  PERFORM zz.check('dispatch details still editable while dispatched', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT public.get_order_delivery(%L)->>''received_by_name''', o_disp));
  PERFORM zz.check('editing dispatch details does not erase proof of delivery', r = 'John Mensah', r);

  PERFORM zz.check('audit log has both activities',
    (SELECT count(DISTINCT activity) FROM public.audit_logs WHERE activity IN ('Delivery details updated', 'Proof of delivery recorded')) = 2);

  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.get_order_delivery(o_acc);
    RESET ROLE;
    PERFORM zz.check('anon cannot read deliveries', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot read deliveries', TRUE, SQLERRM);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
