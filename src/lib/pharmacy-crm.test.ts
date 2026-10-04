import { describe, it, expect } from "vitest";
import { emptyCrm, lastVisit, nextFollowup, matchesRep } from "./pharmacy-crm";
describe("CRM summaries and discovery", () => {
  it("ignores calls and archived visits when deriving last visit", () => {
    const d = emptyCrm();
    d.interactions = [
      { id: "1", rep_id: "r", interaction_type: "visit", occurred_at: "2026-01-01" },
      { id: "2", rep_id: "r", interaction_type: "call", occurred_at: "2026-03-01" },
      {
        id: "3",
        rep_id: "r",
        interaction_type: "visit",
        occurred_at: "2026-04-01",
        archived: true,
      },
    ];
    expect(lastVisit(d, "r")).toBe("2026-01-01");
    expect(lastVisit(d, "other")).toBe("");
  });
  it("derives next pending follow-up, excluding completed and archived records", () => {
    const d = emptyCrm();
    d.followups = [
      { id: "1", rep_id: "r", status: "completed", due_at: "2026-01-01" },
      { id: "2", rep_id: "r", status: "pending", due_at: "2026-03-01" },
      { id: "3", rep_id: "r", status: "pending", due_at: "2026-02-01", archived: true },
    ];
    expect(nextFollowup(d, "r")).toBe("2026-03-01");
  });
  it("finds reps through company and product links without matching other reps", () => {
    const d = emptyCrm();
    const r = { id: "r", name: "A representative" };
    d.companies = [{ id: "c", name: "Supplier Alpha" }];
    d.rep_companies = [{ id: "l", rep_id: "r", company_id: "c" }];
    d.rep_products = [{ id: "p", rep_id: "r", label: "Example product", brand: "Brand A" }];
    expect(matchesRep(d, r, "alpha")).toBe(true);
    expect(matchesRep(d, r, "brand a")).toBe(true);
    expect(matchesRep(d, { id: "other" }, "alpha")).toBe(false);
  });
});
