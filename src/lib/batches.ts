export type ExpiryStatus = "expired" | "within_30" | "within_60" | "within_90" | "ok";

export type BatchRow = {
  batch_id: string;
  product_id: string;
  product_name: string;
  batch_number: string;
  expiry_date: string;
  days_to_expiry: number;
  expiry_status: ExpiryStatus;
  quantity_received: number;
  quantity_on_hand: number;
  product_stock: number;
  product_batched_units: number;
  received_at: string;
  summary_expired: number;
  summary_within_30: number;
  summary_within_60: number;
  summary_within_90: number;
  summary_units_at_risk: number;
  total_count: number;
};

export type Pick = {
  batch_id: string;
  batch_number: string;
  expiry_date: string;
  quantity: number;
};

export type OrderPickLine = {
  order_item_id: string;
  product_name: string;
  quantity_needed: number;
  allocated: boolean;
  picks: Pick[];
  shortfall: number;
};

export const EXPIRY_LABELS: Record<ExpiryStatus, string> = {
  expired: "Expired",
  within_30: "Expires within 30 days",
  within_60: "Expires within 60 days",
  within_90: "Expires within 90 days",
  ok: "In date",
};

export const BATCH_FILTERS: Array<{ value: string; label: string }> = [
  { value: "", label: "All in stock" },
  { value: "expired", label: "Expired" },
  { value: "within_30", label: "30 days" },
  { value: "within_60", label: "60 days" },
  { value: "within_90", label: "90 days" },
  { value: "depleted", label: "Used up" },
];

export const WRITE_OFF_REASONS: Array<{ value: string; label: string }> = [
  { value: "expired", label: "Expired" },
  { value: "damaged", label: "Damaged" },
  { value: "other", label: "Other" },
];

export function expiryText(days: number) {
  if (days < 0) return `Expired ${Math.abs(days)} day${Math.abs(days) === 1 ? "" : "s"} ago`;
  if (days === 0) return "Expires today";
  return `${days} day${days === 1 ? "" : "s"} left`;
}

/** Checks a "receive batch" form before it is sent; the database re-checks everything. */
export function validateBatchInput(input: {
  productId: string;
  batchNumber: string;
  expiryDate: string;
  quantity: string;
  today?: string;
}) {
  if (!input.productId) return "Choose a product.";
  if (!input.batchNumber.trim()) return "Enter a batch number.";
  if (!input.expiryDate) return "Enter the expiry date.";
  const today = input.today ?? new Date().toISOString().slice(0, 10);
  if (input.expiryDate < today) return "This batch has already expired.";
  const quantity = Number(input.quantity);
  if (!Number.isInteger(quantity) || quantity < 1) return "Enter a whole quantity of at least 1.";
  return null;
}

export function pickSummary(line: OrderPickLine) {
  if (line.picks.length === 0) return "No batch stock recorded";
  return line.picks
    .map((pick) => `${pick.quantity} × ${pick.batch_number} (exp ${pick.expiry_date})`)
    .join(", ");
}
