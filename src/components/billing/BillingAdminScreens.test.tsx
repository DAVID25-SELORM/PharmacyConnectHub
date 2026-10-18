// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
const tables = vi.hoisted(() => ({
  data: {} as Record<string, unknown[]>,
  fail: {} as Record<string, string>,
  calls: [] as { table: string; method: string; args: unknown[] }[],
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock("@/integrations/supabase/client", () => {
  // A query that can be built with any of the usual filters and awaited for its rows. Every call is recorded.
  const chain = (table: string, rows: unknown[]) => {
    const q: Record<string, unknown> = {};
    for (const m of ["select", "eq", "is", "not", "order", "limit", "ilike", "in"])
      q[m] = (...args: unknown[]) => {
        tables.calls.push({ table, method: m, args });
        return q;
      };
    q.then = (resolve: (v: unknown) => unknown) =>
      resolve(
        tables.fail[table]
          ? { data: null, error: { message: tables.fail[table] } }
          : { data: rows, error: null },
      );
    return q;
  };
  return { supabase: { from: (t: string) => chain(t, tables.data[t] ?? []), rpc } };
});

import { PlatformModeCard } from "./PlatformModeCard";
import { StartSubscriptionDialog } from "./StartSubscriptionDialog";
import { plansFor } from "@/lib/billing-plans";
import type { PlanRow } from "@/lib/billing";
import type { RolloutStatus } from "@/lib/billing-rollout";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
vi.setConfig({ testTimeout: 30_000 });

// Radix Select and Dialog expect a few browser APIs that jsdom leaves out.
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
  tables.data = {};
  tables.fail = {};
  tables.calls = [];
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  document.body.innerHTML = "";
});
const render = (node: React.ReactNode) => act(async () => root.render(node));
const flush = () => act(async () => void (await new Promise((r) => setTimeout(r, 0))));
// Prefers the open dialog's button over a page button with the same words behind it.
const buttonIn = (text: string, scope?: ParentNode) => {
  const roots = scope
    ? [scope]
    : [...document.body.querySelectorAll('[role="dialog"]'), document.body];
  for (const r of roots) {
    const hit = Array.from(r.querySelectorAll("button")).find(
      (b) => b.textContent?.trim() === text,
    );
    if (hit) return hit;
  }
  throw new Error(`No button "${text}"`);
};
const type = async (el: HTMLInputElement | HTMLTextAreaElement, value: string) => {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement : HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(proto.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};
const byLabel = (text: string) => {
  const label = Array.from(document.body.querySelectorAll("label")).find((l) =>
    l.textContent?.includes(text),
  )!;
  return document.getElementById(label.htmlFor) as HTMLInputElement;
};
const typeLabel = (text: string, value: string) => type(byLabel(text), value);
const reasonBox = () => document.body.querySelector<HTMLTextAreaElement>("textarea")!;
const alertText = () => document.body.querySelector('[role="alert"]')?.textContent ?? "";

const version = (over: Record<string, unknown> = {}) => ({
  version: 1,
  status: "published",
  subscription_amount: 199,
  free_trial_days: 30,
  onboarding_free_orders: 20,
  monthly_free_orders: 5,
  transaction_fee_percentage: 1.5,
  transaction_fee_min: 2,
  transaction_fee_max: 250,
  transaction_fee_cycle_cap: null,
  billing_interval_months: 1,
  currency: "GHS",
  min_billable_order_amount: null,
  max_users: null,
  max_branches: null,
  entitlements: { reports: true },
  metadata: { tier: "growth" },
  ...over,
});
const growth = (over: Partial<PlanRow> = {}): PlanRow =>
  ({
    id: "plan-1",
    code: "wholesale-growth",
    name: "Growth",
    business_type: "wholesaler",
    kind: "standard",
    active: true,
    publicly_visible: false,
    billing_plan_versions: [version()],
    ...over,
  }) as PlanRow;

// ---------- start a subscription ----------

it("lists only plans that are on and published, for the business's own kind", () => {
  const plans = [
    growth(),
    growth({ code: "off", active: false }),
    growth({ code: "draft", billing_plan_versions: [version({ status: "retired" })] }),
    growth({ code: "pharm", business_type: "pharmacy" }),
  ];
  expect(plansFor(plans, "wholesaler").map((p) => p.code)).toEqual(["wholesale-growth"]);
  expect(plansFor(plans, "pharmacy").map((p) => p.code)).toEqual(["pharm"]);
});

it("asks the database for approved businesses with no subscription, and never sends a list of ids back", async () => {
  tables.data.businesses = [
    { id: "b2", name: "Beta Wholesale", type: "wholesaler", billing_subscriptions: null },
  ];
  tables.data.billing_plans = [growth()];
  await render(<StartSubscriptionDialog open onClose={() => {}} onDone={() => {}} />);
  await flush();
  const list = document.body.querySelector('[data-testid="subscription-candidates"]')!;
  expect(list.textContent).toContain("Beta Wholesale");

  const mine = tables.calls.filter((c) => c.table === "businesses");
  const has = (method: string, ...args: unknown[]) =>
    mine.some((c) => c.method === method && JSON.stringify(c.args) === JSON.stringify(args));
  expect(has("select", "id, name, type, billing_subscriptions(id)")).toBe(true);
  expect(has("eq", "verification_status", "approved")).toBe(true);
  expect(has("is", "billing_subscriptions", null)).toBe(true);
  expect(has("limit", 50)).toBe(true);
  // the old way: a second request carrying every business id, which is rejected as too long
  expect(tables.calls.some((c) => c.method === "in")).toBe(false);
  expect(tables.calls.some((c) => c.table === "billing_subscriptions")).toBe(false);
});

it("says so, in the list, when the businesses cannot be loaded", async () => {
  tables.fail.businesses = "Request-URI Too Long";
  tables.data.billing_plans = [growth()];
  await render(<StartSubscriptionDialog open onClose={() => {}} onDone={() => {}} />);
  await flush();
  const list = document.body.querySelector('[data-testid="subscription-candidates"]')!;
  expect(list.querySelector('[data-testid="candidates-error"]')?.textContent).toBe(
    "Request-URI Too Long",
  );
  expect(list.textContent).not.toContain("No approved business");
});

it("needs a business, a plan and a reason, then sends a shadow start", async () => {
  tables.data.businesses = [{ id: "b2", name: "Beta Wholesale", type: "wholesaler" }];
  tables.data.billing_subscriptions = [];
  tables.data.billing_plans = [growth()];
  rpc.mockResolvedValue({ data: { subscription_id: "s1", launch_grant: "granted" }, error: null });
  const done = vi.fn();
  await render(<StartSubscriptionDialog open onClose={() => {}} onDone={done} />);
  await flush();

  await act(async () => buttonIn("Start subscription").click());
  expect(document.body.querySelector('[data-testid="subscription-error"]')?.textContent).toContain(
    "Choose the business",
  );

  await act(async () =>
    Array.from(
      document.body.querySelectorAll<HTMLButtonElement>(
        '[data-testid="subscription-candidates"] button',
      ),
    )
      .find((b) => b.textContent?.includes("Beta Wholesale"))!
      .click(),
  );
  await act(async () => buttonIn("Start subscription").click());
  expect(document.body.querySelector('[data-testid="subscription-error"]')?.textContent).toContain(
    "Choose the plan",
  );

  // pick the plan with the keyboard, the way Radix expects
  const trigger = document.body.querySelector<HTMLButtonElement>("#ss-plan")!;
  await act(async () => {
    trigger.focus();
    trigger.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  });
  const option = Array.from(document.body.querySelectorAll('[role="option"]')).find((o) =>
    o.textContent?.includes("wholesale-growth"),
  ) as HTMLElement;
  expect(option).toBeTruthy();
  await act(async () => {
    option.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
    option.click();
  });

  await act(async () => buttonIn("Start subscription").click());
  expect(document.body.querySelector('[data-testid="subscription-error"]')?.textContent).toContain(
    "reason",
  );
  expect(rpc).not.toHaveBeenCalled();

  await type(reasonBox(), "Pilot wholesaler, shadow first");
  await act(async () => buttonIn("Start subscription").click());
  expect(rpc).toHaveBeenCalledWith("admin_billing_start_subscription", {
    p_business_id: "b2",
    p_plan_code: "wholesale-growth",
    p_billing_starts_at: null,
    p_billing_mode: "shadow",
    p_reason: "Pilot wholesaler, shadow first",
  });
  expect(done).toHaveBeenCalled();
});

// ---------- platform mode and run now ----------

const status = (mode: "disabled" | "shadow" | "active", over: Partial<RolloutStatus["run"]> = {}) =>
  ({
    platform: { mode },
    run: {
      last_run_at: "2026-10-14T08:00:00Z",
      runs: 12,
      minutes_since: 7,
      stale: false,
      last_result: { assessed: 4, invoices_issued: 0 },
      ...over,
    },
  }) as unknown as RolloutStatus;

it("offers shadow from off, and off from shadow or on, but never switches real billing on", async () => {
  await render(<PlatformModeCard status={status("disabled")} onChanged={() => {}} />);
  expect(host.querySelector('[data-testid="to-shadow"]')).not.toBeNull();
  expect(host.querySelector('[data-testid="to-off"]')).toBeNull();
  expect(host.textContent).toContain("Last run 7 minutes ago");
  expect(host.textContent).toContain("assessed: 4");

  for (const m of ["shadow", "active"] as const) {
    await render(<PlatformModeCard status={status(m)} onChanged={() => {}} />);
    expect(host.querySelector('[data-testid="to-shadow"]')).toBeNull();
    expect(host.querySelector('[data-testid="to-off"]')).not.toBeNull();
  }
});

it("switches to shadow with a reason and reloads", async () => {
  rpc.mockResolvedValue({ data: "shadow", error: null });
  const changed = vi.fn();
  await render(<PlatformModeCard status={status("disabled")} onChanged={changed} />);
  await act(async () =>
    host.querySelector<HTMLButtonElement>('[data-testid="to-shadow"]')!.click(),
  );
  await act(async () => buttonIn("Switch to shadow").click());
  expect(alertText()).toContain("reason");
  await type(reasonBox(), "Start the 14 day shadow run");
  await act(async () => buttonIn("Switch to shadow").click());
  expect(rpc).toHaveBeenCalledWith("admin_billing_set_mode", {
    p_mode: "shadow",
    p_reason: "Start the 14 day shadow run",
  });
  expect(changed).toHaveBeenCalled();
});

it("warns what switching live billing off does, and runs the job on request", async () => {
  rpc.mockResolvedValue({ data: { assessed: 2 }, error: null });
  await render(<PlatformModeCard status={status("active")} onChanged={() => {}} />);
  await act(async () => host.querySelector<HTMLButtonElement>('[data-testid="to-off"]')!.click());
  expect(document.body.textContent).toContain("catches up on the orders it missed");
  await act(async () => buttonIn("Cancel").click());

  await act(async () => host.querySelector<HTMLButtonElement>('[data-testid="run-now"]')!.click());
  await type(reasonBox(), "Check the figures before the meeting");
  await act(async () => buttonIn("Run now").click());
  expect(rpc).toHaveBeenCalledWith("admin_billing_run_now", {
    p_reason: "Check the figures before the meeting",
  });
});

it("says plainly when the scheduled run has never run", async () => {
  await render(
    <PlatformModeCard
      status={status("shadow", { last_run_at: null, minutes_since: null, last_result: {} })}
      onChanged={() => {}}
    />,
  );
  expect(host.textContent).toContain("never run");
});
