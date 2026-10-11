import { describe, it, expect } from "vitest";
import {
  newDraft,
  validateDraft,
  draftTotal,
  draftFromPurchase,
  riskSignals,
  traceabilitySheets,
  purchaseSheet,
  type Detail,
} from "./external-procurement";

const receipt = (): Detail => ({
  id: "p1",
  reference: "EXT-1",
  purchase_date: "2026-01-01",
  channel: "intermediary",
  seller_contact_id: "seller",
  seller_company_id: null,
  source_company_id: null,
  source_wholesaler_id: null,
  source_type: "unknown",
  seller_snapshot: { name: "Kwame" },
  source_snapshot: {},
  total_ghs: 200,
  paid_ghs: 50,
  credit_ghs: 20,
  outstanding_ghs: 130,
  payment_status: "part_paid",
  payment_method: "cash",
  due_date: null,
  invoice_number: "INV-1",
  receipt_number: null,
  notes: null,
  review_status: "quarantined",
  verification_status: "unverified",
  received_by: "staff",
  reviewed_by: null,
  reviewed_at: null,
  review_notes: null,
  posted_at: null,
  version: 1,
  document_count: 0,
  quarantine_batches: 2,
  items: [
    {
      id: "i",
      master_product_id: "",
      inventory_item_id: "",
      product_snapshot: { name: "Medicine", strength: "500 mg" },
      quantity: 20,
      unit_cost_ghs: 10,
      batches: [
        {
          id: "a",
          batch_number: "A",
          expiry_date: "2028-01-01",
          quantity: 12,
          remaining: 10,
          disposition: "quarantine",
        },
        {
          id: "b",
          batch_number: "B",
          expiry_date: "2028-02-01",
          quantity: 8,
          remaining: 8,
          disposition: "quarantine",
        },
      ],
    },
  ],
  documents: [],
  events: [],
  payments: [],
  returns: [],
  signals: {
    missing_source: true,
    missing_invoice: true,
    incomplete_batches: false,
    expired_batches: false,
    previous_unknown: 4,
    changed_source: false,
    possible_duplicate: true,
  },
});

describe("external procurement", () => {
  it("requires the seller and treats source independently", () => {
    const d = newDraft();
    d.channel = "intermediary";
    expect(validateDraft(d)).toMatch(/person/);
    d.seller_contact_id = "s";
    expect(validateDraft(d)).toMatch(/original source/);
    d.source_type = "unknown";
    d.items[0].product.name = "Medicine";
    expect(validateDraft(d)).toBeNull();
  });
  it("balances quantities across batches and rejects invalid money", () => {
    const d = draftFromPurchase(receipt());
    expect(validateDraft(d)).toBeNull();
    d.items[0].batches[1].quantity = 9;
    expect(validateDraft(d)).toMatch(/add up/);
    d.items[0].batches[1].quantity = 8;
    d.items[0].unit_cost_ghs = NaN;
    expect(validateDraft(d)).toMatch(/cost/);
  });
  it("does not multiply the cost by the batch count", () => {
    expect(draftTotal(draftFromPurchase(receipt()))).toBe(200);
  });
  it("preserves local snapshot fields when editing", () => {
    expect(draftFromPurchase(receipt()).items[0].product.strength).toBe("500 mg");
  });
  it("reports neutral evidence and duplicate warnings", () => {
    const signals = riskSignals(receipt());
    expect(signals).toHaveLength(4);
    expect(signals.join(" ")).toContain("4 previous purchases");
    expect(signals.join(" ")).not.toMatch(/illegal|compliant/i);
  });
  it("exports the full traceability chain and both batches", () => {
    const sheets = traceabilitySheets(receipt(), "Real Pharmacy");
    expect(sheets[0].rows).toContainEqual(["Seller / deliverer", "Kwame"]);
    expect(sheets[0].rows).toContainEqual(["Original source", "Unknown"]);
    expect(sheets[1].rows).toHaveLength(2);
    expect(sheets[1].rows[0]).toContain("quarantine");
  });
  it("exports separate financial values without losing return credit", () => {
    const s = purchaseSheet([receipt()]);
    expect(s.rows[0].slice(6, 10)).toEqual([200, 50, 20, 130]);
  });
});
