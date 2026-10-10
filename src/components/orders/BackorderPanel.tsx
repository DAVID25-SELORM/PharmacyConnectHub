import { useCallback, useEffect, useState } from "react";
import { PackagePlus, Truck } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { TextDialog } from "@/components/orders/TextDialog";
import { OrderPrintActions, type PrintableOrder } from "@/components/order-print";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { confirmOrderPayment, sendOrderReceipt } from "@/lib/order-actions";
import {
  BACKORDER_LABELS,
  SHIPMENT_LABELS,
  backorderBadge,
  canCancelShipment,
  draftQuantity,
  nextShipmentStep,
  shipmentDraft,
  shipmentDraftTotals,
  shipmentPayload,
  shipmentPrintable,
  shipmentSummary,
  validateShipmentDraft,
  type BackorderLine,
  type OrderBackorder,
  type Shipment,
  type ShipmentDraftLine,
} from "@/lib/order-backorder";
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Side = "wholesaler" | "pharmacy";

const readError = (error: unknown) =>
  (error as { message?: string } | null)?.message ?? "Something went wrong. Please try again.";

/** The back-order of an order: what is still to come, each shipment with its status, and the actions for each side. Shows nothing
 * for an order that has no back-order. */
export function BackorderPanel({
  orderId,
  orderStatus,
  side,
  canAct,
  canCollect = false,
  printable,
  refreshKey,
  onChanged,
}: {
  orderId: string;
  orderStatus: string;
  side: Side;
  /** Whether this user may act (the database enforces it; this only hides buttons). */
  canAct: boolean;
  /** Wholesaler side: may this user confirm that a shipment's cash was received and send its receipt? */
  canCollect?: boolean;
  /** The order as a printable document, for the shipment pick sheets, delivery notes and invoices. */
  printable: PrintableOrder | null;
  /** Changes when the proposal part of the order changes, so this part reloads too. */
  refreshKey?: number;
  onChanged?: () => void;
}) {
  const [data, setData] = useState<OrderBackorder | null>(null);
  const [failed, setFailed] = useState(false);
  const [preparing, setPreparing] = useState(false);
  const [cancelling, setCancelling] = useState<Shipment | null>(null);
  const [cancellingRest, setCancellingRest] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setFailed(false);
    const { data: result, error } = await db.rpc("get_order_backorder", { p_order_id: orderId });
    if (error) return setFailed(true);
    setData(result as OrderBackorder);
  }, [orderId]);

  useEffect(() => {
    void load();
  }, [load, orderStatus, refreshKey]);

  const run = async (fn: string, args: Record<string, unknown>, success: string) => {
    setBusy(true);
    const { error } = await db.rpc(fn, args);
    setBusy(false);
    if (error) {
      toast.error(readError(error));
      return false;
    }
    toast.success(success);
    await load();
    onChanged?.();
    return true;
  };

  if (failed) {
    return (
      <p role="alert" className="mt-3 text-sm">
        We couldn&apos;t load this order&apos;s back-order.{" "}
        <button type="button" className="text-primary underline" onClick={() => void load()}>
          Try again
        </button>
      </p>
    );
  }
  if (!data || data.state.status === "none") return null;

  const { state, lines, shipments } = data;
  const cash = Boolean(data.cash_portions);
  const collect = async (shipment: Shipment) => {
    setBusy(true);
    try {
      const result = await confirmOrderPayment({ orderId, shipmentId: shipment.id });
      toast.success(
        result.receiptSent
          ? `Payment for shipment ${shipment.sequence} confirmed and receipt emailed.`
          : `Payment for shipment ${shipment.sequence} confirmed. Its receipt still needs to be sent.`,
      );
      if (result.warning) toast.error(result.warning);
      await load();
      onChanged?.();
    } catch (error) {
      toast.error(readError(error));
    } finally {
      setBusy(false);
    }
  };
  const resend = async (shipment: Shipment) => {
    setBusy(true);
    try {
      const result = await sendOrderReceipt({ orderId, shipmentId: shipment.id });
      if (result.sent) {
        toast.success(`Receipt for shipment ${shipment.sequence} emailed.`);
        await load();
      } else toast.error(result.warning || "Receipt email could not be sent.");
    } catch (error) {
      toast.error(readError(error));
    } finally {
      setBusy(false);
    }
  };
  const canPrepare =
    side === "wholesaler" &&
    canAct &&
    state.outstanding > 0 &&
    (orderStatus === "dispatched" || orderStatus === "delivered");
  const canCancelRest = canAct && state.outstanding > 0;

  return (
    <div className="mt-4 rounded-lg border border-border p-3 text-sm" aria-label="Back-order">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h4 className="flex items-center gap-2 font-semibold">
          <Truck className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
          Back-order
        </h4>
        <span className="rounded-full bg-muted px-2 py-0.5 text-xs font-medium">
          {backorderBadge(state) ?? BACKORDER_LABELS[state.status]}
        </span>
      </div>
      <p className="mt-1 text-xs text-muted-foreground">
        {cash
          ? "The goods that were not supplied with the order. Each shipment is added to the order when it is dispatched, paid for on its own delivery and receipted separately; nothing is charged for goods that have not been sent."
          : "The goods that were not supplied with the order. Each shipment is invoiced when it is dispatched; nothing is charged for goods that have not been sent."}
      </p>
      {cash && (
        <p className="mt-1 text-xs text-muted-foreground">
          Main delivery{data.main_total !== undefined ? ` (${formatGHS(data.main_total)})` : ""}:{" "}
          {data.main_collected_at
            ? `paid ${formatReportDate(data.main_collected_at)}`
            : "payment pending, confirmed on the order"}
        </p>
      )}

      <div className="mt-3 overflow-x-auto">
        <table className="w-full text-sm">
          <caption className="sr-only">Back-ordered quantities per product</caption>
          <thead>
            <tr className="border-b border-border text-left text-xs text-muted-foreground">
              <th scope="col" className="py-1 pr-3 font-medium">
                Product
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Back-ordered
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Sent
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                In a shipment
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Cancelled
              </th>
              <th scope="col" className="py-1 text-right font-medium">
                Waiting
              </th>
            </tr>
          </thead>
          <tbody>
            {lines.map((line: BackorderLine) => (
              <tr key={line.order_item_id} className="border-b border-border/50">
                <td className="py-1 pr-3">{line.product_name}</td>
                <td className="py-1 pr-3 text-right tabular-nums">{line.backordered}</td>
                <td className="py-1 pr-3 text-right tabular-nums">{line.sent || "—"}</td>
                <td className="py-1 pr-3 text-right tabular-nums">{line.planned || "—"}</td>
                <td className="py-1 pr-3 text-right tabular-nums">{line.cancelled || "—"}</td>
                <td className="py-1 text-right font-medium tabular-nums">
                  {line.outstanding || "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {shipments.length > 0 && (
        <ul className="mt-3 space-y-2" aria-label="Back-order shipments">
          {shipments.map((shipment) => {
            const step = nextShipmentStep(shipment.status);
            return (
              <li key={shipment.id} className="rounded-md border border-border/70 p-2">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-medium">
                    Shipment {shipment.sequence}:{" "}
                    <span
                      className={
                        shipment.status === "cancelled"
                          ? "text-muted-foreground"
                          : "text-foreground"
                      }
                    >
                      {SHIPMENT_LABELS[shipment.status]}
                    </span>
                  </span>
                  <span className="text-xs text-muted-foreground">{shipmentSummary(shipment)}</span>
                </div>
                <ul className="mt-1 text-xs text-muted-foreground">
                  {shipment.lines.map((line) => (
                    <li key={line.order_item_id}>
                      {line.quantity} × {line.product_name} at {formatGHS(line.unit_price_ghs)}
                    </li>
                  ))}
                </ul>
                <div className="mt-1 text-xs text-muted-foreground">
                  Prepared {formatReportDate(shipment.created_at)}
                  {shipment.dispatched_at &&
                    ` · dispatched ${formatReportDate(shipment.dispatched_at)}`}
                  {shipment.delivered_at &&
                    ` · delivered ${formatReportDate(shipment.delivered_at)}`}
                  {!cash &&
                    shipment.credit_due_date &&
                    shipment.status !== "cancelled" &&
                    ` · payment due ${formatReportDate(shipment.credit_due_date)}`}
                  {shipment.status === "cancelled" &&
                    shipment.cancel_reason &&
                    ` · cancelled: ${shipment.cancel_reason}`}
                </div>
                {cash && (shipment.status === "dispatched" || shipment.status === "delivered") && (
                  <div className="mt-1 flex flex-wrap items-center gap-2 text-xs">
                    <span
                      className={
                        shipment.collected_at
                          ? "font-medium text-green-700"
                          : "text-muted-foreground"
                      }
                    >
                      {shipment.collected_at
                        ? `Paid ${formatReportDate(shipment.collected_at)}`
                        : shipment.status === "delivered"
                          ? "Payment due"
                          : "Payment due on delivery"}
                    </span>
                    {side === "wholesaler" &&
                      canCollect &&
                      shipment.status === "delivered" &&
                      !shipment.collected_at && (
                        <Button
                          type="button"
                          size="sm"
                          variant="outline"
                          disabled={busy}
                          onClick={() => void collect(shipment)}
                        >
                          Confirm payment received
                        </Button>
                      )}
                    {side === "wholesaler" && canCollect && shipment.collected_at && (
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() => void resend(shipment)}
                      >
                        {shipment.receipt_sent_at ? "Resend receipt" : "Send receipt"}
                      </Button>
                    )}
                  </div>
                )}
                {side === "wholesaler" &&
                  canAct &&
                  (step || canCancelShipment(shipment.status)) && (
                    <div className="mt-2 flex flex-wrap gap-2">
                      {step && (
                        <Button
                          type="button"
                          size="sm"
                          variant={step.to === "dispatched" ? "hero" : "outline"}
                          disabled={busy}
                          onClick={() =>
                            void run(
                              "advance_backorder_shipment",
                              { p_shipment_id: shipment.id, p_to: step.to },
                              step.to === "dispatched"
                                ? cash
                                  ? "Shipment dispatched"
                                  : "Shipment dispatched and invoiced"
                                : step.to === "packed"
                                  ? "Shipment packed"
                                  : "Shipment delivered",
                            )
                          }
                        >
                          {step.label}
                        </Button>
                      )}
                      {canCancelShipment(shipment.status) && (
                        <Button
                          type="button"
                          size="sm"
                          variant="outline"
                          disabled={busy}
                          onClick={() => setCancelling(shipment)}
                        >
                          Cancel shipment
                        </Button>
                      )}
                    </div>
                  )}
                {printable && shipment.status !== "cancelled" && (
                  <OrderPrintActions
                    order={shipmentPrintable(printable, shipment)}
                    wholesaler={side === "wholesaler"}
                  />
                )}
              </li>
            );
          })}
        </ul>
      )}

      {(canPrepare || canCancelRest) && (
        <div className="mt-3 flex flex-wrap gap-2">
          {canPrepare && (
            <Button type="button" size="sm" variant="hero" onClick={() => setPreparing(true)}>
              <PackagePlus className="mr-1 h-4 w-4" aria-hidden="true" /> Prepare a shipment
            </Button>
          )}
          {canCancelRest && (
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => setCancellingRest(true)}
            >
              Cancel the remaining back-order
            </Button>
          )}
        </div>
      )}

      {preparing && (
        <PrepareDialog
          lines={lines}
          cash={cash}
          busy={busy}
          onClose={() => setPreparing(false)}
          onSubmit={async (payload) => {
            const ok = await run(
              "create_backorder_shipment",
              { p_order_id: orderId, p_lines: payload, p_request_id: crypto.randomUUID() },
              "Shipment prepared",
            );
            if (ok) setPreparing(false);
          }}
        />
      )}
      {cancelling && (
        <TextDialog
          title={`Cancel shipment ${cancelling.sequence}?`}
          description="It has not been dispatched, so nothing was charged and no stock moved. Its goods go back to waiting to be shipped."
          label="Reason"
          submitLabel="Cancel shipment"
          required
          busy={busy}
          onClose={() => setCancelling(null)}
          onSubmit={async (reason) => {
            const ok = await run(
              "cancel_backorder_shipment",
              { p_shipment_id: cancelling.id, p_reason: reason },
              "Shipment cancelled",
            );
            if (ok) setCancelling(null);
          }}
        />
      )}
      {cancellingRest && (
        <TextDialog
          title="Cancel the remaining back-order?"
          description={`The ${state.outstanding} unit${state.outstanding === 1 ? "" : "s"} still waiting to be shipped will never be sent. Nothing was charged for them, so nothing changes in the amount owed.`}
          label="Reason"
          submitLabel="Cancel the remaining back-order"
          required
          busy={busy}
          onClose={() => setCancellingRest(false)}
          onSubmit={async (reason) => {
            const ok = await run(
              "cancel_backorder_remaining",
              { p_order_id: orderId, p_reason: reason },
              "Back-order cancelled",
            );
            if (ok) setCancellingRest(false);
          }}
        />
      )}
    </div>
  );
}

function PrepareDialog({
  lines,
  cash,
  busy,
  onClose,
  onSubmit,
}: {
  lines: BackorderLine[];
  cash: boolean;
  busy: boolean;
  onClose: () => void;
  onSubmit: (payload: ReturnType<typeof shipmentPayload>) => void | Promise<void>;
}) {
  const [draft, setDraft] = useState<ShipmentDraftLine[]>(() => shipmentDraft(lines));
  const [touched, setTouched] = useState(false);
  const problem = validateShipmentDraft(draft);
  const totals = shipmentDraftTotals(draft);
  return (
    <Dialog open onOpenChange={(next) => !next && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>Prepare a back-order shipment</DialogTitle>
          <DialogDescription>
            Choose what goes in this shipment. It is{" "}
            {cash ? "added to the order total" : "invoiced"}, and stock is deducted, when you
            dispatch it, not now.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          {draft.map((line) => (
            <div key={line.order_item_id} className="rounded-lg border border-border p-3 text-sm">
              <div className="flex flex-wrap justify-between gap-1">
                <span className="font-medium">{line.product_name}</span>
                <span className="text-xs text-muted-foreground">
                  {line.outstanding} waiting · {formatGHS(line.unit_price_ghs)} each
                </span>
              </div>
              <label className="mt-2 block text-xs">
                Quantity in this shipment
                <input
                  type="text"
                  inputMode="numeric"
                  className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                  placeholder="0"
                  value={line.quantity}
                  aria-label={`Quantity of ${line.product_name} in this shipment`}
                  onChange={(event) =>
                    setDraft((current) =>
                      current.map((item) =>
                        item.order_item_id === line.order_item_id
                          ? { ...item, quantity: event.target.value }
                          : item,
                      ),
                    )
                  }
                />
              </label>
              {draftQuantity(line) === null && (
                <p role="alert" className="mt-1 text-xs text-destructive">
                  Enter a whole number.
                </p>
              )}
            </div>
          ))}
        </div>
        <div className="rounded-lg bg-muted/50 p-3 text-sm" aria-live="polite">
          {totals.units === 0 ? (
            <span className="text-muted-foreground">
              Enter a quantity for at least one product.
            </span>
          ) : (
            <>
              <b>{totals.units}</b> unit{totals.units === 1 ? "" : "s"},{" "}
              <b>{formatGHS(totals.amount)}</b> to be invoiced when dispatched.
            </>
          )}
        </div>
        {touched && problem && (
          <p role="alert" className="text-sm text-destructive">
            {problem}
          </p>
        )}
        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
            Cancel
          </Button>
          <Button
            type="button"
            variant="hero"
            disabled={busy}
            onClick={() => {
              setTouched(true);
              if (problem) return;
              void onSubmit(shipmentPayload(draft));
            }}
          >
            {busy ? "Preparing…" : "Prepare shipment"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
