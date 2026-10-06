import { describe, expect, it } from "vitest";
import {
  daysUntil,
  inventoryCounts,
  overviewAging,
  overviewSummary,
  pharmacyDashboardAccess,
  rfqsClosingSoon,
  sortAttention,
  wholesalerDashboardAccess,
  type AccountingOverview,
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

const overview: AccountingOverview = {
  side: "wholesaler",
  as_of: "2026-10-02",
  outstanding_ghs: "1050.00",
  invoice_count: 9,
  overdue_ghs: "800.00",
  overdue_count: 6,
  due_soon_ghs: "200.00",
  due_soon_count: 2,
  disputed_ghs: "100.00",
  disputed_count: 1,
  aging: [
    { bucket: "current", invoices: 3, outstanding_ghs: "250.00" },
    { bucket: "d1_30", invoices: 4, outstanding_ghs: "500.00" },
    { bucket: "d31_60", invoices: 1, outstanding_ghs: "200.00" },
    { bucket: "d61_90", invoices: 0, outstanding_ghs: "0.00" },
    { bucket: "d90_plus", invoices: 1, outstanding_ghs: "100.00" },
  ],
  top_overdue: [],
  payments_30d: { count: 1, total_ghs: "150.00" },
  on_account: { total_ghs: "100.00", parties: 1 },
};

describe("overviewSummary", () => {
  it("turns the database's figures into plain numbers without recalculating anything", () => {
    expect(overviewSummary(overview)).toEqual({
      outstanding: 1050,
      invoiceCount: 9,
      overdueCount: 6,
      overdueTotal: 800,
      dueSoonCount: 2,
      dueSoonTotal: 200,
    });
  });
});

describe("overviewAging", () => {
  it("always returns the five buckets, in order, from the database's figures", () => {
    const buckets = overviewAging(overview);
    expect(buckets.map((b) => b.label)).toEqual([
      "Not yet due",
      "1–30 days",
      "31–60 days",
      "61–90 days",
      "Over 90",
    ]);
    expect(buckets.map((b) => b.total)).toEqual([250, 500, 200, 0, 100]);
    expect(buckets.map((b) => b.count)).toEqual([3, 4, 1, 0, 1]);
  });
  it("is five empty buckets while nothing has loaded, or when a bucket is missing", () => {
    expect(overviewAging(null).map((b) => b.total)).toEqual([0, 0, 0, 0, 0]);
    expect(
      overviewAging({
        ...overview,
        aging: [{ bucket: "d90_plus", invoices: 2, outstanding_ghs: 30 }],
      }).map((b) => b.total),
    ).toEqual([0, 0, 0, 0, 30]);
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
  it("shows finance to exactly the roles that can open Accounting, on each side", () => {
    for (const role of ["owner", "manager", "finance", "accountant"] as const)
      expect(wholesalerDashboardAccess(role).finance).toBe(true);
    for (const role of ["cashier", "assistant", "warehouse"] as const)
      expect(wholesalerDashboardAccess(role).finance).toBe(false);
    for (const role of ["owner", "manager", "accountant"] as const)
      expect(pharmacyDashboardAccess(role).finance).toBe(true);
    for (const role of ["finance", "cashier", "assistant", "warehouse"] as const)
      expect(pharmacyDashboardAccess(role).finance).toBe(false);
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
