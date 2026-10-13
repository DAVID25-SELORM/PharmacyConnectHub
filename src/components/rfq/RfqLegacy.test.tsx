// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({}), rpc } }));

import { AdminRfqOperations } from "./AdminRfqOperations";
import { LegacyQuoteTable } from "./LegacyQuoteTable";
import { legacyIssues } from "@/lib/rfq-legacy";
import type { QuoteLineDraft, RfqItem } from "@/lib/rfq";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
// Rendering long lists in jsdom is slow on a busy machine; the default 5 s is too tight.
vi.setConfig({ testTimeout: 30_000 });

let host: HTMLDivElement;
let root: Root;
beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  rpc.mockReset();
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  document.body.innerHTML = "";
});
const render = (node: React.ReactNode) => act(async () => root.render(node));
const button = (text: string, scope: ParentNode = document) =>
  Array.from(scope.querySelectorAll("button")).find((b) => b.textContent?.trim() === text)!;
const type = async (el: HTMLInputElement | HTMLTextAreaElement, value: string) => {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement : HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(proto.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};

const makeItems = (n: number): RfqItem[] =>
  Array.from(
    { length: n },
    (_, i) =>
      ({
        id: `i${i + 1}`,
        rfq_id: "r",
        product_name: `Item ${String(i + 1).padStart(3, "0")}`,
        quantity: 10,
        notes: null,
      }) as RfqItem,
  );
const blank = (id: string, over: Partial<QuoteLineDraft> = {}): QuoteLineDraft => ({
  rfqItemId: id,
  productId: "",
  unitPriceGhs: "",
  quantity: "",
  discountPercent: "",
  notes: "",
  include: false,
  ...over,
});

let latest: QuoteLineDraft[] = [];
function Harness({
  items,
  initial,
  editable = true,
}: {
  items: RfqItem[];
  initial: QuoteLineDraft[];
  editable?: boolean;
}) {
  const [lines, setLines] = useState(initial);
  latest = lines;
  const map = new Map(items.map((i) => [i.id, i]));
  return (
    <LegacyQuoteTable
      businessId="b"
      items={items}
      lines={lines}
      onChange={setLines}
      issues={legacyIssues(lines, map)}
      products={new Map([["p1", { id: "p1", name: "My product", stock: 5 }]])}
      onProducts={() => {}}
      editable={editable}
    />
  );
}

it("pages a long request, and shows what each chosen line still needs", async () => {
  const items = makeItems(40);
  const lines = items.map((i, n) =>
    blank(
      i.id,
      n === 0
        ? { include: true }
        : n === 1
          ? { include: true, productId: "p1", unitPriceGhs: "4" }
          : {},
    ),
  );
  await render(<Harness items={items} initial={lines} />);
  expect(host.querySelectorAll("tbody tr").length).toBe(25);
  expect(host.textContent).toContain("2 of 40 items quoted");
  expect(host.textContent).toContain("Choose your product.");
  expect(host.textContent).toContain("1 need attention");
  await act(async () =>
    host.querySelector<HTMLButtonElement>('button[aria-label="Next page"]')!.click(),
  );
  expect(host.textContent).toContain("Showing 26–40 of 40");
});

it("quotes or clears everything that is shown, not only the visible page", async () => {
  const items = makeItems(40);
  await render(<Harness items={items} initial={items.map((i) => blank(i.id))} />);
  await type(
    host.querySelector<HTMLInputElement>('input[aria-label="Search requested items"]')!,
    "Item 03",
  );
  // Item 030 to 039 match
  expect(host.querySelectorAll("tbody tr").length).toBe(10);
  await act(async () => button("Quote all shown").click());
  expect(latest.filter((l) => l.include)).toHaveLength(10);
  expect(latest.filter((l) => l.include).every((l) => l.rfqItemId.startsWith("i3"))).toBe(true);
  await act(async () => button("Clear all shown").click());
  expect(latest.some((l) => l.include)).toBe(false);
});

it("is read-only for a quotation that can no longer be changed: only quoted lines, no inputs", async () => {
  const items = makeItems(3);
  const lines = [
    blank("i1", { include: true, productId: "p1", unitPriceGhs: "8", discountPercent: "10" }),
    blank("i2"),
    blank("i3"),
  ];
  await render(<Harness items={items} initial={lines} editable={false} />);
  expect(host.querySelectorAll("tbody tr").length).toBe(1);
  expect(
    host.querySelectorAll('input[aria-label^="Unit price"], input[aria-label^="Discount"]').length,
  ).toBe(0);
  expect(host.textContent).toContain("My product");
  expect(host.textContent).toContain("10%");
});

const adminReport = {
  rfqs: 30,
  pharmacies: 4,
  suppliers: 7,
  quotes: 12,
  orders: 3,
  failed: 2,
  cancelled: 1,
  rows: [
    {
      id: "r1",
      reference: "RFQ-1",
      title: "Antibiotics",
      status: "open",
      created_at: "2026-10-01T00:00:00Z",
      failed_conversions: 2,
    },
    {
      id: "r2",
      reference: "RFQ-2",
      title: "Gloves",
      status: "completed",
      created_at: "2026-10-02T00:00:00Z",
      failed_conversions: 0,
    },
  ],
};

it("loads the platform figures, and flags failed conversions", async () => {
  rpc.mockResolvedValueOnce({ data: adminReport, error: null });
  await render(<AdminRfqOperations />);
  await act(async () => button("Load operational report").click());
  expect(host.textContent).toContain("Failed conversions");
  expect(host.textContent).toContain("Antibiotics");
  expect(host.textContent).toContain("Showing 1–2 of 30");
  expect(host.querySelector(".text-destructive")).not.toBeNull();
});

it("will not open an investigation without a specific reason, and records the reason it is given", async () => {
  rpc.mockResolvedValueOnce({ data: adminReport, error: null });
  rpc.mockResolvedValueOnce({
    data: { rfq: { id: "r1" }, events: [{ a: 1 }, { a: 2 }] },
    error: null,
  });
  await render(<AdminRfqOperations />);
  await act(async () => button("Load operational report").click());
  await act(async () => button("Investigate…").click());
  const open = () => button("Open investigation", document.body);
  expect(open().disabled).toBe(true);
  const area = document.body.querySelector<HTMLTextAreaElement>("textarea")!;
  await type(area, "too short");
  expect(open().disabled).toBe(true);
  await type(area, "Complaint about a failed conversion on this award");
  expect(open().disabled).toBe(false);
  await act(async () => open().click());
  expect(rpc).toHaveBeenLastCalledWith("investigate_rfq", {
    p_rfq_id: "r1",
    p_reason: "Complaint about a failed conversion on this award",
  });
  expect(document.body.textContent).toContain("Restricted commercial investigation");
  expect(document.body.textContent).toContain("recorded in the audit log");
  expect(document.body.textContent).toContain("events");
  expect(document.body.textContent).toContain("(2)");
});
