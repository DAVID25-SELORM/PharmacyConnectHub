import { describe, expect, it } from "vitest";
import {
  agingBuckets,
  daysUntil,
  inventoryCounts,
  pharmacyDashboardAccess,
  rfqsClosingSoon,
  sortAttention,
  summariseCredit,
  wholesalerDashboardAccess,
  type AttentionItem,
} from "./dashboard";

const today = new Date(2026, 9, 2, 15, 30); // 2 Oct 2026, mid-afternoon

describe("daysUntil", () => {
  it("counts whole calendar days regardless of the time of day", () => {
    expect(daysUntil("2026-10-02", today)).toBe(0);
    expect(daysUntil("2026-10-09", today)).toBe(7);
    expect(daysUntil("2026-09-30", today)).toBe(-2);
  });
});

describe("summariseCredit", () => {
  it("separates overdue, due within 7 days, and later; ignores settled rows", () => {
    const summary = summariseCredit(
      [
        { due_date: "2026-09-20", outstanding_ghs: "100.00", status: "overdue" },
        { due_date: "2026-10-05", outstanding_ghs: 50, status: "due_soon" },
        { due_date: "2026-11-30", outstanding_ghs: 25.5, status: "not_due" },
        { due_date: "2026-09-01", outstanding_ghs: 0, status: "paid" },
      ],
      today,
    );
    expect(summary).toEqual({
      outstanding: 175.5,
      invoiceCount: 3,
      overdueCount: 1,
      overdueTotal: 100,
      dueSoonCount: 1,
      dueSoonTotal: 50,
    });
  });
  it("treats a past due date as overdue even if the status string says otherwise", () => {
    expect(
      summariseCredit([{ due_date: "2026-10-01", outstanding_ghs: 10, status: "disputed" }], today)
        .overdueCount,
    ).toBe(1);
  });
  it("counts an invoice due today as due soon, not overdue", () => {
    const s = summariseCredit(
      [{ due_date: "2026-10-02", outstanding_ghs: 10, status: "due_today" }],
      today,
    );
    expect(s).toMatchObject({ overdueCount: 0, dueSoonCount: 1 });
  });
  it("is all zeros for no rows", () => {
    expect(summariseCredit([], today).outstanding).toBe(0);
  });
});

describe("agingBuckets", () => {
  it("groups outstanding balances by lateness", () => {
    const buckets = agingBuckets(
      [
        { due_date: "2026-11-01", outstanding_ghs: 10, status: "not_due" },
        { due_date: null, outstanding_ghs: 5, status: "not_due" },
        { due_date: "2026-09-22", outstanding_ghs: 20, status: "overdue" }, // 10 late
        { due_date: "2026-08-20", outstanding_ghs: 30, status: "overdue" }, // 43 late
        { due_date: "2026-06-01", outstanding_ghs: 40, status: "overdue" }, // 123 late
      ],
      today,
    );
    expect(buckets.map((b) => b.total)).toEqual([15, 20, 30, 40]);
    expect(buckets.map((b) => b.count)).toEqual([2, 1, 1, 1]);
  });
});

describe("inventoryCounts", () => {
  it("keeps out-of-stock and low-stock separate and counts expiry within 30 days (including expired)", () => {
    const counts = inventoryCounts(
      [
        { stock: 0, reorder_level: 5, expiry_date: null },
        { stock: 3, reorder_level: 5, expiry_date: "2026-10-20" },
        { stock: 50, reorder_level: 5, expiry_date: "2026-09-01" },
        { stock: 50, reorder_level: null, expiry_date: "2027-06-30" },
        { stock: 4, reorder_level: null, expiry_date: null },
      ],
      today,
    );
    expect(counts).toEqual({ lowStock: 1, outOfStock: 1, expiringSoon: 2 });
  });
});

describe("rfqsClosingSoon", () => {
  const now = new Date("2026-10-02T12:00:00Z");
  it("counts only deadlines within the window that haven't passed", () => {
    expect(
      rfqsClosingSoon(
        [
          { id: "a", response_deadline: "2026-10-04T12:00:00Z" },
          { id: "b", response_deadline: "2026-10-20T12:00:00Z" },
          { id: "c", response_deadline: "2026-10-01T12:00:00Z" },
          { id: "d", response_deadline: null },
        ],
        3,
        now,
      ),
    ).toBe(1);
  });
});

describe("sortAttention", () => {
  const item = (key: string, tone: AttentionItem["tone"], count: number): AttentionItem => ({
    key,
    label: key,
    detail: "",
    count,
    tone,
    to: "/x",
  });
  it("drops empty items and orders by urgency, stable within a tone", () => {
    const sorted = sortAttention([
      item("a", "info", 2),
      item("b", "danger", 0),
      item("c", "warning", 1),
      item("d", "danger", 4),
      item("e", "warning", 3),
    ]);
    expect(sorted.map((i) => i.key)).toEqual(["d", "c", "e", "a"]);
  });
});

describe("dashboard access", () => {
  it("shows finance only to roles that handle money", () => {
    expect(pharmacyDashboardAccess("accountant").finance).toBe(true);
    expect(pharmacyDashboardAccess("cashier").finance).toBe(false);
    expect(pharmacyDashboardAccess("assistant").finance).toBe(false);
  });
  it("shows inventory to stock-handling roles and not to finance-only roles", () => {
    expect(pharmacyDashboardAccess("warehouse").inventory).toBe(true);
    expect(pharmacyDashboardAccess("accountant").inventory).toBe(false);
  });
  it("limits the activity feed to the same roles as the audit log", () => {
    expect(pharmacyDashboardAccess("owner").activity).toBe(true);
    expect(pharmacyDashboardAccess("manager").activity).toBe(true);
    expect(pharmacyDashboardAccess("accountant").activity).toBe(true);
    expect(pharmacyDashboardAccess("cashier").activity).toBe(false);
    expect(wholesalerDashboardAccess("finance").activity).toBe(false);
  });
  it("gives an unknown role nothing", () => {
    expect(pharmacyDashboardAccess(undefined)).toEqual({
      finance: false,
      inventory: false,
      rfq: false,
      activity: false,
    });
  });
});
