// Pure helpers for the printed order documents (order copy, pick & pack sheet, delivery note, invoice).
// They only choose and word what an order already holds; every amount comes from the order as stored,
// nothing is re-priced here.

import {
  SETTLEMENT_LABELS,
  effectiveSettlementMethod,
  type PaymentStatusLike,
} from "@/lib/settlement";

export type PartyDetails = {
  name: string;
  address?: string | null;
  city?: string | null;
  region?: string | null;
  phone?: string | null;
  license_number?: string | null;
};

export type DocumentOrder = {
  total_ghs: number | string;
  subtotal_ghs?: number | string | null;
  discount_amount_ghs?: number | string | null;
  delivery_fee_ghs?: number | string | null;
  settlement_method?: string | null;
  is_credit_order?: boolean | null;
  payment_method?: string | null;
  payment_status?: string | null;
  credit_due_date?: string | null;
  credit_terms_days?: number | null;
  status?: string | null;
};

export type DocumentLine = {
  quantity: number;
  unit_price_ghs?: number | string | null;
  base_unit_price_ghs?: number | string | null;
};

const money = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;
const toNumber = (value: number | string | null | undefined): number | null => {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

export type DocumentTotals = {
  subtotal: number | null;
  discount: number;
  delivery: number | null;
  total: number;
};

/** The totals block. The delivery fee is the stored fee when the order has one; otherwise it is whatever
 * is left of the total after the subtotal and discounts (an older order that did not store it). With no
 * stored subtotal there is nothing to split, so only the total is shown. */
export function documentTotals(order: DocumentOrder): DocumentTotals {
  const total = money(toNumber(order.total_ghs) ?? 0);
  const subtotal = toNumber(order.subtotal_ghs);
  const discount = money(toNumber(order.discount_amount_ghs) ?? 0);
  const stored = toNumber(order.delivery_fee_ghs);
  const delivery =
    stored !== null
      ? money(stored)
      : subtotal !== null
        ? money(Math.max(0, total - (subtotal - discount)))
        : null;
  return { subtotal: subtotal === null ? null : money(subtotal), discount, delivery, total };
}

/** Quantity times the price actually charged (after any discount), rounded to the pesewa. */
export function lineAmount(line: DocumentLine): number {
  return money((toNumber(line.unit_price_ghs) ?? 0) * line.quantity);
}

/** A line that was discounted below its list price: the list price and the saving per unit, otherwise null. */
export function lineDiscount(line: DocumentLine): { listPrice: number; saving: number } | null {
  const list = toNumber(line.base_unit_price_ghs);
  const paid = toNumber(line.unit_price_ghs);
  if (list === null || paid === null || list <= paid) return null;
  return { listPrice: money(list), saving: money(list - paid) };
}

const PAYMENT_STATE: Record<PaymentStatusLike, string> = {
  unpaid: "payment pending",
  paid: "paid",
  refunded: "refunded",
  failed: "payment failed",
};

/** "Credit · 30 days · due 12 Nov 2026", "Cash on delivery · payment pending", "Bank transfer · paid". */
export function paymentTermsLine(
  order: DocumentOrder,
  formatDate: (iso: string) => string,
): string {
  const method = effectiveSettlementMethod(order);
  const parts: string[] = [SETTLEMENT_LABELS[method]];
  if (method === "credit") {
    if (order.credit_terms_days) parts.push(`${order.credit_terms_days} days`);
    if (order.credit_due_date) parts.push(`due ${formatDate(order.credit_due_date)}`);
  }
  const status = (order.payment_status ?? "unpaid") as PaymentStatusLike;
  parts.push(PAYMENT_STATE[status] ?? String(order.payment_status));
  return parts.join(" · ");
}

/** An invoice is issued for an order that stands; a cancelled order has none. */
export function canPrintInvoice(order: Pick<DocumentOrder, "status">): boolean {
  return order.status !== "cancelled";
}

/** Address lines for a party block, skipping anything missing. */
export function partyLines(party: PartyDetails | null | undefined): string[] {
  if (!party) return [];
  const place = [party.city, party.region].filter((part) => part && part.trim()).join(", ");
  return [
    party.address ?? "",
    place,
    party.phone ? `Tel: ${party.phone}` : "",
    party.license_number ? `Licence: ${party.license_number}` : "",
  ]
    .map((line) => line.trim())
    .filter(Boolean);
}
