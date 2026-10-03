-- Production retains stock evidence/context tables and a legacy lifecycle guard that
-- predate the repository's credit checkout. Preserve those protections when present.
-- Fail closed on an unexpected function body instead of replacing unrelated logic.
DO $migration$
DECLARE
  definition TEXT;
  old_deduction TEXT := 'UPDATE public.products SET stock = stock - v_product.quantity WHERE id = v_product.id;';
  marker TEXT := '    -- Audit the classification this order was submitted with (value and line count per class).';
  addition TEXT := $patch$
    -- Checkout stock evidence: consumed by the production cancellation guard.
    INSERT INTO public.order_stock_deductions(order_id, product_id, wholesaler_id, quantity)
    SELECT v_order_id, product_id, wholesaler_id, quantity FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    INSERT INTO public.inventory_operation_context(transaction_id, actor_id, movement_type, order_id)
    VALUES(txid_current(), _caller_id, 'checkout_deduction', v_order_id);
    FOR v_product IN SELECT * FROM tmp_locked_products
      WHERE wholesaler_id = v_wholesaler.wholesaler_id ORDER BY product_id
    LOOP
      UPDATE public.products SET stock = stock - v_product.quantity WHERE id = v_product.product_id;
    END LOOP;
    DELETE FROM public.inventory_operation_context WHERE transaction_id = txid_current();

$patch$;
BEGIN
  IF to_regclass('public.order_stock_deductions') IS NOT NULL THEN
    IF to_regclass('public.inventory_operation_context') IS NULL THEN
      RAISE EXCEPTION 'Stock evidence exists without inventory context; inspect deployment.';
    END IF;
    definition := pg_get_functiondef('public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)'::regprocedure);
    IF strpos(definition, '-- Checkout stock evidence:') = 0 THEN
      IF (length(definition)-length(replace(definition,old_deduction,'')))/length(old_deduction) <> 1
        OR (length(definition)-length(replace(definition,marker,'')))/length(marker) <> 1 THEN
        RAISE EXCEPTION 'Unexpected checkout body; inspect before patching stock evidence.';
      END IF;
      definition := replace(definition,old_deduction,'-- Stock is deducted after order insertion while the product locks remain held.');
      definition := replace(definition,marker,addition || marker);
      EXECUTE definition;
    END IF;
  END IF;
END;
$migration$;

-- The legacy guard's financial immutability checks stay intact. Add the two
-- fulfilment stages supported by the deployed UI and status RPCs.
DO $migration$
DECLARE
  definition TEXT;
  old_transition TEXT := '(OLD.status = ''accepted'' AND NEW.status IN (''packed'',''cancelled''))';
  new_transition TEXT := '(OLD.status = ''accepted'' AND NEW.status IN (''picking'',''packed'',''cancelled'')) OR (OLD.status = ''picking'' AND NEW.status = ''packed'')';
  old_dispatch TEXT := '(OLD.status = ''packed'' AND NEW.status = ''dispatched'')';
  new_dispatch TEXT := '(OLD.status = ''packed'' AND NEW.status IN (''ready_for_dispatch'',''dispatched'')) OR (OLD.status = ''ready_for_dispatch'' AND NEW.status = ''dispatched'')';
BEGIN
  IF to_regprocedure('public.phase0_order_integrity()') IS NOT NULL THEN
    definition := pg_get_functiondef('public.phase0_order_integrity()'::regprocedure);
    IF strpos(definition, new_transition) = 0 THEN
      IF strpos(definition,old_transition) = 0 OR strpos(definition,old_dispatch) = 0 THEN
        RAISE EXCEPTION 'Unexpected legacy order guard; inspect before updating transitions.';
      END IF;
      EXECUTE replace(replace(definition,old_transition,new_transition),old_dispatch,new_dispatch);
    END IF;
  END IF;
END;
$migration$;
