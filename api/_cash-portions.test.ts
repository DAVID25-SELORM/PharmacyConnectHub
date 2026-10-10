import { describe, expect, it } from "vitest";
import { portionReceiptPayload, type PortionReceipt } from "./_cash-portions";

const order = {
  id: "o1",
  order_number: "ORD-1",
  payment_method: "cod" as const,
  pharmacy: { owner_id: "u1", name: "Good Pharmacy", city: "Accra", region: "Greater Accra" },
  wholesaler: { name: "Alpha Wholesale", city: "Kumasi", region: "Ashanti" },
};

const receipt = (overrides: Partial<PortionReceipt> = {}): PortionReceipt => ({
  collection_id: "c1",
  order_number: "ORD-1",
  total_ghs: "1300.00",
  delivery_fee_ghs: "50.00",
  delivered_at: "2026-10-09T10:00:00Z",
  paid_at: "2026-10-09T12:00:00Z",
  receipt_sent_at: null,
  receipt_sent_to: null,
  items: [
    { product_name: "BO A", quantity: 6, unit_price_ghs: "100.00" },
    { product_name: "BO B", quantity: 14, unit_price_ghs: 50 },
  ],
  ...overrides,
});

describe("receipt for one collected portion", () => {
  it("shows the portion's own lines and amount", () => {
    const payload = portionReceiptPayload(order, receipt());
    expect(payload.totalGhs).toBe(1300);
    expect(payload.deliveryFeeGhs).toBe(50);
    expect(payload.items).toEqual([
      { productName: "BO A", quantity: 6, unitPriceGhs: 100 },
      { productName: "BO B", quantity: 14, unitPriceGhs: 50 },
    ]);
    expect(payload.paymentMethod).toBe("cod");
    expect(payload.parties.wholesaler.name).toBe("Alpha Wholesale");
  });

  it("a shipment's receipt carries its own label, no delivery fee and its own date", () => {
    const payload = portionReceiptPayload(
      order,
      receipt({
        order_number: "ORD-1 (shipment 2)",
        total_ghs: 400,
        delivery_fee_ghs: 0,
        items: [{ product_name: "BO A", quantity: 4, unit_price_ghs: 100 }],
      }),
    );
    expect(payload.orderNumber).toBe("ORD-1 (shipment 2)");
    expect(payload.orderId).toBe("o1");
    expect(payload.totalGhs).toBe(400);
    expect(payload.deliveryFeeGhs).toBe(0);
    expect(payload.items).toHaveLength(1);
  });

  it("leaves out a line with nothing on it and copes with a missing delivery fee", () => {
    const payload = portionReceiptPayload(
      order,
      receipt({
        delivery_fee_ghs: null,
        items: [
          { product_name: "BO A", quantity: 0, unit_price_ghs: 100 },
          { product_name: "BO B", quantity: 2, unit_price_ghs: 50 },
        ],
      }),
    );
    expect(payload.deliveryFeeGhs).toBe(0);
    expect(payload.items.map((item) => item.productName)).toEqual(["BO B"]);
  });
});
