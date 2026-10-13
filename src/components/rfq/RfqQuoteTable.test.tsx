// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({}) } }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }));

import { RfqQuoteTable } from "./RfqQuoteTable";
import type { Requirement } from "@/lib/enterprise-rfq";
import { blankDraftLine, lineIssues, type DraftLine } from "@/lib/rfq-quote-lines";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const items = (n: number): Requirement[] =>
  Array.from(
    { length: n },
    (_, i) =>
      ({
        id: `i${i + 1}`,
        rfq_id: "r",
        product_name: `Requested ${String(i + 1).padStart(3, "0")}`,
        quantity: 10,
        notes: null,
        master_product_id: null,
        specification: {},
        unit: "pack",
        minimum_shelf_life_days: 30,
        alternatives_allowed: false,
        partial_allowed: true,
        cold_chain_required: false,
        special_handling: null,
        cancelled_quantity: 0,
      }) as Requirement,
  );

let host: HTMLDivElement;
let root: Root;
let latest: DraftLine[] = [];
beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});

function Harness({ requested, initial }: { requested: Requirement[]; initial: DraftLine[] }) {
  const [lines, setLines] = useState(initial);
  latest = lines;
  const map = new Map(requested.map((i) => [i.id, i]));
  const issues = lineIssues(lines, map, () => ({
    expectedDelivery: null,
    today: "2026-10-13",
    offeredMaster: undefined,
  }));
  return (
    <RfqQuoteTable
      businessId="b"
      items={requested}
      lines={lines}
      onChange={setLines}
      issues={issues}
      products={new Map()}
      onProducts={() => {}}
      orderDiscountPercent={0}
    />
  );
}
const render = (requested: Requirement[], quoted: Partial<DraftLine>[] = []) =>
  act(async () =>
    root.render(
      <Harness
        requested={requested}
        initial={requested.map((it, i) => ({
          ...blankDraftLine(it),
          ...(quoted[i] ?? {}),
        }))}
      />,
    ),
  );
const rows = () => host.querySelectorAll("tbody tr").length;
const button = (text: string) =>
  Array.from(host.querySelectorAll("button")).find((b) => b.textContent?.trim() === text)!;
const type = async (el: HTMLInputElement, value: string) => {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};
const FULL = { productId: "p1", unitPriceGhs: "5", expiryDate: "2030-01-01" };

it("shows one page of a long request and counts what is quoted", async () => {
  await render(items(60), [FULL, FULL]);
  expect(rows()).toBe(25);
  expect(host.textContent).toContain("2 of 60 lines quoted");
  expect(host.textContent).toContain("58 not quoting");
  await act(async () =>
    host.querySelector<HTMLButtonElement>('button[aria-label="Next page"]')!.click(),
  );
  expect(host.textContent).toContain("Showing 26–50 of 60");
});

it("explains why a quoted line cannot be submitted and filters to such lines", async () => {
  await render(items(30), [{ productId: "p1", unitPriceGhs: "", expiryDate: "" }, FULL]);
  expect(host.textContent).toContain("Enter a unit price above zero.");
  expect(host.textContent).toContain("1 need attention");
  await act(async () => button("1 need attention · show").click());
  expect(rows()).toBe(1);
  expect(host.textContent).toContain("1 of 30 lines");
});

it("applies a bulk expiry date to quoted selected lines only", async () => {
  await render(items(5), [
    { productId: "p1", unitPriceGhs: "5" },
    { productId: "p2", unitPriceGhs: "6" },
  ]);
  // select the two quoted lines and the first unquoted one
  for (const n of [1, 2, 3])
    await act(async () =>
      host.querySelector<HTMLButtonElement>(`button[aria-label="Select line ${n}"]`)!.click(),
    );
  expect(host.textContent).toContain("3 selected");
  await type(
    host.querySelector<HTMLInputElement>('input[aria-label="Expiry date for the selected lines"]')!,
    "2031-05-05",
  );
  await act(async () => button("Set expiry").click());
  expect(latest.map((l) => l.expiryDate)).toEqual(["2031-05-05", "2031-05-05", "", "", ""]);
});

it("keeps unquoted lines quiet instead of showing empty inputs", async () => {
  await render(items(3));
  expect(host.textContent).toContain("Not quoting this line");
  expect(host.querySelectorAll('input[aria-label^="Unit price"]').length).toBe(0);
  expect(host.textContent).toContain("0 of 3 lines quoted");
});
