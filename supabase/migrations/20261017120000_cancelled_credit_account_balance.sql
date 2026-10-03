-- Cancellation releases invoice charges; money already paid stays as account credit.
-- Do not silently rewrite historical cancellation entries on a database with paid cancellations.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.orders o JOIN public.credit_ledger_entries e ON e.order_id=o.id
    WHERE o.is_credit_order AND o.status='cancelled' AND e.entry_type='payment'
  ) THEN
    RAISE EXCEPTION 'Paid cancellations already exist; reconcile their account credits before applying this migration.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.release_credit_on_order_cancel()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_charges NUMERIC;
BEGIN
  IF NOT NEW.is_credit_order THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE cancellation_order_id=NEW.id) THEN RETURN NEW; END IF;
  -- Exclude payments and their reversals, so those credits remain on the account.
  -- Credit notes/write-offs still reduce the charges being cancelled.
  SELECT COALESCE(SUM(CASE e.direction WHEN 'debit' THEN e.amount_ghs ELSE -e.amount_ghs END),0)
  INTO v_charges FROM public.credit_ledger_entries e
  LEFT JOIN public.credit_ledger_entries original ON original.id=e.reverses_entry_id
  WHERE e.order_id=NEW.id AND e.entry_type <> 'payment'
    AND NOT (e.entry_type='reversal' AND COALESCE(original.entry_type='payment',false));
  IF v_charges>0 THEN
    INSERT INTO public.credit_ledger_entries(wholesaler_id,pharmacy_id,order_id,entry_type,direction,amount_ghs,created_by,note,cancellation_order_id)
    VALUES(NEW.wholesaler_id,NEW.pharmacy_id,NEW.id,'credit_note','credit',v_charges,auth.uid(),'Order cancelled; payments retained as account credit',NEW.id);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.release_credit_on_order_cancel() FROM PUBLIC,anon,authenticated;

DO $migration$
DECLARE definition TEXT;
  marker TEXT := '  IF v_entry.entry_type = ''reversal'' THEN';
BEGIN
  definition := pg_get_functiondef('public.reverse_credit_ledger_entry(uuid,text)'::regprocedure);
  IF strpos(definition,'Cancellation credits cannot be reversed')=0 THEN
    IF (length(definition)-length(replace(definition,marker,'')))/length(marker) <> 1 THEN
      RAISE EXCEPTION 'Unexpected reversal function; inspect before protecting cancellation credits.';
    END IF;
    EXECUTE replace(definition,marker,
      '  IF v_entry.cancellation_order_id IS NOT NULL THEN RAISE EXCEPTION ''Cancellation credits cannot be reversed; use a documented account adjustment.''; END IF;' || chr(10) || marker);
  END IF;
END;
$migration$;
