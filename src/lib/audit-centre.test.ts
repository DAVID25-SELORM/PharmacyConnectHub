import { describe, expect, it } from "vitest";
import {
  EMPTY_AUDIT_FILTERS,
  auditActivityLabel,
  auditCategoryLabel,
  auditFilterKey,
  auditFiltersToSearch,
  auditLogToCsv,
  buildAuditRpcArgs,
  hasActiveAuditFilters,
  paginate,
  parseAuditSearch,
  type AuditLogRow,
} from "./audit-centre";

const row = (n: number, overrides: Partial<AuditLogRow> = {}): AuditLogRow => ({
  id: `00000000-0000-0000-0000-${String(n).padStart(12, "0")}`,
  created_at: new Date(Date.UTC(2026, 8, 21, 10, 0, 0) - n * 1000).toISOString(),
  activity: "RFQ created",
  record_type: "rfq",
  record_id: null,
  record_label: `RFQ-${n}`,
  performed_by_email: "owner@example.com",
  details: { item_count: 2 },
  ...overrides,
});

describe("event labels and categories", () => {
  it("maps known raw strings to readable labels without changing unknown ones", () => {
    expect(auditActivityLabel("RFQ quote submitted")).toBe("Quote submitted");
    expect(auditActivityLabel("Credit payment recorded")).toBe("Payment recorded");
    expect(auditActivityLabel("Something new")).toBe("Something new");
  });

  it("categorises RFQ, credit, inventory and verification events distinctly", () => {
    expect(auditCategoryLabel("RFQ awarded")).toBe("RFQ");
    expect(auditCategoryLabel("Credit ledger entry reversed")).toBe("Credit");
    expect(auditCategoryLabel("Pharmacy inventory imported")).toBe("Inventory");
    expect(auditCategoryLabel("Pharmacy inventory item added")).toBe("Inventory");
    expect(auditCategoryLabel("Pharmacy inventory stock adjusted")).toBe("Inventory");
    expect(auditCategoryLabel("Business approved")).toBe("Verification");
    expect(auditCategoryLabel("Order supply change accepted")).toBe("Order");
    expect(auditActivityLabel("Order supply change proposed")).toBe("Supply change proposed");
    expect(auditCategoryLabel("Mystery")).toBe("Other");
  });
});

describe("filters and URL state", () => {
  it("coerces untrusted search params to a valid filter set", () => {
    const parsed = parseAuditSearch({
      q: "  acme ",
      recordType: "not-real",
      range: "custom",
      from: "2026-09-01",
      to: "bad",
      limit: "500",
    });
    expect(parsed.q).toBe("acme");
    expect(parsed.recordType).toBe("");
    expect(parsed.range).toBe("custom");
    expect(parsed.from).toBe("2026-09-01");
    expect(parsed.to).toBe("");
    expect(parsed.limit).toBe(50);
  });

  it("accepts only known record types", () => {
    expect(parseAuditSearch({ recordType: "rfq_quote" }).recordType).toBe("rfq_quote");
    expect(parseAuditSearch({ recordType: "users" }).recordType).toBe("");
  });

  it("writes only non-default values to the URL and round-trips", () => {
    const filters = { ...EMPTY_AUDIT_FILTERS, q: "acme", range: "7d" as const, limit: 25 as const };
    const search = auditFiltersToSearch(filters);
    expect(search).toEqual({ q: "acme", range: "7d", limit: 25 });
    expect(parseAuditSearch(search)).toEqual(filters);
    expect(auditFiltersToSearch(EMPTY_AUDIT_FILTERS)).toEqual({});
    expect(hasActiveAuditFilters(EMPTY_AUDIT_FILTERS)).toBe(false);
    expect(hasActiveAuditFilters({ ...EMPTY_AUDIT_FILTERS, limit: 100 })).toBe(false);
    expect(hasActiveAuditFilters(filters)).toBe(true);
  });

  it("only writes from/to when the range is custom", () => {
    const search = auditFiltersToSearch({
      ...EMPTY_AUDIT_FILTERS,
      range: "today",
      from: "2026-09-01",
      to: "2026-09-02",
    });
    expect(search).toEqual({ range: "today" });
  });

  it("changes the filter key when any filter changes (pagination reset trigger)", () => {
    const base = auditFilterKey(EMPTY_AUDIT_FILTERS);
    for (const change of [{ q: "ab" }, { recordType: "rfq" }, { range: "today" as const }]) {
      expect(auditFilterKey({ ...EMPTY_AUDIT_FILTERS, ...change })).not.toBe(base);
    }
  });
});

describe("RPC arguments", () => {
  it("scopes every call to the given business and bounds search to 2+ chars", () => {
    const args = buildAuditRpcArgs(
      "biz-1",
      { ...EMPTY_AUDIT_FILTERS, q: "a", recordType: "rfq" },
      null,
      50,
    );
    expect(args.p_business_id).toBe("biz-1");
    expect(args.p_search).toBeNull(); // 1 character is not searched
    expect(args.p_record_type).toBe("rfq");
    expect(args.p_limit).toBe(50);
  });

  it("builds an inclusive custom date range (next-day exclusive upper bound)", () => {
    const args = buildAuditRpcArgs(
      "biz-1",
      { ...EMPTY_AUDIT_FILTERS, range: "custom", from: "2026-09-01", to: "2026-09-03" },
      { created_at: "2026-09-20T10:00:00.000Z", id: "abc" },
      51,
    );
    expect(args.p_from).toBe("2026-09-01T00:00:00.000Z");
    expect(args.p_to).toBe("2026-09-04T00:00:00.000Z");
    expect(args.p_cursor_id).toBe("abc");
    expect(args.p_limit).toBe(51);
  });

  it("derives a from-timestamp for the preset ranges without a custom bound", () => {
    const args = buildAuditRpcArgs("biz-1", { ...EMPTY_AUDIT_FILTERS, range: "today" }, null);
    expect(args.p_from).not.toBeNull();
    expect(args.p_to).toBeNull();
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
});

describe("csv export", () => {
  it("never shows a secret and escapes formula injection", () => {
    const csv = auditLogToCsv([
      row(1, { details: { refresh_token: "SECRET-VALUE", amount_ghs: 50 } }),
      row(2, { record_label: '=HYPERLINK("x")' }),
    ]);
    expect(csv).not.toContain("SECRET-VALUE");
    expect(csv).toContain(`"'=HYPERLINK(""x"")"`);
    expect(csv.split("\r\n")).toHaveLength(3);
  });
});
