import { describe, expect, it } from "vitest";
import {
  REPORT_GROUPS,
  RFQ_TERM_LABELS,
  deadlineHint,
  paymentLabel,
  reportValue,
  statusTone,
} from "./rfq-format";

const NOW = Date.parse("2026-10-13T12:00:00Z");

describe("deadline hint", () => {
  it("says how long is left, in hours when it is close and days when it is not", () => {
    expect(deadlineHint("2026-10-13T15:00:00Z", NOW)).toBe("Closes in 3 hours");
    expect(deadlineHint("2026-10-13T12:20:00Z", NOW)).toBe("Closes in 1 hour");
    expect(deadlineHint("2026-10-16T12:00:00Z", NOW)).toBe("Closes in 3 days");
    expect(deadlineHint("2026-10-14T12:00:00Z", NOW)).toBe("Closes in 24 hours");
  });
  it("says how long ago it closed", () => {
    expect(deadlineHint("2026-10-13T09:00:00Z", NOW)).toBe("Closed 3 hours ago");
    expect(deadlineHint("2026-10-08T12:00:00Z", NOW)).toBe("Closed 5 days ago");
  });
  it("copes with no deadline", () => {
    expect(deadlineHint(null, NOW)).toBe("No deadline");
    expect(deadlineHint(undefined, NOW)).toBe("No deadline");
  });
});

describe("status colours", () => {
  it("groups statuses by what they mean", () => {
    expect(statusTone("completed")).toBe("success");
    expect(statusTone("confirmed")).toBe("success");
    expect(statusTone("open")).toBe("primary");
    expect(statusTone("partially_awarded")).toBe("warning");
    expect(statusTone("pending")).toBe("warning");
    expect(statusTone("cancelled")).toBe("danger");
    expect(statusTone("conversion_failed")).toBe("danger");
    expect(statusTone("draft")).toBe("muted");
    expect(statusTone("something_new")).toBe("muted");
  });
});

describe("report figures", () => {
  it("formats money, percentages, hours and counts", () => {
    expect(reportValue(1234.5, "ghs")).toBe("GH₵ 1,234.50");
    expect(reportValue(62.5, "percent")).toBe("62.5%");
    expect(reportValue(3.2, "hours")).toBe("3.2 h");
    expect(reportValue(12000)).toBe("12,000");
    expect(reportValue("7")).toBe("7");
  });
  it("shows a dash for a figure that is not available", () => {
    expect(reportValue(null)).toBe("–");
    expect(reportValue(undefined, "ghs")).toBe("–");
    expect(reportValue("")).toBe("–");
  });
  it("names every figure the report returns exactly once", () => {
    const keys = REPORT_GROUPS.flatMap((g) => g.fields.map(([key]) => key));
    expect(new Set(keys).size).toBe(keys.length);
    for (const key of ["rfqs", "orderedValue", "awardWinRatePercent", "pendingInvitations"])
      expect(keys).toContain(key);
  });
});

describe("labels", () => {
  it("has a plain name for each negotiable term and payment method", () => {
    expect(Object.keys(RFQ_TERM_LABELS).sort()).toEqual(
      ["credit", "delivery", "price", "quantity", "substitution"].sort(),
    );
    expect(paymentLabel("bank_transfer")).toBe("Bank transfer");
    expect(paymentLabel("unknown_method")).toBe("unknown method");
  });
});
