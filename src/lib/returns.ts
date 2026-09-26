export type ReturnStatus =
  | "requested"
  | "approved"
  | "rejected"
  | "cancelled"
  | "returned"
  | "inspected"
  | "resolved";

export type ReturnResolution = "refund" | "credit" | "replacement" | "none";

export const RETURN_REASONS: Array<{ value: string; label: string }> = [
  { value: "wrong_product", label: "Wrong product" },
  { value: "damaged", label: "Damaged" },
  { value: "short_dated", label: "Short-dated" },
  { value: "over_delivered", label: "Over-delivered" },
  { value: "quality_issue", label: "Quality issue" },
  { value: "wrong_quantity", label: "Wrong quantity" },
];

export const RETURN_STATUS_LABELS: Record<ReturnStatus, string> = {
  requested: "Requested",
  approved: "Approved",
  rejected: "Rejected",
  cancelled: "Cancelled",
  returned: "Goods returned",
  inspected: "Inspected",
  resolved: "Resolved",
};

export const RESOLUTION_LABELS: Record<ReturnResolution, string> = {
  refund: "Refunded",
  credit: "Credited to account",
  replacement: "Replacement sent",
  none: "No action",
};

export const RETURN_STATUS_FILTERS: Array<{ value: string; label: string }> = [
  { value: "", label: "All" },
  { value: "requested", label: "Requested" },
  { value: "approved", label: "Approved" },
  { value: "returned", label: "Returned" },
  { value: "inspected", label: "Inspected" },
  { value: "resolved", label: "Resolved" },
  { value: "rejected", label: "Rejected" },
  { value: "cancelled", label: "Cancelled" },
];

export type ReturnItem = {
  id: string;
  product_name: string;
  unit_price_ghs: number;
  quantity_requested: number;
  quantity_accepted: number | null;
  restock: boolean;
};

export type ReturnRow = {
  id: string;
  return_number: string;
  order_id: string;
  order_number: string;
  status: ReturnStatus;
  reason: string;
  note: string | null;
  wholesaler_note: string | null;
  resolution: ReturnResolution | null;
  resolved_amount_ghs: number | null;
  counterparty_name: string;
  created_at: string;
  updated_at: string;
  items: ReturnItem[];
  total_count: number;
};

const HAPPY_PATH: ReturnStatus[] = ["requested", "approved", "returned", "inspected", "resolved"];

/** Steps for the progress display; rejected/cancelled returns stop at the step where they ended. */
export function returnTimeline(status: ReturnStatus) {
  if (status === "rejected" || status === "cancelled") {
    return [
      { key: "requested", label: RETURN_STATUS_LABELS.requested, done: true },
      { key: status, label: RETURN_STATUS_LABELS[status], done: true },
    ];
  }
  const reached = HAPPY_PATH.indexOf(status);
  return HAPPY_PATH.map((key, index) => ({
    key,
    label: RETURN_STATUS_LABELS[key],
    done: index <= reached,
  }));
}

export type WholesalerAction = "review" | "receive" | "inspect" | "resolve";

/** Which action the wholesaler can take next, given their permission level. */
export function nextWholesalerAction(
  status: ReturnStatus,
  level: { canProcess: boolean; canManage: boolean },
): WholesalerAction | null {
  if (status === "requested" && level.canProcess) return "review";
  if (status === "approved" && level.canProcess) return "receive";
  if (status === "returned" && level.canManage) return "inspect";
  if (status === "inspected" && level.canManage) return "resolve";
  return null;
}

export function acceptedValue(items: ReturnItem[], accepted: Record<string, number>) {
  return items.reduce(
    (sum, item) => sum + (accepted[item.id] ?? 0) * Number(item.unit_price_ghs),
    0,
  );
}

/** Checks a pharmacy's selection against what the server says is still returnable. */
export function validateReturnSelection(
  lines: Array<{ quantity: number; available: number; name: string }>,
) {
  const chosen = lines.filter((line) => line.quantity > 0);
  if (chosen.length === 0) return "Choose at least one item to return.";
  for (const line of chosen) {
    if (!Number.isInteger(line.quantity)) return `Enter a whole number for ${line.name}.`;
    if (line.quantity > line.available)
      return `Only ${line.available} unit(s) of ${line.name} can still be returned.`;
  }
  return null;
}
