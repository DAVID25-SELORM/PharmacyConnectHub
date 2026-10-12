// Disconnected browser fixture. Never makes a database or production request.
const orders = [
  {
    id: "sample-order",
    pharmacy_id: "fixture",
    reference: "EPO-SAMPLE",
    kind: "order",
    status: "issued",
    version: 2,
    issued_at: "2026-10-11",
    issuer: { name: "Sample Pharmacy" },
    data: {
      kind: "order",
      supplier: "Example External Supplier",
      supplier_contact: "Example contact",
      required_date: "2026-11-01",
      delivery_address: "Sample pharmacy receiving desk",
      notes: "Sample only. Confirm pack size and expiry before receiving.",
      lines: [
        {
          id: "line",
          name: "Sample medicine 500mg pack 10",
          specification: "Original sealed packaging",
          quantity: 20,
          unit_price: 5,
        },
      ],
    },
  },
];
const receipts = [
  {
    id: "sample-receipt",
    reference: "EXT-SAMPLE",
    review_status: "draft",
    external_order_allocations: [
      { line_id: "line", product_name: "Sample medicine 500mg pack 10", quantity: 12 },
    ],
  },
];
export const supabase = {
  from(table: string) {
    const filters: Record<string, string> = {};
    let single = false;
    const result = () => {
      const data =
        table === "external_supply_orders"
          ? orders.filter((o) => !filters.id || o.id === filters.id)
          : table === "external_purchases"
            ? filters.external_order_id === "sample-order"
              ? receipts
              : []
            : [];
      return { data: single ? data[0] : data, error: null, count: data.length };
    };
    const q = {
      select: () => q,
      eq: (k: string, v: string) => {
        filters[k] = v;
        return q;
      },
      neq: () => q,
      limit: () => q,
      order: () => q,
      range: () => q,
      single: () => {
        single = true;
        return Promise.resolve(result());
      },
      then: (fn: (r: unknown) => unknown) => Promise.resolve(result()).then(fn),
    };
    return q;
  },
  async rpc(name: string, args: Record<string, any>) {
    if (["search_procurement_catalogue", "procurement_suppliers", "procurement_document_report"].includes(name)) return { data: [], error: null };
    if (name === "transition_external_supply_order") {
      const o = orders.find((o) => o.id === args.p_id)!;
      o.status = args.p_action;
      o.version++;
      if (args.p_action === "issued") o.issued_at = "2026-10-11";
      return { data: null, error: null };
    }
    if (name === "save_external_supply_order") {
      const id = args.p_id || crypto.randomUUID();
      const existing = orders.find((o) => o.id === id);
      if (existing) {
        existing.data = args.p_data;
        existing.version++;
      } else
        orders.push({
          ...orders[0],
          id,
          reference: "EPO-NEW-SAMPLE",
          data: args.p_data,
          kind: args.p_data.kind,
          status: "draft",
          version: 1,
          issued_at: "",
        });
      return { data: id, error: null };
    }
    return { data: null, error: { message: "Unsupported fixture action" } };
  },
};
