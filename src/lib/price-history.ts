// Helpers for the pharmacy "Price history" report. Every figure comes from
// pharmacy_price_history() / pharmacy_price_history_detail(); nothing is calculated here except
// wording and the shape of exports. The matching and change rules are documented in
// supabase/migrations/20261023100000_pharmacy_price_history.sql.

export type PriceHistoryRow = {
  sample_product_id: string;
  product_name: string;
  brand: string | null;
  form: string | null;
  pack_size: string | null;
  purchases: number | string;
  units: number | string;
  spend_ghs: number | string;
  avg_paid_ghs: number | string | null;
  min_paid_ghs: number | string;
  max_paid_ghs: number | string;
  suppliers: number | string;
  latest_paid_ghs: number | string;
  latest_at: string;
  latest_supplier_id: string;
  latest_supplier_name: string;
  previous_paid_ghs: number | string | null;
  change_pct: number | string | null;
  cheaper_paid_ghs: number | string | null;
  cheaper_supplier_name: string | null;
  total_count: number | string;
};

export type PriceHistoryDetailRow = {
  purchased_at: string;
  order_id: string;
  order_number: string;
  supplier_id: string;
  supplier_name: string;
  quantity: number;
  list_price_ghs: number | string;
  paid_ghs: number | string;
  purchase_category: string | null;
  order_status: string;
  previous_paid_ghs: number | string | null;
  change_pct: number | string | null;
  total_count: number | string;
};

export type PriceHistoryFilters = {
  supplierId: string;
  category: string;
  search: string;
};

export const EMPTY_PRICE_HISTORY_FILTERS: PriceHistoryFilters = {
  supplierId: "",
  category: "",
  search: "",
};

export const PRICE_HISTORY_LIMIT = 200;
export const PRICE_HISTORY_DETAIL_LIMIT = 200;

type RangeArgs = { p_range: string; p_from: string | null; p_to: string | null };

const blankToNull = (value: string) => (value.trim() === "" ? null : value.trim());
const num = (value: number | string | null | undefined) => {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
};

export function priceHistoryArgs(
  businessId: string,
  range: RangeArgs,
  filters: PriceHistoryFilters,
) {
  return {
    p_business_id: businessId,
    ...range,
    p_wholesaler_id: blankToNull(filters.supplierId),
    p_purchase_category: blankToNull(filters.category),
    p_search: blankToNull(filters.search),
    p_limit: PRICE_HISTORY_LIMIT,
    p_offset: 0,
  };
}

export function priceHistoryDetailArgs(
  businessId: string,
  productId: string,
  range: RangeArgs,
  filters: PriceHistoryFilters,
) {
  return {
    p_business_id: businessId,
    p_product_id: productId,
    ...range,
    p_wholesaler_id: blankToNull(filters.supplierId),
    p_purchase_category: blankToNull(filters.category),
    p_limit: PRICE_HISTORY_DETAIL_LIMIT,
  };
}

export type ChangeDirection = "up" | "down" | "same" | "none";

/** The change since the previous purchase from the same supplier, in words so it never depends on colour. */
export function describeChange(changePct: number | string | null | undefined): {
  direction: ChangeDirection;
  label: string;
} {
  if (changePct === null || changePct === undefined) return { direction: "none", label: "—" };
  const value = Number(changePct);
  if (!Number.isFinite(value)) return { direction: "none", label: "—" };
  if (value === 0) return { direction: "same", label: "No change" };
  return value > 0
    ? { direction: "up", label: `Up ${value.toFixed(1)}%` }
    : { direction: "down", label: `Down ${Math.abs(value).toFixed(1)}%` };
}

/** "Brand · FORM · 100s" without empty parts. */
export function productDescriptor(row: {
  brand: string | null;
  form: string | null;
  pack_size: string | null;
}): string {
  return [row.brand, row.form, row.pack_size]
    .map((part) => (part ?? "").trim())
    .filter(Boolean)
    .join(" · ");
}

export type PriceHistoryExport = {
  filenamePrefix: string;
  headers: string[];
  rows: Array<Array<string | number>>;
};

export function priceHistoryExport(rows: PriceHistoryRow[]): PriceHistoryExport {
  return {
    filenamePrefix: "pharmacy-price-history",
    headers: [
      "Product",
      "Brand",
      "Form",
      "Pack size",
      "Purchases",
      "Units",
      "Spend GHS",
      "Average paid GHS",
      "Lowest paid GHS",
      "Highest paid GHS",
      "Suppliers",
      "Latest paid GHS",
      "Latest purchase",
      "Latest supplier",
      "Previous paid GHS (same supplier)",
      "Change %",
      "Cheaper elsewhere GHS",
      "Cheaper at",
    ],
    rows: rows.map((row) => [
      row.product_name,
      row.brand ?? "",
      row.form ?? "",
      (row.pack_size ?? "").trim(),
      num(row.purchases),
      num(row.units),
      num(row.spend_ghs),
      num(row.avg_paid_ghs),
      num(row.min_paid_ghs),
      num(row.max_paid_ghs),
      num(row.suppliers),
      num(row.latest_paid_ghs),
      row.latest_at.slice(0, 10),
      row.latest_supplier_name,
      row.previous_paid_ghs === null ? "" : num(row.previous_paid_ghs),
      row.change_pct === null ? "" : num(row.change_pct),
      row.cheaper_paid_ghs === null ? "" : num(row.cheaper_paid_ghs),
      row.cheaper_supplier_name ?? "",
    ]),
  };
}
