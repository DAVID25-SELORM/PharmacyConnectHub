// What each order on a screen is now committed to supply, for orders that have been amended. The orders themselves keep
// the quantities and total as placed; this overlays the amended figures where a screen shows or prints them.
import { supabase } from "@/integrations/supabase/client";
import type { BackorderState } from "@/lib/order-backorder";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type SupplySummary = {
  order_id: string;
  current_total_ghs: number;
  /** The total of the main shipment alone (the order total less back-order shipments already invoiced). */
  main_total_ghs: number;
  has_open_amendment: boolean;
  backorder: BackorderState;
  lines: Array<{
    order_item_id: string;
    product_id: string;
    ordered_qty: number;
    supplied_qty: number;
  }>;
};

export type SupplyMap = Record<string, SupplySummary>;

/** Summaries for the amended orders among `orderIds` (un-amended orders are simply absent). Never throws. */
export async function loadOrderSupply(orderIds: string[]): Promise<SupplyMap> {
  const ids = [...new Set(orderIds)].filter(Boolean);
  if (ids.length === 0) return {};
  const { data, error } = await db.rpc("order_supply_summary", { p_order_ids: ids });
  if (error || !Array.isArray(data)) return {};
  const map: SupplyMap = {};
  for (const row of data as SupplySummary[]) map[row.order_id] = row;
  return map;
}

type WithItems = {
  id: string;
  total_ghs: number | string;
  order_items: Array<{ product_id?: string | null; quantity: number }>;
};

/** The order as it should be shown or printed: effective total and supplied quantities when it has been amended. */
export function withSupply<T extends WithItems>(
  order: T,
  supply: SupplyMap,
): T & {
  effective_total_ghs?: number | null;
  order_items: Array<T["order_items"][number] & { supplied_quantity?: number | null }>;
  has_open_amendment?: boolean;
  main_total_ghs?: number;
  backorder_state?: BackorderState;
} {
  const summary = supply[order.id];
  if (!summary) return order as never;
  const byProduct = new Map(summary.lines.map((line) => [line.product_id, line.supplied_qty]));
  const amendedTotal = Number(summary.current_total_ghs);
  return {
    ...order,
    effective_total_ghs: amendedTotal !== Number(order.total_ghs) ? amendedTotal : null,
    has_open_amendment: summary.has_open_amendment,
    main_total_ghs: Number(summary.main_total_ghs),
    backorder_state: summary.backorder,
    ...("unit_count" in order
      ? { unit_count: summary.lines.reduce((sum, line) => sum + line.supplied_qty, 0) }
      : {}),
    order_items: order.order_items.map((item) => ({
      ...item,
      supplied_quantity: item.product_id ? (byProduct.get(item.product_id) ?? null) : null,
    })),
  } as never;
}

/** The amount to show for an order: the effective total when amended, otherwise the total as placed. */
export function shownTotal(order: {
  total_ghs: number | string;
  effective_total_ghs?: number | string | null;
}): number {
  const effective = order.effective_total_ghs;
  return Number(effective === null || effective === undefined ? order.total_ghs : effective);
}

/** The order as its own printed documents show it: the main shipment's lines and the main shipment's total. Back-order shipments
 * print as documents of their own, so their amounts must not be added to the order's. */
export function forDocument<
  T extends { effective_total_ghs?: number | string | null; main_total_ghs?: number },
>(order: T): T {
  if (order.main_total_ghs === undefined) return order;
  return { ...order, effective_total_ghs: order.main_total_ghs };
}
