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
};

export type RfqQuoteItem = {
  id: string;
  rfq_quote_id: string;
  rfq_item_id: string;
  product_id: string;
  quantity: number;
  unit_price_ghs: number;
  line_total_ghs: number;
  notes: string | null;
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
  notes: string;
  include: boolean;
};

/** Validates a wholesaler's quote submission before the round trip. */
export function validateQuoteDraft(lines: QuoteLineDraft[]) {
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
  }
  return { error: null, included };
}
