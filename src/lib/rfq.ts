// RFQ: shared types + client-side validation for the request/quote/award flow. The database
// repeats every check here -- this is just to fail fast with a clear message before the round trip.

export type RfqStatus = "open" | "awarded" | "cancelled";
export type RfqQuoteStatus = "submitted" | "withdrawn" | "accepted" | "rejected";

export type Rfq = {
  id: string;
  reference: string;
  pharmacy_id: string;
  title: string;
  notes: string | null;
  status: RfqStatus;
  response_deadline: string | null;
  awarded_quote_id: string | null;
  awarded_order_id: string | null;
  created_by: string;
  created_at: string;
};

export type RfqItem = {
  id: string;
  rfq_id: string;
  product_name: string;
  quantity: number;
  notes: string | null;
};

export type RfqInvitee = {
  rfq_id: string;
  wholesaler_id: string;
  invited_at: string;
};

export type RfqQuote = {
  id: string;
  rfq_id: string;
  wholesaler_id: string;
  status: RfqQuoteStatus;
  total_ghs: number;
  delivery_notes: string | null;
  valid_until: string | null;
  submitted_at: string;
  delivery_charge_ghs: number;
  lead_time_days: number | null;
  payment_terms: string | null;
};

export type RfqQuoteItem = {
  id: string;
  rfq_quote_id: string;
  rfq_item_id: string;
  product_id: string;
  quantity: number;
  unit_price_ghs: number;
  discount_percent: number;
  final_unit_price_ghs: number;
  line_total_ghs: number;
  notes: string | null;
};

export type RfqAward = {
  id: string;
  rfq_id: string;
  rfq_item_id: string;
  rfq_quote_id: string;
  rfq_quote_item_id: string;
  wholesaler_id: string;
  quantity: number;
  unit_price_ghs: number;
  order_id: string;
};

export const RFQ_STATUS_LABELS: Record<RfqStatus, string> = {
  open: "Open",
  awarded: "Awarded",
  cancelled: "Cancelled",
};

export const RFQ_STATUS_STYLES: Record<RfqStatus, string> = {
  open: "bg-primary/15 text-primary border-primary/30",
  awarded: "bg-success/15 text-success border-success/30",
  cancelled: "bg-muted text-muted-foreground border-border",
};

export const RFQ_QUOTE_STATUS_LABELS: Record<RfqQuoteStatus, string> = {
  submitted: "Submitted",
  withdrawn: "Withdrawn",
  accepted: "Accepted",
  rejected: "Not selected",
};

export const RFQ_QUOTE_STATUS_STYLES: Record<RfqQuoteStatus, string> = {
  submitted: "bg-primary/15 text-primary border-primary/30",
  withdrawn: "bg-muted text-muted-foreground border-border",
  accepted: "bg-success/15 text-success border-success/30",
  rejected: "bg-destructive/15 text-destructive border-destructive/30",
};

export type RfqItemDraft = {
  productName: string;
  quantity: string;
  notes: string;
};

/** Validates the create-RFQ form before submitting. */
export function validateRfqDraft(input: {
  title: string;
  wholesalerIds: string[];
  items: RfqItemDraft[];
  responseDeadline: string;
}) {
  if (!input.title.trim()) {
    return { error: "Enter a title for this RFQ." };
  }
  if (input.wholesalerIds.length === 0) {
    return { error: "Invite at least one supplier." };
  }
  const items = input.items.filter((i) => i.productName.trim() !== "");
  if (items.length === 0) {
    return { error: "Add at least one item." };
  }
  for (const item of items) {
    const qty = Number(item.quantity);
    if (!Number.isFinite(qty) || qty <= 0) {
      return { error: `Enter a quantity greater than zero for "${item.productName.trim()}".` };
    }
  }
  if (input.responseDeadline && new Date(input.responseDeadline).getTime() <= Date.now()) {
    return { error: "The response deadline must be in the future." };
  }
  return { error: null, items };
}

export type QuoteLineDraft = {
  rfqItemId: string;
  productId: string;
  unitPriceGhs: string;
  /** Quantity the supplier can actually supply; blank means the full requested quantity. */
  quantity: string;
  discountPercent: string;
  notes: string;
  include: boolean;
};

export function roundMoney(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

/** Unit price after the supplier's discount -- the figure the order is created at. */
export function finalUnitPrice(unitPrice: number, discountPercent: number) {
  return roundMoney(unitPrice * (1 - discountPercent / 100));
}

/** Validates a wholesaler's quote submission before the round trip. `requested` maps each rfq item
 * id to the quantity the pharmacy asked for, so a supplier can't offer more than was requested. */
export function validateQuoteDraft(
  lines: QuoteLineDraft[],
  requested: Record<string, number> = {},
) {
  const included = lines.filter((l) => l.include);
  if (included.length === 0) {
    return { error: "Select at least one item to quote." };
  }
  for (const line of included) {
    if (!line.productId) {
      return { error: "Choose which of your products fulfils each selected item." };
    }
    const price = Number(line.unitPriceGhs);
    if (!Number.isFinite(price) || price <= 0) {
      return { error: "Enter a unit price greater than zero for each selected item." };
    }
    if (line.quantity.trim() !== "") {
      const quantity = Number(line.quantity);
      const max = requested[line.rfqItemId];
      if (!Number.isInteger(quantity) || quantity < 1 || (max !== undefined && quantity > max)) {
        return {
          error:
            max !== undefined
              ? `Available quantity must be a whole number from 1 to ${max}.`
              : "Available quantity must be a whole number of at least 1.",
        };
      }
    }
    if (line.discountPercent.trim() !== "") {
      const discount = Number(line.discountPercent);
      if (!Number.isFinite(discount) || discount < 0 || discount >= 100) {
        return { error: "A discount must be at least 0% and less than 100%." };
      }
      if (finalUnitPrice(price, discount) <= 0) {
        return { error: "The price after discount must be greater than zero." };
      }
    }
  }
  return { error: null, included };
}

/** Validates the quote-level terms (delivery charge, lead time) before the round trip. */
export function validateQuoteTerms(input: {
  deliveryCharge: string;
  leadTimeDays: string;
  paymentTerms: string;
}) {
  if (input.deliveryCharge.trim() !== "") {
    const charge = Number(input.deliveryCharge);
    if (!Number.isFinite(charge) || charge < 0)
      return { error: "The delivery charge must be zero or more." };
  }
  if (input.leadTimeDays.trim() !== "") {
    const days = Number(input.leadTimeDays);
    if (!Number.isInteger(days) || days < 0)
      return { error: "The lead time must be a whole number of days." };
  }
  if (input.paymentTerms.length > 200)
    return { error: "Payment terms are too long (200 characters maximum)." };
  return { error: null };
}

/** quote item id -> quantity to award (as typed). Absent / blank / 0 means "not awarded". */
export type AwardSelection = Record<string, string>;

export function buildAwardPayload(selection: AwardSelection) {
  return Object.entries(selection)
    .map(([quoteItemId, qty]) => ({ quoteItemId, quantity: Number(qty) }))
    .filter((entry) => Number.isFinite(entry.quantity) && entry.quantity > 0);
}

/** Checks a selection against what each supplier offered and what was requested. Mirrors the
 * database's own checks so the pharmacy sees the problem before the round trip. */
export function validateAwardSelection(
  selection: AwardSelection,
  quoteItems: RfqQuoteItem[],
  items: RfqItem[],
) {
  const payload = buildAwardPayload(selection);
  if (payload.length === 0) return { error: "Choose a quantity to award on at least one line." };
  const byId = new Map(quoteItems.map((q) => [q.id, q]));
  const awardedPerItem = new Map<string, number>();
  for (const entry of payload) {
    const line = byId.get(entry.quoteItemId);
    if (!line) return { error: "A selected quote line is no longer available." };
    if (!Number.isInteger(entry.quantity)) return { error: "Quantities must be whole numbers." };
    if (entry.quantity > line.quantity) {
      return {
        error: `A supplier only offered ${line.quantity} unit${line.quantity === 1 ? "" : "s"} on one of these lines.`,
      };
    }
    awardedPerItem.set(
      line.rfq_item_id,
      (awardedPerItem.get(line.rfq_item_id) ?? 0) + entry.quantity,
    );
  }
  for (const item of items) {
    const awarded = awardedPerItem.get(item.id) ?? 0;
    if (awarded > item.quantity) {
      return {
        error: `You've awarded ${awarded} of "${item.product_name}" but only requested ${item.quantity}.`,
      };
    }
  }
  return { error: null, payload };
}

export type SupplierAwardTotal = {
  quoteId: string;
  wholesalerId: string;
  lines: number;
  goods: number;
  delivery: number;
  total: number;
};

/** What each supplier would be paid for the current selection: goods at the final unit price plus
 * the delivery charge it quoted (charged once per supplier that wins anything). */
export function summariseAward(
  selection: AwardSelection,
  quotes: RfqQuote[],
  quoteItems: RfqQuoteItem[],
): SupplierAwardTotal[] {
  const payload = buildAwardPayload(selection);
  const lineById = new Map(quoteItems.map((q) => [q.id, q]));
  const totals = new Map<string, SupplierAwardTotal>();
  for (const entry of payload) {
    const line = lineById.get(entry.quoteItemId);
    const quote = line && quotes.find((q) => q.id === line.rfq_quote_id);
    if (!line || !quote) continue;
    const current = totals.get(quote.id) ?? {
      quoteId: quote.id,
      wholesalerId: quote.wholesaler_id,
      lines: 0,
      goods: 0,
      delivery: Number(quote.delivery_charge_ghs) || 0,
      total: 0,
    };
    current.lines += 1;
    current.goods = roundMoney(current.goods + Number(line.final_unit_price_ghs) * entry.quantity);
    current.total = roundMoney(current.goods + current.delivery);
    totals.set(quote.id, current);
  }
  return [...totals.values()];
}

/** "Award this entire quote": every line the supplier quoted, at the quantity it offered. */
export function selectEntireQuote(quoteId: string, quoteItems: RfqQuoteItem[]): AwardSelection {
  const selection: AwardSelection = {};
  for (const line of quoteItems)
    if (line.rfq_quote_id === quoteId) selection[line.id] = String(line.quantity);
  return selection;
}

/** For each requested item, the quote line(s) with the lowest final unit price. This only marks a
 * line as cheapest in the comparison -- nothing is ever awarded automatically. */
export function cheapestLineIds(quoteItems: RfqQuoteItem[]): Set<string> {
  const best = new Map<string, number>();
  for (const line of quoteItems) {
    const price = Number(line.final_unit_price_ghs);
    const current = best.get(line.rfq_item_id);
    if (current === undefined || price < current) best.set(line.rfq_item_id, price);
  }
  return new Set(
    quoteItems
      .filter((l) => Number(l.final_unit_price_ghs) === best.get(l.rfq_item_id))
      .map((l) => l.id),
  );
}

export type MasterProductSuggestion = {
  id: string;
  name: string;
  generic_name: string | null;
  brand_name: string | null;
  strength: string | null;
  dosage_form: string | null;
  pack_size: string | null;
};

/** The text an RFQ line gets when a catalogue medicine is picked: the catalogue name plus whichever
 * of strength / form / pack size it doesn't already contain, so two pharmacies picking the same
 * medicine send suppliers identical wording instead of free-text variants. */
export function masterProductLabel(product: MasterProductSuggestion): string {
  const name = product.name.trim();
  const lower = name.toLowerCase();
  const extras = [product.strength, product.dosage_form, product.pack_size]
    .map((part) => (part ?? "").trim())
    .filter((part) => part !== "" && !lower.includes(part.toLowerCase()));
  return extras.length > 0 ? `${name} ${extras.join(" ")}` : name;
}

/** Escapes characters that are special inside a PostgREST ilike/or filter value. */
export function toIlikeTerm(raw: string): string {
  return raw
    .trim()
    .replace(/[%_\\,()]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
