import { describe, expect, it } from "vitest";
import {
  escapeHtml,
  statementPrintHtml,
  statementRange,
  statementToCsv,
  type Statement,
} from "./statement";

const statement: Statement = {
  wholesaler: { id: "w", name: "Alpha <b>Wholesale</b>", city: "Accra", region: null },
  pharmacy: { id: "p", name: "Good Pharmacy", city: null, region: null },
  from: "2026-09-01T00:00:00.000Z",
  to: "2026-10-01T00:00:00.000Z",
  opening_balance: 100,
  total_debits: 50,
  total_credits: 120,
  closing_balance: 30,
  line_count: 2,
  truncated: false,
  lines: [
    {
      date: "2026-09-05T10:00:00Z",
      kind: "order",
      order_id: "o1",
      order_number: "ORD-1",
      debit: 50,
      credit: 0,
      discount: 0,
      balance: 150,
    },
    {
      date: "2026-09-06T10:00:00Z",
      kind: "payment",
      order_id: "o1",
      order_number: "=ORD-1",
      debit: 0,
      credit: 120,
      discount: 0,
      balance: 30,
    },
  ],
};

describe("statement helpers", () => {
  it("turns inclusive date inputs into a half-open range", () => {
    const range = statementRange("2026-09-01", "2026-09-30");
    expect(range).not.toBeNull();
    expect(new Date(range!.to).getTime() - new Date(range!.from).getTime()).toBeGreaterThanOrEqual(
      30 * 23 * 3600 * 1000,
    );
    expect(statementRange("2026-09-30", "2026-09-01")).toBeNull();
    expect(statementRange("", "2026-09-01")).toBeNull();
  });

  it("writes opening, lines and closing to CSV with the expected rows", () => {
    const lines = statementToCsv(statement).split("\r\n");
    expect(lines).toHaveLength(5);
    expect(lines[1]).toContain("Opening balance");
    expect(lines[1]).toContain("100.00");
    expect(lines[3]).toContain("Payment received for =ORD-1");
    expect(lines[4]).toContain("30.00");
  });

  it("escapes database values in printable HTML", () => {
    expect(escapeHtml(`<script>"x"&'`)).toBe("&lt;script&gt;&quot;x&quot;&amp;&#39;");
    const html = statementPrintHtml(statement);
    expect(html).toContain("Alpha &lt;b&gt;Wholesale&lt;/b&gt;");
    expect(html).not.toContain("<b>Wholesale</b>");
    expect(html).toContain("GHS 30.00");
  });
});
