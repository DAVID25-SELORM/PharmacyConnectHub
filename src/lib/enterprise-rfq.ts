import { supabase } from "@/integrations/supabase/client";
import type { Rfq, RfqItem, RfqQuote, RfqQuoteItem } from "./rfq";

// Additive migrations are intentionally deployed separately from generated legacy types.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const rfqDb = supabase as any;
export async function rfqCall<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await rfqDb.rpc(name, args);
  if (error) throw new Error(error.message);
  return data as T;
}
export type EnterpriseRfq = Omit<Rfq, "status"> & {
  enterprise: boolean;
  status: string;
  revision: number;
  display_status?: string;
  quote_count?: number;
  delivery_location: string | null;
  expected_delivery_date: string | null;
  payment_preference: string;
  delivery_instructions: string | null;
  visibility: "private" | "open";
};
export type Requirement = RfqItem & {
  master_product_id: string | null;
  specification: Record<string, string | null>;
  unit: string;
  minimum_shelf_life_days: number;
  alternatives_allowed: boolean;
  partial_allowed: boolean;
  cold_chain_required: boolean;
  special_handling: string | null;
  cancelled_quantity: number;
};
export type VersionLine = RfqQuoteItem & {
  alternative: boolean;
  offered_specification: Record<string, string | number | null>;
  requested_units_per_offered_unit: number;
  expiry_date: string;
  batch_number: string | null;
  expected_available_on: string | null;
  cold_chain_supported: boolean;
  special_handling: string | null;
};
export type QuoteVersion = {
  id: string;
  quote_id: string;
  wholesaler_id: string;
  version: number;
  reason: string;
  created_at: string;
  snapshot: {
    quote: RfqQuote & { version: number };
    items: VersionLine[];
    orderDiscountPercent: number;
    taxTreatment: string;
  };
};
export type AwardGroup = {
  id: string;
  quote_version_id: string;
  wholesaler_id: string;
  status: string;
  order_id: string | null;
  goods_ghs: number;
  delivery_ghs: number;
  settlement_method: string;
  reason: string | null;
  last_error: string | null;
};
export type Allocation = {
  id: string;
  group_id: string;
  rfq_item_id: string;
  quote_item_id: string;
  quantity: number;
  requested_quantity: number;
  unit_price_ghs: number;
};
export const RFQ_STATES = [
  "draft",
  "open",
  "evaluation",
  "partially_awarded",
  "in_progress",
  "completed",
  "cancelled",
  "expired",
];
export const label = (value: string) => value.replaceAll("_", " ");
export function remainingRequirement(
  item: Requirement,
  allocations: Allocation[],
  groups: AwardGroup[],
) {
  const active = new Set(
    groups
      .filter((g) => ["pending", "conversion_failed", "confirmed"].includes(g.status))
      .map((g) => g.id),
  );
  return Math.max(
    0,
    item.quantity -
      item.cancelled_quantity -
      allocations
        .filter((a) => a.rfq_item_id === item.id && active.has(a.group_id))
        .reduce((s, a) => s + Number(a.requested_quantity), 0),
  );
}
/** Display sorting only. Database validates all totals and eligibility again. */
export function compareVersions(versions: QuoteVersion[], sort: string): QuoteVersion[] {
  const score = (v: QuoteVersion) =>
    sort === "delivery"
      ? (v.snapshot.quote.lead_time_days ?? Infinity)
      : sort === "quantity"
        ? -v.snapshot.items.reduce(
            (n, l) => n + Number(l.quantity) * Number(l.requested_units_per_offered_unit),
            0,
          )
        : Number(v.snapshot.quote.total_ghs) + Number(v.snapshot.quote.delivery_charge_ghs);
  return [...versions].sort((a, b) => score(a) - score(b) || a.id.localeCompare(b.id));
}
