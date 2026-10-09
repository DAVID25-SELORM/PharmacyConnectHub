import { describe, expect, it } from "vitest";
import {
  backorderBadge,
  backorderConsequence,
  backorderIsLive,
  canCancelShipment,
  draftQuantity,
  nextShipmentStep,
  shipmentDraft,
  shipmentDraftTotals,
  shipmentPayload,
  shipmentPrintable,
  shipmentSummary,
  validateShipmentDraft,
  type BackorderLine,
  type BackorderState,
  type Shipment,
} from "./order-backorder";
import type { PrintableOrder } from "@/components/order-print";

const state = (overrides: Partial<BackorderState> = {}): BackorderState => ({
  status: "open",
  backordered: 11,
  outstanding: 11,
  planned: 0,
  sent: 0,
  cancelled: 0,
  ...overrides,
});

const lines: BackorderLine[] = [
  {
    order_item_id: "a",
    product_name: "BO A",
    unit_price_ghs: 100,
    backordered: 3,
    sent: 0,
    planned: 0,
    cancelled: 0,
    outstanding: 3,
  },
  {
    order_item_id: "b",
    product_name: "BO B",
    unit_price_ghs: 50,
    backordered: 8,
    sent: 8,
    planned: 0,
    cancelled: 0,
    outstanding: 0,
  },
  {
    order_item_id: "c",
    product_name: "BO C",
    unit_price_ghs: 20,
    backordered: 5,
    sent: 0,
    planned: 0,
    cancelled: 0,
    outstanding: 5,
  },
];

describe("back-order status wording", () => {
  it("says what is still to come", () => {
    expect(backorderBadge(state())).toBe("Back-order open: 11 units to come");
    expect(
      backorderBadge(state({ status: "partially_fulfilled", outstanding: 1, planned: 0 })),
    ).toBe("Back-order partly sent: 1 unit to come");
    expect(backorderBadge(state({ status: "fulfilled", outstanding: 0 }))).toBe(
      "Back-order fulfilled",
    );
    expect(backorderBadge(state({ status: "none", backordered: 0, outstanding: 0 }))).toBeNull();
    expect(backorderBadge(null)).toBeNull();
  });

  it("is live while something is waiting or planned", () => {
    expect(backorderIsLive(state())).toBe(true);
    expect(backorderIsLive(state({ outstanding: 0, planned: 2 }))).toBe(true);
    expect(backorderIsLive(state({ status: "fulfilled", outstanding: 0, planned: 0 }))).toBe(false);
    expect(backorderIsLive(null)).toBe(false);
  });
});

describe("shipment steps", () => {
  it("walks pending to packed to dispatched to delivered, then stops", () => {
    expect(nextShipmentStep("pending")?.to).toBe("packed");
    expect(nextShipmentStep("packed")?.to).toBe("dispatched");
    expect(nextShipmentStep("dispatched")?.to).toBe("delivered");
    expect(nextShipmentStep("delivered")).toBeNull();
    expect(nextShipmentStep("cancelled")).toBeNull();
  });

  it("can be cancelled only before it goes out", () => {
    expect(canCancelShipment("pending")).toBe(true);
    expect(canCancelShipment("packed")).toBe(true);
    expect(canCancelShipment("dispatched")).toBe(false);
    expect(canCancelShipment("delivered")).toBe(false);
  });
});

describe("preparing a shipment", () => {
  it("offers only the products with something waiting", () => {
    expect(shipmentDraft(lines).map((line) => line.product_name)).toEqual(["BO A", "BO C"]);
  });

  it("totals units and money at the agreed prices", () => {
    const draft = shipmentDraft(lines).map((line) => ({
      ...line,
      quantity: line.order_item_id === "a" ? "2" : "3",
    }));
    expect(shipmentDraftTotals(draft)).toEqual({ units: 5, amount: 260 });
  });

  it("refuses more than is waiting, fractions and an empty shipment", () => {
    const draft = shipmentDraft(lines);
    expect(validateShipmentDraft(draft)).toMatch(/at least one product/);
    expect(validateShipmentDraft(draft.map((line) => ({ ...line, quantity: "9" })))).toMatch(
      /waiting to be shipped/,
    );
    expect(validateShipmentDraft(draft.map((line) => ({ ...line, quantity: "1.5" })))).toMatch(
      /whole number/,
    );
    expect(validateShipmentDraft(draft.map((line) => ({ ...line, quantity: "1" })))).toBeNull();
    expect(draftQuantity({ ...draft[0], quantity: "" })).toBe(0);
  });

  it("sends only the lines with a quantity", () => {
    const draft = shipmentDraft(lines).map((line) => ({
      ...line,
      quantity: line.order_item_id === "a" ? "2" : "",
    }));
    expect(shipmentPayload(draft)).toEqual([{ order_item_id: "a", quantity: 2 }]);
  });
});

describe("wording and printing", () => {
  const shipment: Shipment = {
    id: "s",
    sequence: 2,
    status: "packed",
    amount: 350,
    note: null,
    created_at: "2026-10-09T10:00:00Z",
    packed_at: null,
    dispatched_at: null,
    delivered_at: null,
    cancelled_at: null,
    cancel_reason: null,
    credit_due_date: "2026-11-10",
    lines: [
      { order_item_id: "a", product_name: "BO A", quantity: 2, unit_price_ghs: 100 },
      { order_item_id: "b", product_name: "BO B", quantity: 3, unit_price_ghs: 50 },
    ],
  };

  it("summarises a shipment", () => {
    expect(shipmentSummary(shipment)).toBe("5 units · GH₵ 350.00");
  });

  it("explains accepting with a back-order in terms of the invoice", () => {
    const text = backorderConsequence(-700);
    expect(text).toMatch(/credit note for GH₵ 700\.00/);
    expect(text).toMatch(/invoiced separately/);
  });

  it("prints a shipment as its own document: own number, own lines, own total, no fee or discount", () => {
    const order = {
      order_number: "ORD-1",
      created_at: "2026-10-01T00:00:00Z",
      total_ghs: 2000,
      effective_total_ghs: 1300,
      subtotal_ghs: 2000,
      discount_amount_ghs: 60,
      delivery_fee_ghs: 50,
      status: "delivered",
      payment_status: "unpaid",
      order_items: [
        { product_name: "BO A", quantity: 10, supplied_quantity: 7, unit_price_ghs: 100 },
      ],
    } as PrintableOrder;
    const printable = shipmentPrintable(order, shipment);
    expect(printable.order_number).toBe("ORD-1-B2");
    expect(printable.total_ghs).toBe(350);
    expect(printable.effective_total_ghs).toBeNull();
    expect(printable.discount_amount_ghs).toBe(0);
    expect(printable.delivery_fee_ghs).toBe(0);
    expect(printable.order_items.map((item) => item.quantity)).toEqual([2, 3]);
    expect(printable.credit_due_date).toBe("2026-11-10");
  });
});
