import { describe, expect, it } from "vitest";
import {
  decisionCredit,
  decisionSummary,
  decisionsPayload,
  discrepancies,
  draftHasProblem,
  draftReceived,
  liveReport,
  outcomesFor,
  reportDraft,
  reportPayload,
  reportSummary,
  validateDecisions,
  validateReportDraft,
  withinReportWindow,
  type DeliveryReport,
  type ExpectedLine,
} from "./delivery-report";

const expected: ExpectedLine[] = [
  { order_item_id: "a", product_name: "BO A", quantity: 10, unit_price_ghs: 100 },
  { order_item_id: "b", product_name: "BO B", quantity: 20, unit_price_ghs: 50 },
];

const report = (overrides: Partial<DeliveryReport> = {}): DeliveryReport => ({
  id: "r1",
  shipment_id: null,
  status: "submitted",
  note: null,
  submitted_at: "2026-10-09T10:00:00Z",
  submitted_by_label: "po@x.test",
  resolved_at: null,
  resolved_by_label: null,
  resolution_note: null,
  credit_total: 0,
  lines: [
    {
      id: "la",
      order_item_id: "a",
      product_name: "BO A",
      unit_price_ghs: 100,
      expected: 10,
      received: 8,
      missing: 2,
      damaged: 0,
      rejected: 0,
      reason: "short",
    },
    {
      id: "lb",
      order_item_id: "b",
      product_name: "BO B",
      unit_price_ghs: 50,
      expected: 20,
      received: 15,
      missing: 0,
      damaged: 4,
      rejected: 1,
      reason: "crushed",
    },
  ],
  decisions: [],
  ...overrides,
});

describe("the pharmacy's draft", () => {
  it("starts as received in full", () => {
    const draft = reportDraft(expected);
    expect(draftHasProblem(draft)).toBe(false);
    expect(draftReceived(draft[0])).toBe(10);
    expect(reportPayload(draft)).toEqual([]);
  });

  it("works out what was received and sends only the lines with a problem", () => {
    const draft = reportDraft(expected).map((line) =>
      line.order_item_id === "b"
        ? { ...line, damaged: "4", rejected: "1", reason: " crushed " }
        : line,
    );
    expect(draftReceived(draft[1])).toBe(15);
    expect(draftHasProblem(draft)).toBe(true);
    expect(reportPayload(draft)).toEqual([
      { order_item_id: "b", missing: 0, damaged: 4, rejected: 1, reason: "crushed" },
    ]);
  });

  it("refuses non-numbers, more than was delivered, and a problem without a reason", () => {
    const base = reportDraft(expected);
    expect(validateReportDraft(base)).toBeNull();
    expect(validateReportDraft(base.map((l) => ({ ...l, missing: "1.5" })))).toMatch(
      /whole numbers/,
    );
    expect(validateReportDraft(base.map((l) => ({ ...l, missing: "11", reason: "x1x" })))).toMatch(
      /more than the 10 delivered/,
    );
    expect(validateReportDraft(base.map((l) => ({ ...l, missing: "1" })))).toMatch(
      /Say what went wrong/,
    );
    expect(
      validateReportDraft(base.map((l) => ({ ...l, missing: "1", reason: "lost" }))),
    ).toBeNull();
  });
});

describe("the wholesaler's decisions", () => {
  it("lists one entry per discrepancy", () => {
    const items = discrepancies(report());
    expect(items.map((item) => `${item.product_name}:${item.kind}:${item.quantity}`)).toEqual([
      "BO A:missing:2",
      "BO B:damaged:4",
      "BO B:rejected:1",
    ]);
  });

  it("only offers returns for goods that exist", () => {
    expect(outcomesFor("missing")).toEqual(["credit", "reject"]);
    expect(outcomesFor("damaged")).toEqual(["return", "credit", "reject"]);
  });

  it("adds up what would be credited at the agreed prices", () => {
    const items = discrepancies(report());
    expect(
      decisionCredit(items, {
        "la:missing": "credit",
        "lb:damaged": "return",
        "lb:rejected": "credit",
      }),
    ).toBe(250);
  });

  it("needs every discrepancy decided and a note for a rejection", () => {
    const items = discrepancies(report());
    expect(validateDecisions(items, { "la:missing": "credit" }, "")).toMatch(/Choose what to do/);
    expect(
      validateDecisions(
        items,
        { "la:missing": "reject", "lb:damaged": "return", "lb:rejected": "credit" },
        " ",
      ),
    ).toMatch(/Explain to the pharmacy/);
    expect(
      validateDecisions(
        items,
        { "la:missing": "reject", "lb:damaged": "return", "lb:rejected": "credit" },
        "waybill signed",
      ),
    ).toBeNull();
  });

  it("sends the decisions the database expects", () => {
    const items = discrepancies(report());
    expect(
      decisionsPayload(items, {
        "la:missing": "credit",
        "lb:damaged": "return",
        "lb:rejected": "credit",
      })[1],
    ).toEqual({
      line_id: "lb",
      kind: "damaged",
      outcome: "return",
    });
  });
});

describe("finding and wording a report", () => {
  it("finds the live report for a delivery and ignores withdrawn or disputed ones", () => {
    const reports = [
      report({ id: "old", status: "withdrawn" }),
      report({ id: "dispute", status: "disputed" }),
      report({ id: "live", status: "resolved" }),
      report({ id: "other", shipment_id: "s2", status: "submitted" }),
    ];
    expect(liveReport(reports, null)?.id).toBe("live");
    expect(liveReport(reports, "s2")?.id).toBe("other");
    expect(liveReport(reports.slice(0, 2), null)).toBeNull();
  });

  it("is open for 30 days after delivery", () => {
    const delivered = "2026-10-01T00:00:00Z";
    expect(withinReportWindow(delivered, new Date("2026-10-30T00:00:00Z").getTime())).toBe(true);
    expect(withinReportWindow(delivered, new Date("2026-11-02T00:00:00Z").getTime())).toBe(false);
    expect(withinReportWindow(null)).toBe(true);
  });

  it("describes the claim and the outcome", () => {
    expect(reportSummary(report())).toBe("2 missing BO A, 4 damaged BO B, 1 rejected BO B");
    expect(reportSummary(report({ status: "received_in_full" }))).toMatch(/everything arrived/);
    expect(decisionSummary(report({ status: "submitted" }))).toBeNull();
    expect(decisionSummary(report({ status: "disputed" }))).toMatch(/did not accept/);
    expect(
      decisionSummary(
        report({
          status: "resolved",
          credit_total: 250,
          decisions: [
            {
              line_id: "la",
              kind: "missing",
              quantity: 2,
              outcome: "credit",
              amount: 200,
              return_number: null,
            },
            {
              line_id: "lb",
              kind: "damaged",
              quantity: 4,
              outcome: "return",
              amount: 0,
              return_number: "RET-001001",
            },
          ],
        }),
      ),
    ).toBe("GH₵ 250.00 credited; goods to be returned (RET-001001)");
  });
});
