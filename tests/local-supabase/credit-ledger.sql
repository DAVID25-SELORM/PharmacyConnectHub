-- Credit ledger (phase 2 of the procurement/credit/RFQ expansion): invoice auto-creation at
-- checkout, granular payments (partial, multi-invoice, multi-payment), adjustments/credit notes,
-- write-offs, reversals, disputes, the legacy-confirm-payment mirror trigger, permission gating,
-- and cross-tenant isolation.
-- Run after setup.sql + migrations through 20261003110000_credit_ledger_logic.sql.
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

-- Finance + accountant + cashier staff on Alpha, to exercise the payment-recording permission gate.
SELECT zz.mkuser('10000000-0000-0000-0000-0000000000d1', 'wfin2@zz.test', '{"full_name":"Alpha Finance 2","phone":"+233241000017"}');
SELECT zz.mkuser('10000000-0000-0000-0000-0000000000d2', 'wacc2@zz.test', '{"full_name":"Alpha Accountant 2","phone":"+233241000018"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000d1', 'finance', 'active', now()),
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000d2', 'accountant', 'active', now());

-- Approve a credit line: Good Pharmacy <-> Alpha Wholesale, GHS 1,000 limit, 30-day terms.
-- set_credit_terms checks auth.uid() itself, so it must run impersonated (zz.run_as, from
-- setup.sql), not as the bare postgres superuser -- a plain top-level call would see auth.uid()
-- IS NULL and be rejected before ever reaching the permission check it's meant to exercise.
SELECT zz.run_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  'SELECT public.set_credit_terms(%L, %L, 1000, 30, ''test line'')',
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.b WHERE name='Good Pharmacy')));

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_wh UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_fin UUID := '10000000-0000-0000-0000-0000000000d1';
  u_acc UUID := '10000000-0000-0000-0000-0000000000d2';
  o1 UUID; o2 UUID; o3 UUID; o4 UUID;
  r TEXT;
  v_entry_id UUID;
  v_payment_id UUID;
BEGIN
  -- Four direct credit orders (bypassing checkout for fixture speed; order 1 below is placed
  -- through the real checkout RPC to prove the automatic invoice-entry hook).
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 200, 200, 0, 'unpaid', 'cod', TRUE, current_date + 30) RETURNING id INTO o1;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o1, 'invoice', 'debit', 200, u_wo);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 150, 150, 0, 'unpaid', 'cod', TRUE, current_date + 30) RETURNING id INTO o2;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o2, 'invoice', 'debit', 150, u_wo);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 80, 80, 0, 'unpaid', 'cod', TRUE, current_date - 5) RETURNING id INTO o3; -- overdue
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o3, 'invoice', 'debit', 80, u_wo);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 60, 60, 0, 'unpaid', 'cod', TRUE, current_date) RETURNING id INTO o4; -- due today
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o4, 'invoice', 'debit', 60, u_wo);

  ------------------------------------------------------------------
  -- 1. credit_invoice_status: not_due / overdue / due_today, freshly-invoiced.
  ------------------------------------------------------------------
  PERFORM zz.check('o1 status is not_due', (SELECT status FROM public.credit_invoice_status(o1)) = 'not_due');
  PERFORM zz.check('o1 outstanding = invoice amount', (SELECT outstanding_ghs FROM public.credit_invoice_status(o1)) = 200);
  PERFORM zz.check('o3 (past due date) status is overdue', (SELECT status FROM public.credit_invoice_status(o3)) = 'overdue');
  PERFORM zz.check('o4 (due date = today) status is due_today', (SELECT status FROM public.credit_invoice_status(o4)) = 'due_today');

  ------------------------------------------------------------------
  -- 2. Permission gate on record_credit_payment: owner/manager/finance/accountant yes, cashier no.
  ------------------------------------------------------------------
  r := zz.val_as(u_wc, format(
    'SELECT public.record_credit_payment(%L, %L, 50, ''cash'', NULL, NULL, NULL, NULL, ''[]''::jsonb)::text', alpha, good));
  PERFORM zz.check('cashier cannot record a credit payment', r LIKE 'ERR: You do not have permission to record payments%', r);

  r := zz.val_as(u_fin, format(
    'SELECT public.record_credit_payment(%L, %L, 200, ''bank_transfer'', ''REF-1'', NULL, NULL, NULL, %L::jsonb)::text',
    alpha, good, jsonb_build_array(jsonb_build_object('order_id', o1, 'amount', 200))::text));
  PERFORM zz.check('finance can record a credit payment', r NOT LIKE 'ERR%', r);

  ------------------------------------------------------------------
  -- 3. Full payment settles the invoice and flips payment_status.
  ------------------------------------------------------------------
  PERFORM zz.check('o1 fully paid: outstanding = 0', (SELECT outstanding_ghs FROM public.credit_invoice_status(o1)) = 0);
  PERFORM zz.check('o1 fully paid: status = paid', (SELECT status FROM public.credit_invoice_status(o1)) = 'paid');
  PERFORM zz.check('o1 orders.payment_status flipped to paid', (SELECT payment_status::text FROM public.orders WHERE id = o1) = 'paid');

  ------------------------------------------------------------------
  -- 4. Partial payment: outstanding drops but stays unpaid/partially_paid.
  ------------------------------------------------------------------
  r := zz.val_as(u_acc, format(
    'SELECT public.record_credit_payment(%L, %L, 100, ''mobile_money'', ''MM-1'', NULL, NULL, NULL, %L::jsonb)::text',
    alpha, good, jsonb_build_array(jsonb_build_object('order_id', o2, 'amount', 100))::text));
  PERFORM zz.check('accountant can record a partial credit payment', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('o2 partial payment: outstanding = 50', (SELECT outstanding_ghs FROM public.credit_invoice_status(o2)) = 50);
  PERFORM zz.check('o2 partial payment: status = partially_paid', (SELECT status FROM public.credit_invoice_status(o2)) = 'partially_paid');
  PERFORM zz.check('o2 orders.payment_status stays unpaid', (SELECT payment_status::text FROM public.orders WHERE id = o2) = 'unpaid');

  ------------------------------------------------------------------
  -- 5. One payment split across two invoices (o3 + o4), with an unallocated remainder.
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format(
    'SELECT public.record_credit_payment(%L, %L, 150, ''cash'', NULL, NULL, ''combined settlement'', NULL, %L::jsonb)::text',
    alpha, good, jsonb_build_array(
      jsonb_build_object('order_id', o3, 'amount', 80),
      jsonb_build_object('order_id', o4, 'amount', 60)
    )::text));
  PERFORM zz.check('owner can split one payment across two invoices', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('o3 fully settled by the split payment', (SELECT status FROM public.credit_invoice_status(o3)) = 'paid');
  PERFORM zz.check('o4 fully settled by the split payment', (SELECT status FROM public.credit_invoice_status(o4)) = 'paid');
  PERFORM zz.check('the GHS 10 unallocated remainder became a credit-on-account entry', EXISTS (
    SELECT 1 FROM public.credit_ledger_entries WHERE wholesaler_id = alpha AND pharmacy_id = good
      AND order_id IS NULL AND entry_type = 'payment' AND amount_ghs = 10));

  ------------------------------------------------------------------
  -- 6. Over-allocation is rejected, atomically (no partial write survives).
  ------------------------------------------------------------------
  -- o2's outstanding is GHS 50 here (150 invoiced, 100 paid in step 4). Use a 77/77 payment (an
  -- amount used nowhere else in this suite, so the "no new row" check below can't collide with a
  -- genuine earlier payment) so the allocation total doesn't ALSO exceed the payment amount --
  -- that's a separate check, tested just below -- and this one isolates the per-order
  -- outstanding-balance check on its own.
  r := zz.val_as(u_wo, format(
    'SELECT public.record_credit_payment(%L, %L, 77, ''cash'', NULL, NULL, NULL, NULL, %L::jsonb)::text',
    alpha, good, jsonb_build_array(jsonb_build_object('order_id', o2, 'amount', 77))::text));
  PERFORM zz.check('allocation exceeding outstanding balance is rejected', r LIKE 'ERR: Allocation of GHS%exceeds the outstanding balance%', r);
  PERFORM zz.check('the rejected attempt left no new payment row', (
    SELECT count(*) FROM public.credit_payments WHERE wholesaler_id = alpha AND pharmacy_id = good AND amount_ghs = 77) = 0);

  r := zz.val_as(u_wo, format(
    'SELECT public.record_credit_payment(%L, %L, 10, ''cash'', NULL, NULL, NULL, NULL, %L::jsonb)::text',
    alpha, good, jsonb_build_array(jsonb_build_object('order_id', o2, 'amount', 50))::text));
  PERFORM zz.check('allocations exceeding the payment amount is rejected', r LIKE 'ERR: Allocations (GHS%cannot exceed the payment amount%', r);

  ------------------------------------------------------------------
  -- 7. record_credit_adjustment: owner/manager only; creates an auditable ledger line.
  ------------------------------------------------------------------
  r := zz.val_as(u_wc, format(
    'SELECT public.record_credit_adjustment(%L, %L, %L, ''credit_note'', ''credit'', 10, ''damaged goods'')::text', alpha, good, o2));
  PERFORM zz.check('cashier cannot record a ledger adjustment', r LIKE 'ERR: Only wholesaler owners and managers%', r);

  r := zz.val_as(u_wm, format(
    'SELECT public.record_credit_adjustment(%L, %L, %L, ''credit_note'', ''credit'', 10, ''damaged goods'')::text', alpha, good, o2));
  PERFORM zz.check('manager can record a credit note', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('o2 outstanding drops by the credit note', (SELECT outstanding_ghs FROM public.credit_invoice_status(o2)) = 40);

  r := zz.val_as(u_wm, format(
    'SELECT public.record_credit_adjustment(%L, %L, %L, ''credit_note'', ''credit'', 5, NULL)::text', alpha, good, o2));
  PERFORM zz.check('an adjustment without a reason is rejected', r LIKE 'ERR: A reason is required%', r);

  ------------------------------------------------------------------
  -- 8. write_off_credit_invoice: zeroes the remaining balance, status becomes written_off, and a
  --    second attempt is rejected (nothing left to write off).
  ------------------------------------------------------------------
  r := zz.val_as(u_wm, format('SELECT public.write_off_credit_invoice(%L, ''uncollectible'')::text', o2));
  PERFORM zz.check('manager can write off the remaining balance', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('o2 outstanding is now 0', (SELECT outstanding_ghs FROM public.credit_invoice_status(o2)) = 0);
  PERFORM zz.check('o2 status is written_off (not just paid)', (SELECT status FROM public.credit_invoice_status(o2)) = 'written_off');

  r := zz.val_as(u_wm, format('SELECT public.write_off_credit_invoice(%L, ''again'')::text', o2));
  PERFORM zz.check('writing off an already-settled invoice is rejected', r LIKE 'ERR: This invoice has no outstanding balance%', r);

  ------------------------------------------------------------------
  -- 9. reverse_credit_ledger_entry: reverses o1's payment without touching the original row;
  --    reopens payment_status; a second reversal of the same entry is rejected.
  ------------------------------------------------------------------
  SELECT id INTO v_entry_id FROM public.credit_ledger_entries WHERE order_id = o1 AND entry_type = 'payment' LIMIT 1;
  r := zz.val_as(u_wo, format('SELECT public.reverse_credit_ledger_entry(%L, ''payment bounced'')::text', v_entry_id));
  PERFORM zz.check('owner can reverse a payment entry', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('the original payment entry still exists, unmodified', EXISTS (
    SELECT 1 FROM public.credit_ledger_entries WHERE id = v_entry_id AND direction = 'credit' AND amount_ghs = 200));
  PERFORM zz.check('o1 outstanding is back to 200 after the reversal', (SELECT outstanding_ghs FROM public.credit_invoice_status(o1)) = 200);
  PERFORM zz.check('o1 orders.payment_status reopened to unpaid', (SELECT payment_status::text FROM public.orders WHERE id = o1) = 'unpaid');

  r := zz.val_as(u_wo, format('SELECT public.reverse_credit_ledger_entry(%L, ''again'')::text', v_entry_id));
  PERFORM zz.check('reversing an already-reversed entry is rejected', r LIKE 'ERR: This entry has already been reversed%', r);

  ------------------------------------------------------------------
  -- 10. set_credit_invoice_dispute: overrides the computed status; accountant may set it,
  --     cashier may not; clearing it restores the normal computed status.
  ------------------------------------------------------------------
  r := zz.val_as(u_wc, format('SELECT public.set_credit_invoice_dispute(%L, TRUE, ''wrong items'')::text', o1));
  PERFORM zz.check('cashier cannot dispute an invoice', r LIKE 'ERR: You do not have permission to dispute%', r);

  r := zz.val_as(u_acc, format('SELECT public.set_credit_invoice_dispute(%L, TRUE, ''wrong items delivered'')::text', o1));
  PERFORM zz.check('accountant can dispute an invoice', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('a disputed invoice reports status = disputed even though it has an outstanding balance',
    (SELECT status FROM public.credit_invoice_status(o1)) = 'disputed');

  r := zz.val_as(u_acc, format('SELECT public.set_credit_invoice_dispute(%L, FALSE, NULL)::text', o1));
  PERFORM zz.check('clearing the dispute restores the normal computed status', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('o1 status back to not_due after clearing the dispute',
    (SELECT status FROM public.credit_invoice_status(o1)) = 'not_due');

  ------------------------------------------------------------------
  -- 11. Legacy "Confirm payment received" flow still works and mirrors into the ledger, topped up
  --     to the REMAINING balance (not blindly total_ghs) -- step 9's reversal reopened o1 to the
  --     full GHS 200 outstanding, and this settles it again via the plain UPDATE path this time.
  ------------------------------------------------------------------
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now(), payment_confirmed_by = u_wo
  WHERE id = o1;
  PERFORM zz.check('legacy confirm-payment mirrors a matching ledger entry', (
    SELECT count(*) FROM public.credit_ledger_entries
    WHERE order_id = o1 AND entry_type = 'payment' AND note LIKE 'Recorded via the order%Confirm Payment%') = 1);
  PERFORM zz.check('o1 outstanding is 0 again after the legacy flow', (SELECT outstanding_ghs FROM public.credit_invoice_status(o1)) = 0);

  ------------------------------------------------------------------
  -- 12. Checkout hook: a credit order placed through the real create_marketplace_orders RPC gets
  --     its invoice ledger entry automatically, with no manual insert.
  ------------------------------------------------------------------
  INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
  SELECT alpha, 'CL Test Product', 'Generic', 'Analgesic', 'TABLET', '100s', 20, 500, true;
  PERFORM public.create_marketplace_orders(u_po, good, jsonb_build_array(
    jsonb_build_object('productId', (SELECT id FROM public.products WHERE name = 'CL Test Product'), 'quantity', 2)
  ), ARRAY[alpha]);
  -- setup.sql seeds a standing 5% Alpha->Good Pharmacy customer discount, so the invoiced amount
  -- is 40 * 0.95 = 38, not the raw 2 * GHS20 subtotal -- match the order's own total_ghs rather
  -- than re-deriving the arithmetic here, so this check can't drift from checkout's own math.
  PERFORM zz.check('checkout with credit selected creates an invoice ledger entry automatically', EXISTS (
    SELECT 1 FROM public.credit_ledger_entries e
    JOIN public.orders o ON o.id = e.order_id
    WHERE o.pharmacy_id = good AND o.wholesaler_id = alpha AND o.is_credit_order
      AND e.entry_type = 'invoice' AND e.amount_ghs = o.total_ghs
      AND o.created_at > now() - interval '1 minute'));

  ------------------------------------------------------------------
  -- 13. Cross-tenant isolation: an unrelated wholesaler cannot record payments or adjustments
  --     against Good Pharmacy's credit line with Alpha.
  ------------------------------------------------------------------
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format(
    'SELECT public.record_credit_payment(%L, %L, 10, ''cash'', NULL, NULL, NULL, NULL, ''[]''::jsonb)::text', alpha, good));
  PERFORM zz.check('an unrelated wholesaler cannot record a payment for Alpha''s credit line', r LIKE 'ERR%', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format(
    'SELECT public.record_credit_adjustment(%L, %L, %L, ''adjustment'', ''debit'', 5, ''test'')::text', alpha, good, o1));
  PERFORM zz.check('an unrelated wholesaler cannot record an adjustment for Alpha''s credit line', r LIKE 'ERR%', r);

  ------------------------------------------------------------------
  -- 14. list_credit_invoices: the browsable list the payment-recording UI is built on. By this
  --     point o1/o3/o4 are paid, o2 is written off, and the checkout-hook order (step 12) is the
  --     only one still outstanding -- 5 credit invoices total for this wholesaler/pharmacy pair.
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.list_credit_invoices(%L, NULL, NULL)', alpha));
  PERFORM zz.check('list_credit_invoices(wholesaler, all statuses) returns every credit invoice', r = '5', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.list_credit_invoices(%L, NULL, ''outstanding'')', alpha));
  PERFORM zz.check('list_credit_invoices(wholesaler, outstanding) returns only the unsettled one', r = '1', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.list_credit_invoices(NULL, %L, NULL)', good));
  PERFORM zz.check('the pharmacy can list its own credit invoices from the other side', r = '5', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format('SELECT count(*)::text FROM public.list_credit_invoices(%L, NULL, NULL)', alpha));
  PERFORM zz.check('an unrelated wholesaler cannot list Alpha''s credit invoices', r LIKE 'ERR%', r);
  r := zz.val_as(u_wo, 'SELECT count(*)::text FROM public.list_credit_invoices(NULL, NULL, NULL)');
  PERFORM zz.check('list_credit_invoices requires at least one business id', r LIKE 'ERR%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
