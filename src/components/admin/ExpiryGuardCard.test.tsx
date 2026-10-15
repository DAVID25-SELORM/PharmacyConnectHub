// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({}), rpc } }));

import { ExpiryGuardCard } from "./ExpiryGuardCard";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
vi.setConfig({ testTimeout: 30_000 });
Element.prototype.hasPointerCapture ??= () => false;
Element.prototype.setPointerCapture ??= () => {};
Element.prototype.releasePointerCapture ??= () => {};
Element.prototype.scrollIntoView ??= () => {};
globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
} as unknown as typeof ResizeObserver;

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
const flush = () => act(async () => void (await new Promise((r) => setTimeout(r, 0))));
const byId = (id: string) => host.querySelector<HTMLElement>(`[data-testid="${id}"]`);
const type = async (el: HTMLTextAreaElement, value: string) => {
  const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};
const status = (over: Record<string, unknown> = {}) => ({
  mode: "observe",
  changed_at: "2026-10-15T10:00:00Z",
  products_with_expired_units: 3,
  expired_units: 42,
  orderable_products_with_expired_units: 2,
  products_where_batches_exceed_stock: 0,
  would_have_blocked_7_days: 1,
  would_have_blocked_30_days: 4,
  events: [
    {
      created_at: "2026-10-14T09:30:00Z",
      entry_point: "checkout",
      product_name: "Amoxicillin 500mg",
      wholesaler_name: "Alpha Wholesale",
      quantity: 15,
      stock: 20,
      expired_units: 8,
      sellable: 12,
    },
  ],
  ...over,
});
const open = async () => {
  await act(async () => root.render(<ExpiryGuardCard />));
  await flush();
};

it("shows the mode in words, what the guard saw, and the sales it would have refused", async () => {
  rpc.mockResolvedValue({ data: status(), error: null });
  await open();
  expect(byId("guard-mode")?.textContent).toBe("Observing");
  expect(byId("guard-mode-text")?.textContent).toContain("Nothing is blocked");
  const events = byId("guard-events")!.textContent!;
  expect(events).toContain("Amoxicillin 500mg");
  expect(events).toContain("Alpha Wholesale");
  expect(events).toContain("Checkout");
  expect(events).toContain("15");
  expect(events).toContain("12");
  expect(host.textContent).toContain("42");
  expect(byId("guard-advice")?.textContent).toContain("Review these before enforcing");
});

it("says enforcing looks safe when nothing would have been refused", async () => {
  rpc.mockResolvedValue({
    data: status({
      orderable_products_with_expired_units: 0,
      would_have_blocked_7_days: 0,
      events: [],
    }),
    error: null,
  });
  await open();
  expect(byId("guard-advice")?.textContent).toContain("Enforcing looks safe");
  expect(byId("guard-no-events")?.textContent).toContain("None recorded");
});

it("explains that a refused sale is not recorded once it is enforced", async () => {
  rpc.mockResolvedValue({ data: status({ mode: "enforce", events: [] }), error: null });
  await open();
  expect(byId("guard-mode")?.textContent).toBe("Enforced");
  expect(byId("guard-no-events")?.textContent).toContain("buyer sees the reason");
});

it("says plainly when the database update has not been applied, and offers no switch", async () => {
  rpc.mockResolvedValue({
    data: null,
    error: { code: "PGRST202", message: "Could not find the function" },
  });
  await open();
  expect(byId("expiry-guard-missing")?.textContent).toContain(
    "has not been added to the database yet",
  );
  expect(byId("guard-change")).toBeNull();
});

it("shows a real error as it is", async () => {
  rpc.mockResolvedValue({ data: null, error: { code: "XX000", message: "Something broke." } });
  await open();
  expect(host.querySelector('[role="alert"]')?.textContent).toBe("Something broke.");
});

it("switching the mode needs a reason, sends it, and reloads", async () => {
  rpc.mockImplementation(async (fn: string) =>
    fn === "admin_expiry_guard_status"
      ? { data: status(), error: null }
      : { data: "enforce", error: null },
  );
  await open();
  await act(async () => byId("guard-change")!.click());
  // the mode box starts on the current mode, so "change" to the same one is refused without calling the database
  const dialog = () => document.body.querySelector('[role="dialog"]')!;
  const submit = () =>
    Array.from(dialog().querySelectorAll("button")).find(
      (b) => b.textContent?.trim() === "Change mode",
    )!;
  await act(async () => submit().click());
  expect(document.body.querySelector('[role="alert"]')?.textContent).toContain("reason");
  expect(rpc.mock.calls.filter((c) => c[0] === "admin_set_expiry_guard_mode")).toHaveLength(0);
  await type(dialog().querySelector("textarea")!, "Two weeks of observing were clean");
  await act(async () => submit().click());
  expect(document.body.querySelector('[role="alert"]')?.textContent).toContain("already the mode");
  expect(rpc.mock.calls.filter((c) => c[0] === "admin_set_expiry_guard_mode")).toHaveLength(0);

  // choose "Enforced" the way Radix expects
  const trigger = document.body.querySelector<HTMLButtonElement>("#act-mode")!;
  await act(async () => {
    trigger.focus();
    trigger.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  });
  const option = Array.from(document.body.querySelectorAll('[role="option"]')).find((o) =>
    o.textContent?.startsWith("Enforced"),
  ) as HTMLElement;
  expect(option).toBeTruthy();
  await act(async () => {
    option.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
    option.click();
  });
  const statusCalls = rpc.mock.calls.filter((c) => c[0] === "admin_expiry_guard_status").length;
  await act(async () => submit().click());
  await flush();
  expect(rpc.mock.calls.filter((c) => c[0] === "admin_set_expiry_guard_mode")).toEqual([
    [
      "admin_set_expiry_guard_mode",
      { p_mode: "enforce", p_reason: "Two weeks of observing were clean" },
    ],
  ]);
  expect(rpc.mock.calls.filter((c) => c[0] === "admin_expiry_guard_status").length).toBeGreaterThan(
    statusCalls,
  );
});
