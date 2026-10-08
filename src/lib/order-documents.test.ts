import { describe, expect, it } from "vitest";
import {
  canPrintInvoice,
  documentTotals,
  isAmended,
  lineAmount,
  lineDiscount,
  partyLines,
  paymentTermsLine,
  suppliedQuantity,
} from "./order-documents";

const date = (iso: string) => `D(${iso})`;

describe("documentTotals", () => {
  it("uses the stored delivery fee and splits subtotal, discount, delivery and total", () => {
    expect(
      documentTotals({
        total_ghs: "1090.00",
        subtotal_ghs: "1100.00",
        discount_amount_ghs: "60.00",
        delivery_fee_ghs: "50.00",
      }),
    ).toEqual({
      subtotal: 1100,
      discount: 60,
      delivery: 50,
      total: 1090,
      amended: false,
      originalTotal: 1090,
    });
  });

  it("works the delivery fee out of an older order that did not store one", () => {
    expect(
      documentTotals({ total_ghs: 1090, subtotal_ghs: 1100, discount_amount_ghs: 60 }).delivery,
    ).toBe(50);
    expect(
      documentTotals({ total_ghs: 1000, subtotal_ghs: 1000, discount_amount_ghs: 0 }).delivery,
    ).toBe(0);
  });

  it("never reports a negative delivery fee", () => {
    expect(
      documentTotals({ total_ghs: 900, subtotal_ghs: 1000, discount_amount_ghs: 0 }).delivery,
    ).toBe(0);
  });

  it("shows only the total when the order has no stored subtotal", () => {
    expect(documentTotals({ total_ghs: 250 })).toEqual({
      subtotal: null,
      discount: 0,
      delivery: null,
      total: 250,
      amended: false,
      originalTotal: 250,
    });
  });

  it("treats a stored zero fee as zero, not as missing", () => {
    expect(
      documentTotals({ total_ghs: 100, subtotal_ghs: 100, delivery_fee_ghs: 0 }).delivery,
    ).toBe(0);
  });
});

describe("amended orders", () => {
  it("shows the goods as supplied, the unchanged delivery fee and the effective total", () => {
    // Ordered 10 @ 100 + 20 @ 50 + 5 @ 20 = 2100, plus a 50 delivery fee = 2150; 550 taken off by agreement.
    expect(
      documentTotals({
        total_ghs: 2150,
        effective_total_ghs: 1600,
        subtotal_ghs: 2100,
        discount_amount_ghs: 0,
        delivery_fee_ghs: 50,
      }),
    ).toEqual({
      subtotal: 1550,
      discount: 0,
      delivery: 50,
      total: 1600,
      amended: true,
      originalTotal: 2150,
    });
  });

  it("drops the order-level discount row, because that discount was granted on the quantities first ordered", () => {
    const totals = documentTotals({
      total_ghs: 1090,
      effective_total_ghs: 790,
      subtotal_ghs: 1100,
      discount_amount_ghs: 60,
      delivery_fee_ghs: 50,
    });
    expect(totals.discount).toBe(0);
    expect(totals.subtotal).toBe(740);
    expect(totals.subtotal! + totals.delivery!).toBe(totals.total);
  });

  it("an order that was never amended is described exactly as before", () => {
    expect(
      documentTotals({ total_ghs: 100, effective_total_ghs: null, subtotal_ghs: 100 }).amended,
    ).toBe(false);
  });

  it("lines are priced on what is supplied", () => {
    expect(lineAmount({ quantity: 10, supplied_quantity: 7, unit_price_ghs: 100 })).toBe(700);
    expect(lineAmount({ quantity: 10, unit_price_ghs: 100 })).toBe(1000);
    expect(suppliedQuantity({ quantity: 10, supplied_quantity: 0 })).toBe(0);
    expect(suppliedQuantity({ quantity: 10 })).toBe(10);
  });

  it("recognises an amended order by its effective total or by a changed line", () => {
    expect(isAmended({ effective_total_ghs: 5 })).toBe(true);
    expect(isAmended({}, [{ quantity: 10, supplied_quantity: 8 }])).toBe(true);
    expect(
      isAmended({ effective_total_ghs: null }, [{ quantity: 10, supplied_quantity: 10 }]),
    ).toBe(false);
    expect(isAmended({})).toBe(false);
  });
});

describe("line amounts", () => {
  it("multiplies the price charged by the quantity and rounds to the pesewa", () => {
    expect(lineAmount({ quantity: 3, unit_price_ghs: "33.33" })).toBe(99.99);
    expect(lineAmount({ quantity: 7, unit_price_ghs: 0.1 })).toBe(0.7);
    expect(lineAmount({ quantity: 2, unit_price_ghs: null })).toBe(0);
  });

  it("reports a discount only when the price charged is below the list price", () => {
    expect(
      lineDiscount({ quantity: 1, unit_price_ghs: "90.00", base_unit_price_ghs: "100.00" }),
    ).toEqual({
      listPrice: 100,
      saving: 10,
    });
    expect(lineDiscount({ quantity: 1, unit_price_ghs: 100, base_unit_price_ghs: 100 })).toBeNull();
    expect(lineDiscount({ quantity: 1, unit_price_ghs: 100 })).toBeNull();
    expect(lineDiscount({ quantity: 1, unit_price_ghs: 120, base_unit_price_ghs: 100 })).toBeNull();
  });
});

describe("paymentTermsLine", () => {
  it("states credit with its terms and due date", () => {
    expect(
      paymentTermsLine(
        {
          total_ghs: 1,
          settlement_method: "credit",
          credit_terms_days: 30,
          credit_due_date: "2026-11-12",
          payment_status: "unpaid",
        },
        date,
      ),
    ).toBe("Credit · 30 days · due D(2026-11-12) · payment pending");
  });

  it("says the clock starts on delivery, and that the date is set then, until the order is delivered", () => {
    expect(
      paymentTermsLine(
        {
          total_ghs: 1,
          settlement_method: "credit",
          credit_due_basis: "delivery_date",
          credit_terms_days: 30,
          credit_due_date: null,
          payment_status: "unpaid",
        },
        date,
      ),
    ).toBe("Credit · 30 days after delivery · due date set on delivery · payment pending");
    expect(
      paymentTermsLine(
        {
          total_ghs: 1,
          settlement_method: "credit",
          credit_due_basis: "delivery_date",
          credit_terms_days: 30,
          credit_due_date: "2026-11-12",
          payment_status: "unpaid",
        },
        date,
      ),
    ).toBe("Credit · 30 days after delivery · due D(2026-11-12) · payment pending");
  });

  it("does not show a due date for a non-credit order", () => {
    expect(
      paymentTermsLine(
        {
          total_ghs: 1,
          settlement_method: "bank_transfer",
          credit_due_date: "2026-11-12",
          payment_status: "paid",
        },
        date,
      ),
    ).toBe("Bank transfer · paid");
  });

  it("falls back for orders placed before settlement methods existed", () => {
    expect(
      paymentTermsLine(
        { total_ghs: 1, is_credit_order: true, credit_due_date: "2026-01-02" },
        date,
      ),
    ).toBe("Credit · due D(2026-01-02) · payment pending");
    expect(
      paymentTermsLine({ total_ghs: 1, payment_method: "cod", payment_status: "unpaid" }, date),
    ).toBe("Cash on delivery · payment pending");
  });

  it("says when a payment failed or was refunded", () => {
    expect(
      paymentTermsLine({ total_ghs: 1, settlement_method: "cod", payment_status: "failed" }, date),
    ).toBe("Cash on delivery · payment failed");
    expect(
      paymentTermsLine(
        { total_ghs: 1, settlement_method: "cod", payment_status: "refunded" },
        date,
      ),
    ).toBe("Cash on delivery · refunded");
  });
});

describe("invoice availability", () => {
  it("is issued for any order that stands, not a cancelled one", () => {
    expect(canPrintInvoice({ status: "pending" })).toBe(true);
    expect(canPrintInvoice({ status: "delivered" })).toBe(true);
    expect(canPrintInvoice({ status: "cancelled" })).toBe(false);
  });
});

describe("partyLines", () => {
  it("lists what is known and skips blanks", () => {
    expect(
      partyLines({
        name: "Alpha Wholesale",
        address: " 12 Ring Road ",
        city: "Accra",
        region: "Greater Accra",
        phone: "+233241000000",
        license_number: "WH-123",
      }),
    ).toEqual(["12 Ring Road", "Accra, Greater Accra", "Tel: +233241000000", "Licence: WH-123"]);
    expect(partyLines({ name: "Only name", city: "Kumasi", region: "  " })).toEqual(["Kumasi"]);
    expect(partyLines(null)).toEqual([]);
  });
});
