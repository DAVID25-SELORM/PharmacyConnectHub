import { describe, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: {} }));

import { withSupply, type SupplyMap } from "./order-supply";

const order = {
  id: "o1",
  total_ghs: 2000,
  order_items: [
    { product_id: "pa", quantity: 10, unit_price_ghs: 100 },
    { product_id: "pb", quantity: 20, unit_price_ghs: 50 },
  ],
};

const supply = (lines: SupplyMap[string]["lines"], current = 2100): SupplyMap => ({
  o1: {
    order_id: "o1",
    current_total_ghs: current,
    main_total_ghs: current,
    has_open_amendment: false,
    backorder: null as never,
    lines,
  },
});

describe("withSupply and prices", () => {
  it("shows the price now in force and keeps the placed price beside it", () => {
    const result = withSupply(
      order,
      supply([
        {
          order_item_id: "a",
          product_id: "pa",
          ordered_qty: 10,
          supplied_qty: 10,
          unit_price_ghs: 120,
        },
        {
          order_item_id: "b",
          product_id: "pb",
          ordered_qty: 20,
          supplied_qty: 20,
          unit_price_ghs: 50,
        },
      ]),
    );
    expect(result.order_items[0]).toMatchObject({
      unit_price_ghs: 120,
      placed_unit_price_ghs: 100,
    });
    expect(result.order_items[1].unit_price_ghs).toBe(50);
    expect(result.order_items[1].placed_unit_price_ghs).toBeUndefined();
    expect(result.effective_total_ghs).toBe(2100);
  });

  it("leaves the price alone when the summary carries none (older summaries, unamended lines)", () => {
    const result = withSupply(
      order,
      supply([{ order_item_id: "a", product_id: "pa", ordered_qty: 10, supplied_qty: 8 }], 1800),
    );
    expect(result.order_items[0]).toMatchObject({ unit_price_ghs: 100, supplied_quantity: 8 });
  });

  it("an order that is not in the summary is returned as it is", () => {
    expect(withSupply(order, {})).toBe(order);
  });
});
