import { newDraft, newLine, type Draft } from "./external-procurement";
import type { DocumentBusiness } from "./document-branding";

export type SupplyLine = {
  id: string;
  unit?: string;
  catalogue_id?: string;
  catalogue_source?: "business" | "master";
  product_snapshot?: Record<string, string>;
  name: string;
  specification: string;
  quantity: number;
  unit_price: number | null;
};
export type SupplyDraft = {
  kind: "request" | "order";
  supplier: string;
  supplier_contact: string;
  required_date: string;
  delivery_address: string;
  notes: string;
  lines: SupplyLine[];
  source_request_id?: string;
  supplier_id?: string;
  supplier_reference?: string;
  supplier_email?: string;
  supplier_phone?: string;
};
export type SupplyOrder = {
  id: string;
  pharmacy_id: string;
  reference: string;
  kind: SupplyDraft["kind"];
  status: "draft" | "issued" | "shared" | "confirmed" | "cancelled";
  data: SupplyDraft;
  issuer: DocumentBusiness | null;
  version: number;
  created_at: string;
  issued_at: string | null;
};
export type Allocation = {
  line_id: string;
  product_name: string;
  quantity: number;
  unit?: string;
  packs_per_unit?: number;
  inventory_packs?: number;
};
export type SupplyReceipt = {
  id: string;
  reference: string;
  review_status: string;
  external_order_allocations: Allocation[];
};
export const supplyLine = (): SupplyLine => ({
  id: crypto.randomUUID(),
  name: "",
  specification: "",
  quantity: 1,
  unit: "packs",
  unit_price: null,
});
export const supplyDraft = (): SupplyDraft => ({
  kind: "request",
  supplier: "",
  supplier_contact: "",
  required_date: "",
  delivery_address: "",
  notes: "",
  lines: [supplyLine()],
});
export function receivedQuantity(lineId: string, receipts: SupplyReceipt[]) {
  return receipts.reduce(
    (sum, receipt) =>
      sum +
      receipt.external_order_allocations
        .filter((a) => a.line_id === lineId)
        .reduce((n, a) => n + a.quantity, 0),
    0,
  );
}
export function supplyStatus(order: SupplyOrder, receipts: SupplyReceipt[]) {
  if (order.status === "cancelled" || order.status === "draft" || order.kind === "request")
    return order.status;
  const total = order.data.lines.reduce((n, l) => n + l.quantity, 0);
  const received = order.data.lines.reduce((n, l) => n + receivedQuantity(l.id, receipts), 0);
  return received >= total ? "received" : received > 0 ? "partially received" : order.status;
}
export function receiptFromSupplyOrder(order: SupplyOrder, receipts: SupplyReceipt[]): Draft {
  return {
    ...newDraft(),
    external_order_id: order.id,
    channel: "unknown",
    source_type: "unknown",
    notes: `Received against ${order.reference}. Supplier: ${order.data.supplier}. Confirm actual seller and original source before review.`,
    items: order.data.lines.flatMap((l) => {
      const quantity = l.quantity - receivedQuantity(l.id, receipts);
      const factor =
        (l.unit || "packs") === "packs"
          ? 1
          : receipts.flatMap((r) => r.external_order_allocations).find((a) => a.line_id === l.id)
              ?.packs_per_unit;
      const packs = factor ? quantity * factor : 0;
      return quantity > 0
        ? [
            {
              ...newLine(),
              external_order_line_id: l.id,
              external_order_unit: l.unit || "packs",
              external_packs_per_unit: factor,
              product: {
                ...newLine().product,
                name: l.name,
                notes: l.specification,
                unit: "packs",
                pack_size: l.product_snapshot?.pack_size,
              },
              quantity: packs,
              unit_cost_ghs: factor === 1 ? (l.unit_price ?? 0) : 0,
              batches: [{ batch_number: "", expiry_date: "", quantity: packs }],
            },
          ]
        : [];
    }),
  };
}
export function validateSupplyDraft(d: SupplyDraft, complete = false): string | null {
  if (complete && !d.supplier.trim()) return "Enter a supplier or intended recipient.";
  if ((complete && !d.lines.length) || d.lines.length > 200) return "Add 1 to 200 items.";
  if (
    new Set(d.lines.filter((l) => l.name.trim()).map((l) => l.name.trim().toLowerCase())).size !==
    d.lines.filter((l) => l.name.trim()).length
  )
    return "Use distinct medicine names, including strength and pack size.";
  for (const l of d.lines) {
    if (
      (complete && !l.name.trim()) ||
      !Number.isSafeInteger(l.quantity) ||
      l.quantity < 1 ||
      l.quantity > 1000000
    )
      return "Each item needs a name and positive whole quantity.";
    if (
      l.unit_price !== null &&
      (!Number.isFinite(l.unit_price) ||
        l.unit_price < 0 ||
        l.unit_price >= 100000000 ||
        Math.abs(l.unit_price * 100 - Math.round(l.unit_price * 100)) > 0.00001)
    )
      return "Use valid prices with at most two decimal places.";
  }
  if (
    d.lines.reduce((n, l) => n + Math.round((l.unit_price ?? 0) * 100) * l.quantity, 0) >=
    100000000000000
  )
    return "Order total exceeds the supported purchase amount.";
  return null;
}
