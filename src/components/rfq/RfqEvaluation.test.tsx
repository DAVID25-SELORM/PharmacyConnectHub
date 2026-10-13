// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({}) } }));

import { RfqEvaluation } from "./RfqEvaluation";
import type { QuoteVersion, Requirement, VersionLine } from "@/lib/enterprise-rfq";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
// Rendering long lists in jsdom is slow on a busy machine; the default 5 s is too tight.
vi.setConfig({ testTimeout: 30_000 });

const item = (id: string, over: Partial<Requirement> = {}): Requirement =>
  ({
    id,
    rfq_id: "r",
    product_name: `Medicine ${id}`,
    quantity: 100,
    notes: null,
    master_product_id: "m",
    specification: {},
    unit: "pack",
    minimum_shelf_life_days: 30,
    alternatives_allowed: true,
    partial_allowed: true,
    cold_chain_required: false,
    special_handling: null,
    cancelled_quantity: 0,
    ...over,
  }) as Requirement;
const line = (
  id: string,
  itemId: string,
  price: number,
  over: Partial<VersionLine> = {},
): VersionLine =>
  ({
    id,
    rfq_quote_id: "q",
    rfq_item_id: itemId,
    product_id: "p",
    quantity: 100,
    unit_price_ghs: price,
    discount_percent: 0,
    final_unit_price_ghs: price,
    line_total_ghs: price * 100,
    notes: null,
    alternative: false,
    offered_specification: { name: `Offer ${id}` },
    requested_units_per_offered_unit: 1,
    expiry_date: "2030-01-01",
    batch_number: null,
    expected_available_on: null,
    cold_chain_supported: false,
    special_handling: null,
    ...over,
  }) as VersionLine;
const version = (id: string, lines: VersionLine[], total: number, delivery = 0): QuoteVersion =>
  ({
    id,
    quote_id: `q-${id}`,
    wholesaler_id: `w-${id}`,
    version: 1,
    reason: "Initial quotation",
    created_at: "2026-10-13T10:00:00Z",
    snapshot: {
      quote: {
        total_ghs: total,
        delivery_charge_ghs: delivery,
        lead_time_days: 2,
        payment_terms: "Net 7",
        valid_until: "2030-01-01T00:00:00Z",
      },
      items: lines,
      orderDiscountPercent: 0,
      taxTreatment: "",
    },
  }) as unknown as QuoteVersion;

const items = [item("a"), item("b")];
const A = version("A", [line("A-a", "a", 10), line("A-b", "b", 6)], 1600, 20);
const B = version("B", [line("B-a", "a", 8), line("B-b", "b", 9)], 1700, 0);
const names = { "w-A": "Alpha Ltd", "w-B": "Beta Ltd" };

let host: HTMLDivElement;
let root: Root;
beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  document.body.innerHTML = "";
});

const onAward = vi.fn(async () => true);
const onNegotiate = vi.fn(async () => true);
const render = (canManage = true) =>
  act(async () =>
    root.render(
      <RfqEvaluation
        items={items}
        current={[A, B]}
        versions={[A, B]}
        names={names}
        credit={[]}
        groups={[]}
        allocations={[]}
        canManage={canManage}
        busy={false}
        onAward={onAward}
        onNegotiate={onNegotiate}
        onPdf={() => {}}
      />,
    ),
  );
const button = (text: string, scope: ParentNode = document) =>
  Array.from(scope.querySelectorAll("button")).find((b) => b.textContent?.trim() === text)!;
const type = async (el: HTMLInputElement, value: string) => {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};
const award = (id: string) => host.querySelector<HTMLInputElement>(`input[aria-label*="${id}"]`)!;

it("compares suppliers by landed total and marks the lowest price on each requirement", async () => {
  await render();
  expect(host.textContent).toContain("Alpha Ltd");
  expect(host.textContent).toContain("Beta Ltd");
  const lowestTotal = Array.from(host.querySelectorAll("tr")).find((r) =>
    r.textContent?.includes("Lowest total"),
  )!;
  expect(lowestTotal.textContent).toContain("Alpha Ltd");
  expect(host.textContent?.match(/Lowest price/g)).toHaveLength(2);
});

it("fills a cheapest-first starting point and totals it with each supplier's delivery", async () => {
  await render();
  await act(async () => button("Start from lowest prices").click());
  expect(host.textContent).toContain("2 lines from 2 suppliers");
  // a: Beta 100 @ 8 = 800 (no delivery); b: Alpha 100 @ 6 = 600 + 20 delivery
  expect(host.textContent).toContain("1420.00");
});

it("flags an over-allocation and blocks the review until it is fixed", async () => {
  await render();
  await type(award("Offer A-a"), "70");
  await type(award("Offer B-a"), "50");
  expect(host.textContent).toContain("still needed across suppliers");
  expect(button("Review allocations").disabled).toBe(true);
  await type(award("Offer B-a"), "30");
  expect(host.textContent).not.toContain("still needed across suppliers");
  expect(button("Review allocations").disabled).toBe(false);
});

it("sends the reviewed choices, with classification and settlement, to the award request", async () => {
  onAward.mockClear();
  await render();
  await type(award("Offer A-a"), "40");
  await type(award("Offer B-b"), "10");
  await act(async () => button("Review allocations").click());
  expect(document.body.textContent).toContain("Suppliers must confirm before orders are created");
  await act(async () => button("Confirm pending awards", document.body).click());
  expect(onAward).toHaveBeenCalledTimes(1);
  expect(onAward).toHaveBeenCalledWith({
    settlement: "cod",
    allocations: [
      {
        versionId: "A",
        quoteItemId: "A-a",
        quantity: 40,
        acceptAlternative: false,
        category: "cash_private",
      },
      {
        versionId: "B",
        quoteItemId: "B-b",
        quantity: 10,
        acceptAlternative: false,
        category: "cash_private",
      },
    ],
  });
});

it("is read-only for someone who cannot award: no award boxes and no review bar", async () => {
  await render(false);
  expect(host.querySelectorAll('input[aria-label^="Units to award"]').length).toBe(0);
  expect(host.textContent).not.toContain("Review allocations");
  expect(host.textContent).toContain("Alpha Ltd");
});
