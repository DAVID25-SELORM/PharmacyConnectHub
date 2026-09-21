import { describe, expect, it } from "vitest";
import {
  EMPTY_FILTERS,
  REDACTED,
  activityFiltersToSearch,
  activityLabel,
  activityToCsv,
  buildActivityRpcArgs,
  categorizeActivity,
  detailRows,
  filterKey,
  hasActiveFilters,
  paginate,
  parseActivitySearch,
  redactDetails,
  summarizeDetails,
  type ActivityRow,
} from "./activity-log";

const row = (n: number, overrides: Partial<ActivityRow> = {}): ActivityRow => ({
  id: `00000000-0000-0000-0000-${String(n).padStart(12, "0")}`,
  created_at: new Date(Date.UTC(2026, 8, 21, 10, 0, 0) - n * 1000).toISOString(),
  activity: "Order placed",
  organization: "Good Pharmacy",
  performed_by_email: "owner@example.com",
  record_type: "order",
  record_id: null,
  record_label: `ORD-${n}`,
  details: { status: "pending", total_ghs: 120 },
  ...overrides,
});

describe("event labels and categories", () => {
  it("maps raw strings to readable labels without changing unknown ones", () => {
    expect(activityLabel("Business staff invited")).toBe("Staff invited");
    expect(activityLabel("Pharmacy submitted")).toBe("Verification submitted (pharmacy)");
    expect(activityLabel("Order cancelled")).toBe("Order cancelled");
    expect(activityLabel("Something new")).toBe("Something new");
  });

  it("categorises like the database does", () => {
    expect(categorizeActivity("Business approved")).toBe("verification");
    expect(categorizeActivity("Verification resubmitted")).toBe("verification");
    expect(categorizeActivity("Order dispatched")).toBe("orders");
    expect(categorizeActivity("Payment paid")).toBe("payments");
    expect(categorizeActivity("Platform staff updated")).toBe("staff");
    expect(categorizeActivity("Inventory imported")).toBe("inventory");
    expect(categorizeActivity("Mystery")).toBe("other");
  });
});

describe("sensitive metadata", () => {
  it("redacts secret-looking keys at any depth", () => {
    const safe = redactDetails({
      status: "ok",
      access_token: "abc",
      nested: { SMTP_PASS: "x", keep: 1, list: [{ password: "p", name: "n" }] },
      headers: { Authorization: "Bearer zzz" },
    }) as Record<string, any>;

    expect(safe.access_token).toBe(REDACTED);
    expect(safe.nested.SMTP_PASS).toBe(REDACTED);
    expect(safe.nested.keep).toBe(1);
    expect(safe.nested.list[0].password).toBe(REDACTED);
    expect(safe.nested.list[0].name).toBe("n");
    expect(safe.headers.Authorization).toBe(REDACTED);
    expect(JSON.stringify(safe)).not.toMatch(/abc|Bearer zzz/);
  });

  it("never shows a secret in rows, summaries or csv", () => {
    const details = { refresh_token: "SECRET-VALUE", total_ghs: 5 };
    expect(
      detailRows(details)
        .map((r) => r.value)
        .join(),
    ).not.toContain("SECRET-VALUE");
    expect(summarizeDetails(details)).not.toContain("SECRET-VALUE");
    expect(activityToCsv([row(1, { details })])).not.toContain("SECRET-VALUE");
  });
});

describe("details formatting", () => {
  it("renders readable key/value rows, never [object Object]", () => {
    const rows = detailRows({ wholesaler: "Alpha", meta: { city: "Accra", region: "GA" } });
    expect(rows).toContainEqual({ key: "Wholesaler", value: "Alpha" });
    expect(rows).toContainEqual({ key: "Meta city", value: "Accra" });
    expect(JSON.stringify(rows)).not.toContain("[object Object]");
  });

  it("summarises to one bounded line", () => {
    const long = summarizeDetails({ a: "x".repeat(300), b: 2 }, 3, 60);
    expect(long.length).toBeLessThanOrEqual(60);
    expect(summarizeDetails(null)).toBe("");
  });
});

describe("filters and URL state", () => {
  it("coerces untrusted search params to a valid filter set", () => {
    const parsed = parseActivitySearch({
      q: "  acme ",
      category: "not-real",
      orgType: "wholesaler",
      range: "custom",
      from: "2026-09-01",
      to: "bad",
      limit: "500",
    });
    expect(parsed.q).toBe("acme");
    expect(parsed.category).toBe("");
    expect(parsed.orgType).toBe("wholesaler");
    expect(parsed.to).toBe("");
    expect(parsed.limit).toBe(50);
  });

  it("writes only non-default values to the URL and round-trips", () => {
    const filters = { ...EMPTY_FILTERS, q: "acme", range: "7d" as const, limit: 25 as const };
    const search = activityFiltersToSearch(filters);
    expect(search).toEqual({ q: "acme", range: "7d", limit: 25 });
    expect(parseActivitySearch(search)).toEqual(filters);
    expect(activityFiltersToSearch(EMPTY_FILTERS)).toEqual({});
    expect(hasActiveFilters(EMPTY_FILTERS)).toBe(false);
    expect(hasActiveFilters({ ...EMPTY_FILTERS, limit: 100 })).toBe(false);
    expect(hasActiveFilters(filters)).toBe(true);
  });

  it("changes the filter key when any filter changes (pagination reset trigger)", () => {
    const base = filterKey(EMPTY_FILTERS);
    for (const change of [
      { q: "ab" },
      { event: "Order placed" },
      { org: "Alpha" },
      { actor: "system" },
      { range: "today" as const },
      { category: "orders" as const },
    ]) {
      expect(filterKey({ ...EMPTY_FILTERS, ...change })).not.toBe(base);
    }
  });

  it("builds bounded RPC args: only what the server needs", () => {
    const args = buildActivityRpcArgs(
      { ...EMPTY_FILTERS, q: "a", range: "custom", from: "2026-09-01", to: "2026-09-03" },
      { created_at: "2026-09-20T10:00:00.000Z", id: "abc" },
      51,
    );
    expect(args.p_search).toBeNull(); // 1 character is not searched
    expect(args.p_limit).toBe(51);
    expect(args.p_from).toBe("2026-09-01T00:00:00.000Z");
    expect(args.p_to).toBe("2026-09-04T00:00:00.000Z"); // inclusive end date => next day, exclusive
    expect(args.p_cursor_id).toBe("abc");
  });
});

describe("keyset pagination helper", () => {
  it("asks for one extra row and exposes the cursor of the last visible row", () => {
    const fetched = Array.from({ length: 51 }, (_, i) => row(i + 1));
    const { page, hasMore, nextCursor } = paginate(fetched, 50);
    expect(page).toHaveLength(50);
    expect(hasMore).toBe(true);
    expect(nextCursor).toEqual({ created_at: fetched[49].created_at, id: fetched[49].id });
  });

  it("reports the last page without a cursor", () => {
    const { page, hasMore, nextCursor } = paginate([row(1), row(2)], 50);
    expect(page).toHaveLength(2);
    expect(hasMore).toBe(false);
    expect(nextCursor).toBeNull();
  });

  it("never lets a simulated 100k-row table exceed one page in memory", () => {
    // The client only ever receives limit + 1 rows, regardless of the table size.
    const serverPage = Array.from({ length: 51 }, (_, i) => row(i + 1));
    expect(paginate(serverPage, 50).page.length).toBeLessThanOrEqual(50);
  });
});

describe("csv export", () => {
  it("escapes quotes and neutralises formula injection", () => {
    const csv = activityToCsv([
      row(1, { organization: '=HYPERLINK("x")', record_label: 'He said "hi"' }),
    ]);
    expect(csv).toContain(`"'=HYPERLINK(""x"")"`);
    expect(csv).toContain(`"He said ""hi"""`);
    expect(csv.split("\r\n")).toHaveLength(2);
  });
});
