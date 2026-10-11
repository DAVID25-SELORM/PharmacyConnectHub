// @vitest-environment jsdom
import { act, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { supply } = vi.hoisted(() => ({ supply: vi.fn() }));
vi.mock("@/lib/order-supply", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  loadOrderSupply: supply,
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: vi.fn().mockResolvedValue({ data: [], error: null }) },
}));
vi.mock("@/components/orders/SupplyChangePanel", () => ({ SupplyChangePanel: () => null }));
vi.mock("@/components/orders/DeliveryCheckPanel", () => ({ DeliveryCheckPanel: () => null }));
vi.mock("@/components/orders/OrderActivityTimeline", () => ({ OrderActivityTimeline: () => null }));
vi.mock("@/components/orders/OnlinePaymentPanel", () => ({ OnlinePaymentPanel: () => null }));
vi.mock("@/components/delivery/DeliveryPanel", () => ({ DeliveryPanel: () => null }));
import { OrdersView } from "@/routes/pharmacy";

const order = {
  id: "00000000-0000-0000-0000-000000000001",
  pharmacy_id: "p",
  order_number: "ORD-TEST",
  status: "delivered",
  total_ghs: 27,
  payment_method: "cod",
  payment_status: "paid",
  is_credit_order: true,
  created_at: "2026-10-01T00:00:00Z",
  detailLoaded: true,
  item_count: 1,
  wholesaler: { name: "Supplier" },
  pharmacy: { name: "Buyer" },
  order_items: [
    { product_name: "Amlodipine", quantity: 10, supplied_quantity: 4, unit_price_ghs: 2.7 },
  ],
};
let root: Root;
let host: HTMLDivElement;
const load = vi.fn().mockResolvedValue(undefined);
const detail = vi.fn().mockResolvedValue(order);
async function render(orders: unknown[] = [order], overrides = {}) {
  await act(async () =>
    root.render(
      <OrdersView
        {...({
          orders,
          totalCount: 1,
          counts: { active: 0, awaiting: 0, transit: 0, delivered: 1 },
          loading: false,
          error: null,
          loadOrders: load,
          loadOrderDetail: detail,
          wholesalers: [],
          ...overrides,
        } as any)}
      />,
    ),
  );
}
async function click(name: string) {
  const button = [...host.querySelectorAll("button")].find(
    (b) => b.getAttribute("aria-label") === name || b.textContent === name,
  );
  expect(button, name).toBeTruthy();
  await act(async () => button!.click());
}
beforeEach(() => {
  (
    globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
  ).IS_REACT_ACT_ENVIRONMENT = true;
  window.history.replaceState({}, "", "/pharmacy?tab=orders");
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  supply.mockReset().mockResolvedValue({});
  load.mockClear();
  detail.mockClear();
  window.HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});

describe("orders audit UI regressions", () => {
  it("keeps payment method consistent and uses supplied line amounts", async () => {
    await render();
    await click("View order ORD-TEST");
    expect(host.textContent).toContain("Credit");
    expect(host.textContent).not.toContain("COD paid");
    expect(host.textContent).toContain("10.80");
    expect(host.textContent).not.toContain("being prepared");
  });
  it("never exposes an invoice from an expanded summary without details", async () => {
    await render();
    await click("View order ORD-TEST");
    expect(host.textContent).toContain("Invoice copy");
    await render([]);
    await render([{ ...order, detailLoaded: false, order_items: [] }]);
    expect(host.textContent).toContain("Reload details");
    expect(host.textContent).not.toContain("Invoice copy");
  });
  it("blocks financial documents when supply lookup fails", async () => {
    supply.mockRejectedValue(new Error("offline"));
    await render();
    await click("View order ORD-TEST");
    expect(host.textContent).toContain("Supply details could not be verified");
    expect(host.textContent).not.toContain("Invoice copy");
    expect(host.textContent).toContain("Amount unavailable");
  });
  it("names filters, announces selected status, and hides stale rows while loading", async () => {
    await render();
    expect(
      [...host.querySelectorAll('[role="combobox"]')].every(
        (el) => !!el.getAttribute("aria-label"),
      ),
    ).toBe(true);
    expect(host.querySelector('[aria-pressed="true"]')?.textContent).toBe("All");
    await render([order], { loading: true });
    expect(host.textContent).toContain("Loading orders");
    expect(host.textContent).not.toContain("ORD-TEST");
  });
  it("opens an authorized linked order even when absent from the page", async () => {
    window.history.replaceState({}, "", `/pharmacy?tab=orders&order=${order.id}`);
    await render([]);
    expect(detail).toHaveBeenCalledWith(order.id);
    expect(host.textContent).toContain("ORD-TEST");
    expect(host.textContent).toContain("Invoice copy");
  });
});
