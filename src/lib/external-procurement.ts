import type { SupabaseClient } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";
import type { ReportExportSheet } from "@/lib/reports";

export const CHANNELS = {
  external_licensed: "External licensed supplier",
  intermediary: "Individual / intermediary",
  unknown: "Other / unknown source",
};
export const SOURCES = {
  platform_wholesaler: "DrugXOne registered wholesaler",
  external_wholesaler: "External wholesaler / distributor",
  pharmacy: "Pharmacy",
  manufacturer: "Manufacturer",
  health_facility: "Hospital / health facility",
  other: "Other",
  unknown: "Unknown",
};
export const DOCUMENTS = {
  supplier_invoice: "Supplier invoice",
  receipt: "Receipt",
  delivery_note: "Delivery note",
  product_invoice: "Product invoice",
  purchase_receipt: "Purchase receipt",
  other: "Other evidence",
};
export const label = (s: string) => s.replaceAll("_", " ").replace(/^./, (c) => c.toUpperCase());
export type Contact = {
  id: string;
  name: string;
  phone?: string;
  email?: string;
  location?: string;
  license_reference?: string;
  alternate_phone?: string;
};
export type Context = {
  supplier_stats?: Record<
    string,
    { purchases: number; spend: number; last_purchase: string; unknown_sources: number }
  >;
  can_record: boolean;
  can_review: boolean;
  can_pay: boolean;
  is_owner: boolean;
  collect_identity: boolean;
  reviewers: string[];
  staff: { id: string; name: string }[];
  people: Contact[];
  companies: Contact[];
};
export type Product = {
  name: string;
  brand?: string;
  generic_name?: string;
  strength?: string;
  form?: string;
  pack_size?: string;
  manufacturer?: string;
  barcode?: string;
  registration?: string;
  notes?: string;
};
export type Batch = {
  id?: string;
  batch_number: string;
  expiry_date: string;
  quantity: number;
  remaining?: number;
  returned?: number;
  consumed?: number;
  disposition?: string;
};
export type Line = {
  id?: string;
  master_product_id: string;
  inventory_item_id: string;
  product: Product;
  quantity: number;
  unit_cost_ghs: number;
  batches: Batch[];
};
export type Draft = {
  purchase_date: string;
  channel: keyof typeof CHANNELS;
  seller_contact_id: string;
  seller_company_id: string;
  source_company_id: string;
  source_wholesaler_id: string;
  source_type: keyof typeof SOURCES;
  source: Record<string, string>;
  invoice_number: string;
  receipt_number: string;
  notes: string;
  payment_method: string;
  due_date: string;
  items: Line[];
};
export type Purchase = {
  id: string;
  reference: string;
  purchase_date: string;
  channel: keyof typeof CHANNELS;
  seller_contact_id: string | null;
  seller_company_id: string | null;
  source_company_id: string | null;
  source_wholesaler_id: string | null;
  source_type: keyof typeof SOURCES;
  seller_snapshot: Record<string, string>;
  source_snapshot: Record<string, string>;
  total_ghs: number;
  paid_ghs: number;
  credit_ghs: number;
  outstanding_ghs: number;
  payment_status: string;
  payment_method: string;
  due_date: string | null;
  invoice_number: string | null;
  receipt_number: string | null;
  notes: string | null;
  review_status: string;
  verification_status: string;
  reviewed_name?: string;
  received_name?: string;
  received_by: string;
  reviewed_by: string | null;
  reviewed_at: string | null;
  review_notes: string | null;
  posted_at: string | null;
  version: number;
  document_count: number;
  quarantine_batches: number;
};
export type Detail = Purchase & {
  items: (Omit<Line, "product"> & { product_snapshot: Product })[];
  documents: {
    id: string;
    document_type: string;
    filename: string;
    storage_path: string;
    uploaded_at: string;
  }[];
  events: {
    id: string;
    action: string;
    actor_id: string;
    occurred_at: string;
    details: Record<string, unknown>;
  }[];
  payments: {
    id: string;
    amount_ghs: number;
    method: string;
    reference: string;
    paid_at: string;
    reverses_id: string | null;
  }[];
  returns: {
    id: string;
    batch_id: string;
    quantity: number;
    kind: string;
    reason: string;
    returned_to: string;
    returned_at: string;
    credit_ghs: number;
  }[];
  signals: {
    missing_source: boolean;
    missing_invoice: boolean;
    incomplete_batches: boolean;
    expired_batches: boolean;
    previous_unknown: number;
    changed_source: boolean;
    possible_duplicate: boolean;
  };
};
export type Filters = {
  product: string;
  manufacturer: string;
  minimum_price: string;
  maximum_price: string;
  from: string;
  to: string;
  q: string;
  channel: string;
  verification: string;
  review: string;
  payment: string;
  supplier: string;
  source: string;
};
export const emptyFilters: Filters = {
  product: "",
  manufacturer: "",
  minimum_price: "",
  maximum_price: "",
  from: "",
  to: "",
  q: "",
  channel: "",
  verification: "",
  review: "",
  payment: "",
  supplier: "",
  source: "",
};
export type PurchaseList = { rows: Purchase[]; summary: Record<string, number> };
export type AnalyticsRow = {
  purchase_id: string;
  reference: string;
  date: string;
  channel: string;
  seller: string;
  source: string;
  product: string;
  manufacturer: string;
  quantity: number;
  returned: number;
  unit_cost: number;
  verification: string;
  review: string;
  invoice: string;
  batches: string;
};
export type Analytics = {
  products: {
    product_key: string;
    supplier_key: string;
    product: string;
    seller: string;
    channel: string;
    units: number;
    weighted_average: number;
    minimum_price: number;
    maximum_price: number;
    last_price: number;
    last_purchase: string;
  }[];
  rows: AnalyticsRow[];
  count: number;
  channels: {
    channel: string;
    units: number;
    returned: number;
    gross_cost: number;
  }[];
};
export const db = supabase as unknown as SupabaseClient;
export async function externalRpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(name, args);
  if (error) throw new Error(error.message);
  return data as T;
}
export const today = () => new Date().toISOString().slice(0, 10);
export const newLine = (): Line => ({
  master_product_id: "",
  inventory_item_id: "",
  product: { name: "" },
  quantity: 1,
  unit_cost_ghs: 0,
  batches: [{ batch_number: "", expiry_date: "", quantity: 1 }],
});
export const newDraft = (): Draft => ({
  purchase_date: today(),
  channel: "external_licensed",
  seller_contact_id: "",
  seller_company_id: "",
  source_company_id: "",
  source_wholesaler_id: "",
  source_type: "external_wholesaler",
  source: {},
  invoice_number: "",
  receipt_number: "",
  notes: "",
  payment_method: "cash",
  due_date: "",
  items: [newLine()],
});
export function draftFromPurchase(p: Detail): Draft {
  return {
    purchase_date: p.purchase_date,
    channel: p.channel,
    seller_contact_id: p.seller_contact_id ?? "",
    seller_company_id: p.seller_company_id ?? "",
    source_company_id: p.source_company_id ?? "",
    source_wholesaler_id: p.source_wholesaler_id ?? "",
    source_type: p.source_type,
    source: p.source_snapshot,
    invoice_number: p.invoice_number ?? "",
    receipt_number: p.receipt_number ?? "",
    notes: p.notes ?? "",
    payment_method: p.payment_method,
    due_date: p.due_date ?? "",
    items: p.items.map((i) => ({
      ...i,
      master_product_id: i.master_product_id ?? "",
      inventory_item_id: i.inventory_item_id ?? "",
      product: i.product_snapshot,
      batches: i.batches.map((b) => ({
        ...b,
        batch_number: b.batch_number ?? "",
        expiry_date: b.expiry_date ?? "",
      })),
    })),
  };
}
export function validateDraft(d: Draft): string | null {
  if (!d.purchase_date || d.purchase_date > today())
    return "Choose a purchase date no later than today.";
  if (d.channel === "intermediary" && !d.seller_contact_id)
    return "Select the person who delivered or sold the medicines.";
  if (d.channel === "external_licensed" && !d.seller_company_id)
    return "Select the external supplier company.";
  if (d.source_type === "platform_wholesaler" && !d.source_wholesaler_id)
    return "Select the original registered wholesaler.";
  if (
    d.source_type !== "unknown" &&
    d.source_type !== "platform_wholesaler" &&
    !d.source_company_id &&
    !d.source.name?.trim()
  )
    return "Enter the original source name or choose Unknown.";
  if (!d.items.length) return "Add at least one medicine.";
  for (const i of d.items) {
    if (!i.product.name.trim()) return "Enter a product name or choose a catalogue product.";
    if (
      !Number.isSafeInteger(i.quantity) ||
      i.quantity <= 0 ||
      !Number.isFinite(i.unit_cost_ghs) ||
      i.unit_cost_ghs < 0
    )
      return "Enter valid quantities and costs.";
    if (
      !i.batches.length ||
      i.batches.some((b) => !Number.isSafeInteger(b.quantity) || b.quantity <= 0) ||
      i.batches.reduce((s, b) => s + b.quantity, 0) !== i.quantity
    )
      return "Batch quantities must add up to each product quantity.";
  }
  return null;
}
export const draftTotal = (d: Draft) =>
  d.items.reduce((s, i) => s + (i.quantity * Math.round(i.unit_cost_ghs * 100)) / 100, 0);
export function riskSignals(p: Detail): string[] {
  const s = p.signals;
  return [
    s.missing_source && "Original source could not be established.",
    s.missing_invoice && "Supporting invoice or purchase receipt missing.",
    s.incomplete_batches && "Batch information incomplete.",
    s.expired_batches && "Expired batches require review.",
    s.previous_unknown > 0 &&
      `Original source missing on ${s.previous_unknown} previous purchases.`,
    s.changed_source && "Original source differs from a previous transaction.",
    s.possible_duplicate && "Possible duplicate: same invoice, seller, date and amount.",
  ].filter((v): v is string => Boolean(v));
}
export function purchaseSheet(rows: Purchase[]): ReportExportSheet {
  return {
    name: "External procurement",
    headers: [
      "Reference",
      "Date",
      "Channel",
      "Seller / deliverer",
      "Original source",
      "Invoice",
      "Total GHS",
      "Paid GHS",
      "Return credit GHS",
      "Outstanding GHS",
      "Verification",
      "Review",
      "Received by",
      "Reviewed by",
    ],
    rows: rows.map((p) => [
      p.reference,
      p.purchase_date,
      CHANNELS[p.channel],
      p.seller_snapshot.name ?? "Unknown",
      p.source_snapshot.name ?? "Unknown",
      p.invoice_number ?? "",
      p.total_ghs,
      p.paid_ghs,
      p.credit_ghs,
      p.outstanding_ghs,
      p.verification_status,
      p.review_status,
      p.received_by,
      p.reviewed_by ?? "",
    ]),
  };
}
export function traceabilitySheets(p: Detail, pharmacy: string): ReportExportSheet[] {
  return [
    {
      name: "Goods received note",
      headers: ["Field", "Value"],
      rows: [
        ["Pharmacy / workspace", pharmacy],
        ["Reference", p.reference],
        ["Date", p.purchase_date],
        ["Seller / deliverer", p.seller_snapshot.name ?? "Unknown"],
        ["Original source", p.source_snapshot.name ?? "Unknown"],
        ["Source details", JSON.stringify(p.source_snapshot)],
        ["Invoice", p.invoice_number ?? ""],
        ["Verification", p.verification_status],
        ["Review", p.review_status],
        ["Received by", p.received_name ?? p.received_by],
        ["Reviewed by", p.reviewed_name ?? p.reviewed_by ?? "Pending"],
        ["Review date", p.reviewed_at ?? ""],
        ["Review notes", p.review_notes ?? ""],
        ["Documents", p.documents.map((d) => d.filename).join(", ")],
        ["Received signature", "________________"],
        ["Reviewed signature", "________________"],
      ],
    },
    {
      name: "Products and batches",
      headers: [
        "Product",
        "Brand",
        "Strength",
        "Batch",
        "Expiry",
        "Received",
        "Remaining",
        "Consumed",
        "Returned / corrected",
        "Disposition",
        "Unit cost GHS",
      ],
      rows: p.items.flatMap((i) =>
        i.batches.map((b) => [
          i.product_snapshot.name,
          i.product_snapshot.brand ?? "",
          i.product_snapshot.strength ?? "",
          b.batch_number ?? "Unknown",
          b.expiry_date ?? "Unknown",
          b.quantity,
          b.remaining ?? 0,
          b.consumed ?? 0,
          b.returned ?? 0,
          b.disposition ?? "quarantine",
          i.unit_cost_ghs,
        ]),
      ),
    },
  ];
}
