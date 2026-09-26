export type InsightRow = {
  product_id: string;
  product_name: string;
  category: string | null;
  current_stock: number;
  price_ghs: number;
  stock_value_ghs: number;
  units_sold_window: number;
  units_sold_90d: number;
  daily_velocity: number;
  days_remaining: number | null;
  status: "out_of_stock" | "low_stock" | "dead_stock" | "ok";
  movement: "fast" | "slow" | null;
  suggested_reorder: number | null;
  total_products: number;
  total_out_of_stock: number;
  total_low_stock: number;
  total_dead_stock: number;
  total_stock_value_ghs: number;
  total_count: number;
};

export const STATUS_LABELS: Record<InsightRow["status"], string> = {
  out_of_stock: "Out of stock",
  low_stock: "Low stock",
  dead_stock: "Dead stock",
  ok: "Healthy",
};

export const INSIGHT_FILTERS: Array<{ value: string; label: string }> = [
  { value: "", label: "All" },
  { value: "out_of_stock", label: "Out of stock" },
  { value: "low_stock", label: "Low stock" },
  { value: "dead_stock", label: "Dead stock" },
  { value: "fast", label: "Fast moving" },
  { value: "slow", label: "Slow moving" },
];

export function daysRemainingLabel(row: Pick<InsightRow, "days_remaining" | "current_stock">) {
  if (row.current_stock <= 0) return "0 days";
  if (row.days_remaining === null || row.days_remaining === undefined) return "No recent sales";
  if (row.days_remaining > 365) return "Over a year";
  return `${Number(row.days_remaining).toFixed(row.days_remaining < 10 ? 1 : 0)} days`;
}
