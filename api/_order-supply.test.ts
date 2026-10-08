import { describe, expect, it } from "vitest";
import { receiptFigures } from "./_order-supply";

const order = {
  total_ghs: 2150,
  subtotal_ghs: 2100,
  discount_amount_ghs: 0,
  order_items: [
    { id: "a", product_name: "PF A", quantity: 10, unit_price_ghs: "100.00" },
    { id: "b", product_name: "PF B", quantity: 20, unit_price_ghs: "50.00" },
    { id: "c", product_name: "PF C", quantity: 5, unit_price_ghs: "20.00" },
  ],
};

describe("receipt figures", () => {
  it("an order that was never amended is described as it was placed", () => {
    expect(receiptFigures(order, null)).toEqual({
      totalGhs: 2150,
      deliveryFeeGhs: 50,
      items: [
        { productName: "PF A", quantity: 10, unitPriceGhs: 100 },
        { productName: "PF B", quantity: 20, unitPriceGhs: 50 },
        { productName: "PF C", quantity: 5, unitPriceGhs: 20 },
      ],
    });
  });

  it("an amended order shows the supplied quantities and the effective total", () => {
    const figures = receiptFigures(order, {
      effective_total_ghs: "1600.00",
      delivery_fee_ghs: "50.00",
      lines: [
        { order_item_id: "a", product_name: "PF A", supplied_qty: 7 },
        { order_item_id: "b", product_name: "PF B", supplied_qty: 15 },
        { order_item_id: "c", product_name: "PF C", supplied_qty: 5 },
      ],
    });
    expect(figures.totalGhs).toBe(1600);
    expect(figures.deliveryFeeGhs).toBe(50);
    expect(figures.items.map((item) => item.quantity)).toEqual([7, 15, 5]);
    // The receipt adds up: goods as supplied + delivery fee = total.
    const goods = figures.items.reduce((sum, item) => sum + item.quantity * item.unitPriceGhs, 0);
    expect(goods + figures.deliveryFeeGhs).toBe(figures.totalGhs);
  });

  it("leaves out a line that is no longer supplied at all", () => {
    const figures = receiptFigures(order, {
      effective_total_ghs: 1100,
      delivery_fee_ghs: 50,
      lines: [
        { order_item_id: "a", product_name: "PF A", supplied_qty: 0 },
        { order_item_id: "b", product_name: "PF B", supplied_qty: 20 },
        { order_item_id: "c", product_name: "PF C", supplied_qty: 5 },
      ],
    });
    expect(figures.items.map((item) => item.productName)).toEqual(["PF B", "PF C"]);
  });

  it("uses the delivery fee implied by the placed order when none is stored", () => {
    const figures = receiptFigures(order, {
      effective_total_ghs: 1600,
      delivery_fee_ghs: null,
      lines: [],
    });
    expect(figures.deliveryFeeGhs).toBe(50);
  });

  it("keeps an unmatched line at its ordered quantity rather than dropping it", () => {
    const figures = receiptFigures(order, {
      effective_total_ghs: 2150,
      delivery_fee_ghs: 50,
      lines: [],
    });
    expect(figures.items).toHaveLength(3);
    expect(figures.items[0].quantity).toBe(10);
  });
});
