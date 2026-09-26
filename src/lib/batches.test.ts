import { describe, expect, it } from "vitest";
import { expiryText, pickSummary, validateBatchInput, type OrderPickLine } from "./batches";

describe("batch helpers", () => {
  it("describes days to expiry", () => {
    expect(expiryText(-3)).toBe("Expired 3 days ago");
    expect(expiryText(-1)).toBe("Expired 1 day ago");
    expect(expiryText(0)).toBe("Expires today");
    expect(expiryText(1)).toBe("1 day left");
    expect(expiryText(45)).toBe("45 days left");
  });

  it("validates a receive-batch form", () => {
    const ok = {
      productId: "p",
      batchNumber: "B1",
      expiryDate: "2027-01-01",
      quantity: "10",
      today: "2026-09-26",
    };
    expect(validateBatchInput(ok)).toBeNull();
    expect(validateBatchInput({ ...ok, productId: "" })).toMatch(/product/);
    expect(validateBatchInput({ ...ok, batchNumber: "  " })).toMatch(/batch number/);
    expect(validateBatchInput({ ...ok, expiryDate: "" })).toMatch(/expiry/);
    expect(validateBatchInput({ ...ok, expiryDate: "2026-09-25" })).toMatch(/already expired/);
    expect(validateBatchInput({ ...ok, quantity: "0" })).toMatch(/quantity/);
    expect(validateBatchInput({ ...ok, quantity: "2.5" })).toMatch(/quantity/);
  });

  it("summarises picks", () => {
    const line: OrderPickLine = {
      order_item_id: "i",
      product_name: "Amox",
      quantity_needed: 12,
      allocated: false,
      shortfall: 0,
      picks: [
        { batch_id: "a", batch_number: "B0", expiry_date: "2026-10-06", quantity: 5 },
        { batch_id: "b", batch_number: "B1", expiry_date: "2026-11-05", quantity: 7 },
      ],
    };
    expect(pickSummary(line)).toBe("5 × B0 (exp 2026-10-06), 7 × B1 (exp 2026-11-05)");
    expect(pickSummary({ ...line, picks: [] })).toBe("No batch stock recorded");
  });
});
