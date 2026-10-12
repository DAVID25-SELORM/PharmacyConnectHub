// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  rpc: vi.fn(),
  block: vi.fn(),
  receive: vi.fn(),
  status: "issued",
  fail: false,
}));
vi.mock("./ProcurementTemplates", () => ({ ProcurementTemplates: () => null }));
vi.mock("./ProcurementCatalogue", () => ({ ProcurementCatalogue: () => null }));
vi.mock("@tanstack/react-router", () => ({ useBlocker: mocks.block }));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc: mocks.rpc,
    from: (table: string) => {
      let single = false;
      const result = () => ({
        error: null,
        count: 1,
        data:
          table === "external_supply_orders"
            ? single
              ? order()
              : [order()]
            : table === "external_purchases"
              ? [
                  {
                    id: "receipt",
                    reference: "EXT-1",
                    review_status: "draft",
                    external_order_allocations: [
                      { line_id: "line", product_name: "Medicine", quantity: 12 },
                    ],
                  },
                ]
              : [],
      });
      const query: Record<string, unknown> = {};
      for (const method of ["select", "eq", "neq", "order", "range"]) query[method] = () => query;
      query.single = () => {
        single = true;
        return Promise.resolve(result());
      };
      query.then = (fn: (value: unknown) => unknown) => Promise.resolve(result()).then(fn);
      return query;
    },
  },
}));
function order() {
  return {
    id: "order",
    pharmacy_id: "pharmacy",
    reference: "EPO-1",
    kind: "order",
    status: mocks.status,
    version: 2,
    issued_at: mocks.status === "draft" ? null : "2026-10-11",
    issuer: { name: "Pharmacy" },
    data: {
      kind: "order",
      supplier: "Outside supplier",
      supplier_contact: "",
      required_date: "",
      delivery_address: "",
      notes: "",
      lines: [{ id: "line", name: "Medicine", specification: "", quantity: 20, unit_price: 5 }],
    },
  };
}
import { ConfirmationHost } from "@/lib/confirm-action";
import { ExternalSupplyOrders } from "./ExternalSupplyOrders";
let host: HTMLDivElement, root: Root;
beforeEach(() => {
  mocks.status = "issued";
  mocks.rpc.mockReset().mockImplementation(async (name: string) => ({ data: name === "procurement_suppliers" ? [] : "order", error: null }));
  mocks.receive.mockReset();
  vi.spyOn(window, "confirm").mockReturnValue(true);
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.restoreAllMocks();
});
async function render(canRecord = true) {
  await act(async () =>
    root.render(
      <>
        {" "}
        <ConfirmationHost />
        <ExternalSupplyOrders
          pharmacyId="pharmacy"
          canRecord={canRecord}
          onReceive={mocks.receive}
          onReceipt={() => {}}
        />
      </>,
    ),
  );
}
async function click(text: string) {
  const buttons = Array.from(document.querySelectorAll("button"));
  const button = buttons.find((b) => b.textContent?.trim() === text) ?? buttons.find((b) => b.textContent?.includes(text));
  expect(button).toBeTruthy();
  await act(async () => button!.click());
}
it("opens outstanding quantities and prepares a partial receipt without writing stock", async () => {
  await render();
  await click("EPO-1");
  expect(document.body.textContent).toContain("partially received");
  await click("Record delivery against order");
  expect(mocks.receive).toHaveBeenCalledWith(
    expect.objectContaining({
      external_order_id: "order",
      items: [expect.objectContaining({ quantity: 8 })],
    }),
  );
  expect(mocks.rpc.mock.calls.filter(([name]) => name !== "procurement_suppliers")).toHaveLength(0);
});
it("requires a separate user confirmation to mark a document shared", async () => {
  await render();
  await click("EPO-1");
  expect(mocks.rpc.mock.calls.filter(([name]) => name !== "procurement_suppliers")).toHaveLength(0);
  await click("Mark as shared manually");
  expect(window.confirm).not.toHaveBeenCalled();
  expect(mocks.rpc.mock.calls.filter(([name]) => name !== "procurement_suppliers")).toHaveLength(0);
  await click("Continue");
  expect(mocks.rpc).toHaveBeenCalledWith("transition_external_supply_order", {
    p_id: "order",
    p_version: 2,
    p_action: "shared",
  });
});
it("read-only users cannot create, issue or receive orders", async () => {
  await render(false);
  await click("EPO-1");
  for (const label of [
    "New request / order",
    "Record delivery against order",
    "Mark as shared manually",
    "Cancel remaining order",
  ])
    expect(document.body.textContent).not.toContain(label);
});
it("preserves the editable draft after a failed save", async () => {
  mocks.status = "draft";
  await render();
  await click("EPO-1");
  await click("Continue / edit draft");
  mocks.rpc.mockResolvedValueOnce({ data: null, error: { message: "Offline" } });
  await act(async () =>
    document
      .querySelector("form")!
      .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(document.querySelector("form")).toBeTruthy();
  expect(mocks.rpc).toHaveBeenCalledWith(
    "save_external_supply_order",
    expect.objectContaining({ p_pharmacy_id: "pharmacy", p_id: "order", p_version: 2 }),
  );
});

it("keeps the document unchanged when an in-app confirmation is dismissed", async () => {
  await render();
  await click("EPO-1");
  await click("Mark as shared manually");
  await click("Keep working");
  expect(mocks.rpc.mock.calls.filter(([name]) => name !== "procurement_suppliers")).toHaveLength(0);
  expect(window.confirm).not.toHaveBeenCalled();
});
it("removes a draft through the versioned cancellation RPC, preserving its history", async () => {
  mocks.status = "draft";
  await render();
  await click("EPO-1");
  await click("Remove draft");
  expect(mocks.rpc.mock.calls.filter(([name]) => name !== "procurement_suppliers")).toHaveLength(0);
  await click("Continue");
  expect(mocks.rpc).toHaveBeenCalledWith("transition_external_supply_order", {
    p_id: "order",
    p_version: 2,
    p_action: "cancelled",
  });
});

it("creates a revised draft without changing the issued document", async () => {
  await render();
  await click("EPO-1");
  await click("Create revised draft");
  expect(document.querySelector("form")).toBeTruthy();
  expect((document.querySelector("textarea") as HTMLTextAreaElement).value).toContain("Revised from EPO-1");
  expect(mocks.rpc.mock.calls.filter(([name]) => name !== "procurement_suppliers")).toHaveLength(0);
});
