/** Orders use Ghana business dates (UTC), with an exclusive next-day end. */
export function orderDateRange(from: string, to: string) {
  if (!from || !to) return { error: "Choose both dates." };
  const valid = (value: string) =>
    /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    Number.isFinite(Date.parse(`${value}T00:00:00Z`)) &&
    new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
  if (!valid(from) || !valid(to)) return { error: "Enter valid dates." };
  if (from > to) return { error: "Start date must be on or before end date." };
  return {
    from: `${from}T00:00:00.000Z`,
    to: new Date(Date.parse(`${to}T00:00:00Z`) + 86400000).toISOString(),
  };
}

export const ORDER_STAGES = [
  "all",
  "active",
  "pending",
  "accepted",
  "picking",
  "packed",
  "ready_for_dispatch",
  "dispatched",
  "delivered",
  "cancelled",
];
export const stageLabel = (stage: string) =>
  stage.replaceAll("_", " ").replace(/^./, (s) => s.toUpperCase());

export function orderDate(value: string) {
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    timeZone: "Africa/Accra",
  }).format(new Date(value));
}

/** List rows are summaries, never proof that a document's details are complete. */
export function hasOrderDetails(order: {
  detailLoaded?: boolean;
  item_count?: number;
  order_items: unknown[];
}) {
  return (
    order.detailLoaded === true &&
    order.order_items.length > 0 &&
    (order.item_count === undefined || order.order_items.length === order.item_count)
  );
}

export class LatestOrderRequest {
  private version = 0;
  start() {
    return ++this.version;
  }
  current(version: number) {
    return version === this.version;
  }
  invalidate() {
    ++this.version;
  }
}

export function mergeOrderSummary<T extends { order_items: unknown[]; wholesaler?: unknown }>(
  row: Record<string, unknown>,
  detail?: T,
): T {
  const itemCount = Number(row.item_count ?? 0);
  return {
    ...detail,
    ...row,
    detailLoaded: Boolean(detail && detail.order_items.length === itemCount && itemCount > 0),
    wholesaler:
      detail?.wholesaler ?? (row.wholesaler_name ? { name: String(row.wholesaler_name) } : null),
    order_items: detail?.order_items ?? [],
    item_count: itemCount,
    unit_count: Number(row.unit_count ?? 0),
  } as unknown as T;
}
