// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({}) } }));

import { RfqAwards } from "./RfqAwards";
import { RfqListTable } from "./RfqListTable";
import { RfqNegotiations, type Negotiation } from "./RfqNegotiations";
import { RfqReasonDialog } from "./RfqReasonDialog";
import type { Allocation, AwardGroup, EnterpriseRfq } from "@/lib/enterprise-rfq";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
// Rendering long lists in jsdom is slow on a busy machine; the default 5 s is too tight.
vi.setConfig({ testTimeout: 30_000 });

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
const render = (node: React.ReactNode) => act(async () => root.render(node));
const button = (text: string, scope: ParentNode = document) =>
  Array.from(scope.querySelectorAll("button")).find((b) => b.textContent?.trim() === text)!;

const rfq = (over: Partial<EnterpriseRfq> = {}): EnterpriseRfq =>
  ({
    id: "r1",
    reference: "RFQ-1",
    title: "Antibiotics restock",
    status: "open",
    enterprise: true,
    quote_count: 3,
    response_deadline: new Date(Date.now() + 3 * 86_400_000).toISOString(),
    created_at: "2026-10-01T00:00:00Z",
    ...over,
  }) as EnterpriseRfq;

it("lists requests with status, quotation count and deadline, and opens one by click or keyboard", async () => {
  const onOpen = vi.fn();
  await render(
    <RfqListTable
      rows={[
        rfq(),
        rfq({
          id: "r2",
          reference: "RFQ-2",
          title: "Old one",
          enterprise: false,
          status: "draft",
          quote_count: 0,
          response_deadline: null,
        }),
      ]}
      loading={false}
      count={2}
      page={0}
      onPage={() => {}}
      onOpen={onOpen}
    />,
  );
  expect(host.textContent).toContain("Antibiotics restock");
  expect(host.textContent).toContain("Legacy RFQ");
  expect(host.textContent).toContain("Closes in 3 days");
  expect(host.textContent).toContain("No deadline");
  const first = host.querySelector<HTMLElement>('tr[aria-label^="Open RFQ-1"]')!;
  await act(async () => first.click());
  expect(onOpen).toHaveBeenCalledWith(expect.objectContaining({ id: "r1" }));
  const second = host.querySelector<HTMLElement>('tr[aria-label^="Open RFQ-2"]')!;
  await act(async () => {
    second.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(onOpen).toHaveBeenCalledWith(expect.objectContaining({ id: "r2" }));
});

it("says so when nothing matches, and while loading", async () => {
  await render(
    <RfqListTable
      rows={[]}
      loading={false}
      count={0}
      page={0}
      onPage={() => {}}
      onOpen={() => {}}
    />,
  );
  expect(host.textContent).toContain("No matching requests");
  await render(
    <RfqListTable rows={[]} loading count={0} page={0} onPage={() => {}} onOpen={() => {}} />,
  );
  expect(host.textContent).toContain("Loading requests");
});

const group = (over: Partial<AwardGroup> = {}): AwardGroup =>
  ({
    id: "g1",
    quote_version_id: "v",
    wholesaler_id: "w1",
    status: "pending",
    order_id: null,
    goods_ghs: 100,
    delivery_ghs: 20,
    settlement_method: "cod",
    reason: null,
    last_error: null,
    ...over,
  }) as AwardGroup;
const allocs: Allocation[] = [
  { id: "a", group_id: "g1" } as Allocation,
  { id: "b", group_id: "g1" } as Allocation,
];

it("lets a supplier confirm or decline a waiting award, and shows the buyer only the status", async () => {
  const onConfirm = vi.fn();
  const onDecline = vi.fn();
  const props = {
    groups: [group()],
    allocations: allocs,
    names: { w1: "Alpha Ltd" },
    busy: false,
    onPdf: () => {},
    onConfirm,
    onDecline,
  };
  await render(<RfqAwards {...props} buyer={false} canConfirm />);
  expect(host.textContent).toContain("Alpha Ltd");
  expect(host.textContent).toContain("120");
  await act(async () => button("Confirm and create order").click());
  expect(onConfirm).toHaveBeenCalledWith(expect.objectContaining({ id: "g1" }));
  await act(async () => button("Decline…").click());
  expect(onDecline).toHaveBeenCalled();
  await render(<RfqAwards {...props} buyer canConfirm={false} />);
  expect(host.textContent).not.toContain("Confirm and create order");
});

it("shows a failed conversion's error and a confirmed award's order link", async () => {
  await render(
    <RfqAwards
      groups={[
        group({ status: "conversion_failed", last_error: "Stock changed" }),
        group({ id: "g2", status: "confirmed", order_id: "abcdef12-0000" }),
      ]}
      allocations={allocs}
      names={{ w1: "Alpha Ltd" }}
      buyer
      canConfirm={false}
      busy={false}
      onPdf={() => {}}
      onConfirm={() => {}}
      onDecline={() => {}}
    />,
  );
  expect(host.querySelector('[role="alert"]')?.textContent).toBe("Stock changed");
  expect(host.querySelector('a[href="/pharmacy?tab=orders"]')?.textContent).toContain("abcdef12");
});

it("shows what was asked in plain terms and lets a supplier reply only to open requests", async () => {
  const onRespond = vi.fn();
  const items: Negotiation[] = [
    {
      id: "n1",
      wholesaler_id: "w1",
      status: "requested",
      proposal: { price: "9.50" },
      response: null,
    },
    {
      id: "n2",
      wholesaler_id: "w1",
      status: "accepted",
      proposal: { delivery: "2026-11-01" },
      response: "Done",
    },
  ];
  await render(
    <RfqNegotiations
      negotiations={items}
      names={{ w1: "Alpha Ltd" }}
      buyer={false}
      canRespond
      busy={false}
      onRespond={onRespond}
    />,
  );
  expect(host.textContent).toContain("Unit price: 9.50");
  expect(host.textContent).toContain("Reply: Done");
  expect(host.querySelectorAll("button").length).toBe(3);
  await act(async () => button("Counter…").click());
  expect(onRespond).toHaveBeenCalledWith(expect.objectContaining({ id: "n1" }), "countered");
});

it("will not submit an empty reason, and passes the trimmed text on", async () => {
  const onSubmit = vi.fn(async () => true);
  const onClose = vi.fn();
  await render(
    <RfqReasonDialog
      title="Cancel this request"
      label="Reason"
      confirmLabel="Cancel request"
      busy={false}
      onSubmit={onSubmit}
      onClose={onClose}
    />,
  );
  const confirm = () => button("Cancel request", document.body);
  expect(confirm().disabled).toBe(true);
  const area = document.body.querySelector<HTMLTextAreaElement>("textarea")!;
  const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(area, "  Supplier pulled out  ");
    area.dispatchEvent(new Event("input", { bubbles: true }));
  });
  expect(confirm().disabled).toBe(false);
  await act(async () => confirm().click());
  expect(onSubmit).toHaveBeenCalledWith("Supplier pulled out");
  expect(onClose).toHaveBeenCalled();
});
