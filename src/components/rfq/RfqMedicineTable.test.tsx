// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    from: () => ({
      select: () => ({
        eq: () => ({ or: () => ({ order: () => ({ limit: async () => ({ data: [] }) }) }) }),
      }),
    }),
  },
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

import { RfqMedicineTable } from "./RfqMedicineTable";
import { rfqRowIssues } from "@/lib/rfq-bulk";
import { blankLine, type RfqLine } from "@/lib/rfq-lines";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const make = (n: number): RfqLine[] =>
  Array.from({ length: n }, (_, i) => ({
    ...blankLine(),
    productName: `Medicine ${String(i + 1).padStart(3, "0")}`,
    masterProductId: i % 2 ? "m" : null,
  }));

let host: HTMLDivElement;
let root: Root;
let latest: RfqLine[] = [];
beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});

function Harness({ initial }: { initial: RfqLine[] }) {
  const [lines, setLines] = useState(initial);
  latest = lines;
  return <RfqMedicineTable lines={lines} onChange={setLines} issues={rfqRowIssues(lines)} />;
}
const render = (lines: RfqLine[]) => act(async () => root.render(<Harness initial={lines} />));
const rows = () => host.querySelectorAll("tbody tr").length;
const button = (label: string) =>
  host.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)!;
const type = async (el: HTMLInputElement, value: string) => {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};

it("shows one page of a long list and moves between pages", async () => {
  await render(make(60));
  expect(rows()).toBe(25);
  expect(host.textContent).toContain("Showing 1–25 of 60");
  expect(host.textContent).toContain("60 / 500 medicines");
  await act(async () => button("Next page").click());
  expect(host.textContent).toContain("Showing 26–50 of 60");
  await act(async () => button("Next page").click());
  expect(rows()).toBe(10);
  expect(button("Next page").disabled).toBe(true);
});

it("searches the whole list, not just the visible page", async () => {
  await render(make(60));
  await type(
    host.querySelector<HTMLInputElement>('input[aria-label="Search this list"]')!,
    "Medicine 057",
  );
  expect(rows()).toBe(1);
  expect(host.textContent).toContain("1 of 60 lines");
});

it("selects a page, offers the whole view, and removes the selection", async () => {
  await render(make(60));
  await act(async () =>
    host
      .querySelector<HTMLButtonElement>('button[aria-label="Select all lines on this page"]')!
      .click(),
  );
  expect(host.textContent).toContain("25 selected");
  expect(host.textContent).toContain("Select all 60 in this view");
  const remove = Array.from(host.querySelectorAll("button")).find(
    (b) => b.textContent?.trim() === "Remove",
  )!;
  await act(async () => remove.click());
  // removal needs a second, explicit confirmation
  expect(latest).toHaveLength(60);
  const confirm = Array.from(host.querySelectorAll("button")).find((b) =>
    b.textContent?.includes("for good"),
  )!;
  await act(async () => confirm.click());
  expect(latest).toHaveLength(35);
  expect(host.textContent).not.toContain("selected");
});

it("flags duplicates, offers to combine them, and combines quantities", async () => {
  const lines = make(3);
  lines[1] = { ...lines[1], productName: lines[0].productName, quantity: "4" };
  lines[0] = { ...lines[0], quantity: "6" };
  await render(lines);
  expect(host.textContent).toContain("Duplicate medicine");
  const combine = Array.from(host.querySelectorAll("button")).find((b) =>
    b.textContent?.includes("Combine duplicates"),
  )!;
  await act(async () => combine.click());
  expect(latest).toHaveLength(2);
  expect(latest[0].quantity).toBe("10");
  expect(host.textContent).not.toContain("Duplicate medicine");
});

it("explains an empty list instead of showing a blank table", async () => {
  await render([]);
  expect(host.textContent).toContain("No medicines yet");
  expect(host.querySelector("table")).toBeNull();
});
