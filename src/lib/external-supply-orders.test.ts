import { describe, expect, it } from "vitest";
import {
  receiptFromSupplyOrder,
  supplyStatus,
  validateSupplyDraft,
  type SupplyOrder,
  type SupplyReceipt,
} from "./external-supply-orders";
import { buildSupplyOrderPdf } from "./external-supply-order-pdf";
const order: SupplyOrder = {
  id: "order",
  pharmacy_id: "pharmacy",
  reference: "EPO-TEST",
  kind: "order",
  status: "issued",
  version: 2,
  created_at: "2026-10-11",
  issued_at: "2026-10-11",
  issuer: { name: "Test Pharmacy" },
  data: {
    kind: "order",
    supplier: "Supplier",
    supplier_contact: "",
    required_date: "",
    delivery_address: "",
    notes: "",
    lines: [
      {
        id: "line",
        name: "Medicine 500mg pack 10",
        specification: "",
        quantity: 20,
        unit_price: 5,
      },
    ],
  },
};
describe("external purchase order workflow", () => {
  it("prepares only outstanding packs without treating the supplier as a verified source", () => {
    const receipts: SupplyReceipt[] = [
      {
        id: "r",
        reference: "EXT",
        review_status: "draft",
        external_order_allocations: [
          { line_id: "line", product_name: "Medicine 500mg pack 10", quantity: 12 },
        ],
      },
    ];
    const draft = receiptFromSupplyOrder(order, receipts);
    expect(draft.items[0].quantity).toBe(8);
    expect(draft.items[0].batches[0].quantity).toBe(8);
    expect(draft.external_order_id).toBe(order.id);
    expect(draft.source_type).toBe("unknown");
    expect(supplyStatus(order, receipts)).toBe("partially received");
    receipts[0].external_order_allocations[0].quantity = 20;
    expect(supplyStatus(order, receipts)).toBe("received");
    expect(receiptFromSupplyOrder(order, receipts).items).toEqual([]);
    expect(supplyStatus({ ...order, status: "cancelled" }, receipts)).toBe("cancelled");
  });
  it("rejects invalid quantities, prices and ambiguous duplicate medicine names", () => {
    expect(validateSupplyDraft(order.data)).toBeNull();
    for (const quantity of [0, -1, 1.5, Infinity])
      expect(
        validateSupplyDraft({ ...order.data, lines: [{ ...order.data.lines[0], quantity }] }),
      ).toBeTruthy();
    expect(
      validateSupplyDraft({
        ...order.data,
        lines: [...order.data.lines, { ...order.data.lines[0], id: "different" }],
      }),
    ).toBeTruthy();
    expect(
      validateSupplyDraft({
        ...order.data,
        lines: [{ ...order.data.lines[0], unit_price: 1.001 }],
      }),
    ).toBeTruthy();
  });
  it("requires an issued snapshot and renders a multipage order with all items", () => {
    expect(() => buildSupplyOrderPdf({ ...order, issued_at: null })).toThrow();
    const large = {
      ...order,
      data: {
        ...order.data,
        lines: Array.from({ length: 90 }, (_, i) => ({
          ...order.data.lines[0],
          id: String(i),
          name: `Medicine ${i} with long strength and pack description`,
          specification:
            "Manufacturer and packaging requirements repeated across a multi-page order.",
        })),
      },
    };
    const pdf = buildSupplyOrderPdf(large);
    expect(pdf.getNumberOfPages()).toBeGreaterThan(2);
    const output = pdf.output();
    expect(output).toContain("Medicine 89");
    expect(output).toContain("EPO-TEST");
    expect(output).toContain("9000.00");
  });
});
