// Back-orders: types for what get_order_backorder returns, and the pure helpers the screens use to word, validate and print them.
// The database enforces every rule; these only mirror it so people get a clear message first and the wording is the same everywhere.
import { formatGHS } from "@/lib/format";
import type { PrintableOrder } from "@/components/order-print";

export type BackorderStatus =
  "none" | "open" | "partially_fulfilled" | "fulfilled" | "closed" | "cancelled";

export type BackorderState = {
  status: BackorderStatus;
  backordered: number;
  outstanding: number;
  planned: number;
  sent: number;
  cancelled: number;
};

export type BackorderLine = {
  order_item_id: string;
  product_name: string;
  unit_price_ghs: number;
  backordered: number;
  sent: number;
  planned: number;
  cancelled: number;
  outstanding: number;
};

export type ShipmentStatus = "pending" | "packed" | "dispatched" | "delivered" | "cancelled";

export type ShipmentLine = {
  order_item_id: string;
  product_name: string;
  quantity: number;
  unit_price_ghs: number;
};

export type Shipment = {
  id: string;
  sequence: number;
  status: ShipmentStatus;
  amount: number;
  note: string | null;
  created_at: string;
  packed_at: string | null;
  dispatched_at: string | null;
  delivered_at: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  credit_due_date: string | null;
  lines: ShipmentLine[];
};

export type OrderBackorder = {
  state: BackorderState;
  lines: BackorderLine[];
  shipments: Shipment[];
};

export const BACKORDER_LABELS: Record<BackorderStatus, string> = {
  none: "No back-order",
  open: "Back-order open",
  partially_fulfilled: "Back-order partly sent",
  fulfilled: "Back-order fulfilled",
  closed: "Back-order closed (rest cancelled)",
  cancelled: "Back-order cancelled",
};

export const SHIPMENT_LABELS: Record<ShipmentStatus, string> = {
  pending: "Being prepared",
  packed: "Packed",
  dispatched: "On its way",
  delivered: "Delivered",
  cancelled: "Cancelled",
};

/** True while there is still something to come: units waiting for a shipment or in one that has not gone out. */
export function backorderIsLive(state: BackorderState | null | undefined): boolean {
  return Boolean(state) && state!.outstanding + state!.planned > 0;
}

/** "3 units to come" / "nothing to come". */
export function backorderBadge(state: BackorderState | null | undefined): string | null {
  if (!state || state.status === "none") return null;
  const toCome = state.outstanding + state.planned;
  if (toCome > 0)
    return `${BACKORDER_LABELS[state.status]}: ${toCome} unit${toCome === 1 ? "" : "s"} to come`;
  return BACKORDER_LABELS[state.status];
}

/** The next step a wholesaler can take on a shipment, or null when it is finished. */
export function nextShipmentStep(
  status: ShipmentStatus,
): { to: "packed" | "dispatched" | "delivered"; label: string } | null {
  switch (status) {
    case "pending":
      return { to: "packed", label: "Mark packed" };
    case "packed":
      return { to: "dispatched", label: "Dispatch" };
    case "dispatched":
      return { to: "delivered", label: "Mark delivered" };
    default:
      return null;
  }
}

export const canCancelShipment = (status: ShipmentStatus) =>
  status === "pending" || status === "packed";

// ---------------------------------------------------------------------------------------------------------------------
// Preparing a shipment
// ---------------------------------------------------------------------------------------------------------------------
export type ShipmentDraftLine = {
  order_item_id: string;
  product_name: string;
  unit_price_ghs: number;
  outstanding: number;
  /** What the person typed ("" = none). */
  quantity: string;
};

export function shipmentDraft(lines: BackorderLine[]): ShipmentDraftLine[] {
  return lines
    .filter((line) => line.outstanding > 0)
    .map((line) => ({
      order_item_id: line.order_item_id,
      product_name: line.product_name,
      unit_price_ghs: Number(line.unit_price_ghs),
      outstanding: line.outstanding,
      quantity: "",
    }));
}

export function draftQuantity(line: ShipmentDraftLine): number | null {
  const text = line.quantity.trim();
  if (text === "") return 0;
  return /^\d{1,9}$/.test(text) ? Number(text) : null;
}

const money = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;

export function shipmentDraftTotals(lines: ShipmentDraftLine[]) {
  let units = 0;
  let amount = 0;
  for (const line of lines) {
    const quantity = draftQuantity(line) ?? 0;
    units += quantity;
    amount += money(quantity * line.unit_price_ghs);
  }
  return { units, amount: money(amount) };
}

export function validateShipmentDraft(lines: ShipmentDraftLine[]): string | null {
  for (const line of lines) {
    const quantity = draftQuantity(line);
    if (quantity === null) return `Enter a whole number of units for ${line.product_name}.`;
    if (quantity > line.outstanding) {
      return `Only ${line.outstanding} unit${line.outstanding === 1 ? " of" : "s of"} ${line.product_name} ${line.outstanding === 1 ? "is" : "are"} waiting to be shipped.`;
    }
  }
  if (shipmentDraftTotals(lines).units === 0) return "Enter a quantity for at least one product.";
  return null;
}

export function shipmentPayload(lines: ShipmentDraftLine[]) {
  return lines
    .filter((line) => (draftQuantity(line) ?? 0) > 0)
    .map((line) => ({
      order_item_id: line.order_item_id,
      quantity: draftQuantity(line) as number,
    }));
}

// ---------------------------------------------------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------------------------------------------------
/** What accepting with a back-order means for the money, said plainly (credit orders). */
export function backorderConsequence(delta: number): string {
  const less = formatGHS(Math.abs(money(delta)));
  return `If you accept, the available quantity is supplied now. A credit note for ${less} removes the rest from this order's invoice, and each later shipment is invoiced separately when it is dispatched. Nothing is charged for goods that have not been sent.`;
}

export function shipmentSummary(shipment: Shipment): string {
  const units = shipment.lines.reduce((sum, line) => sum + line.quantity, 0);
  return `${units} unit${units === 1 ? "" : "s"} · ${formatGHS(shipment.amount)}`;
}

// ---------------------------------------------------------------------------------------------------------------------
// Printing a shipment: the same documents as an order, built from the shipment's own lines
// ---------------------------------------------------------------------------------------------------------------------
/** A printable order for one back-order shipment: its lines, its own number, its own total (no delivery fee, no discounts). */
export function shipmentPrintable(order: PrintableOrder, shipment: Shipment): PrintableOrder {
  return {
    ...order,
    order_number: `${order.order_number}-B${shipment.sequence}`,
    created_at: shipment.created_at,
    total_ghs: shipment.amount,
    effective_total_ghs: null,
    subtotal_ghs: shipment.amount,
    discount_amount_ghs: 0,
    delivery_fee_ghs: 0,
    status: shipment.status,
    credit_due_date: shipment.credit_due_date ?? order.credit_due_date ?? null,
    order_items: shipment.lines.map((line) => ({
      product_name: line.product_name,
      quantity: line.quantity,
      supplied_quantity: null,
      unit_price_ghs: Number(line.unit_price_ghs),
      base_unit_price_ghs: null,
    })),
  };
}
