import { describe, expect, it } from "vitest";
import { locationFor, sortPrintableItems } from "./order-print";

describe("order print data", () => {
  it("sorts located items before unassigned items", () => {
    const result = sortPrintableItems([
      { product_name: "No location", quantity: 1 },
      {
        product_name: "Shelf B",
        quantity: 1,
        product: { zone: "A", rack: "03", shelf: "02", bin: "B" },
      },
      { product_name: "Shelf A", quantity: 1, location: "A-01-01-A" },
    ]);
    expect(result.map((item) => item.product_name)).toEqual(["Shelf A", "Shelf B", "No location"]);
    expect(locationFor(result[2])).toBe("");
  });

  it("supports explicit UNASSIGNED display without inventing a location", () => {
    expect(locationFor({ product_name: "Legacy stock", quantity: 2 })).toBe("");
  });
});
