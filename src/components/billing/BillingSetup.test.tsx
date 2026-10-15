// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
const tables = vi.hoisted(() => ({ data: {} as Record<string, unknown[]> }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock("@/integrations/supabase/client", () => {
  const chain = (rows: unknown[]) => {
    const q: Record<string, unknown> = {};
    for (const m of ["select", "eq", "is", "not", "order", "limit", "ilike", "in"]) q[m] = () => q;
    q.then = (resolve: (v: unknown) => unknown) => resolve({ data: rows, error: null });
    return q;
  };
  return { supabase: { from: (t: string) => chain(tables.data[t] ?? []), rpc } };
});

import { ActivationCard } from "./AdminBillingRolloutSection";
import { BillingSetup } from "./BillingSetup";

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
  tables.data = {};
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  document.body.innerHTML = "";
});
const render = (node: React.ReactNode) => act(async () => root.render(node));
const flush = () => act(async () => void (await new Promise((r) => setTimeout(r, 0))));
const byId = (id: string) => host.querySelector<HTMLElement>(`[data-testid="${id}"]`);
const text = (id: string) => byId(id)?.textContent ?? "";
const type = async (el: HTMLInputElement | HTMLTextAreaElement, value: string) => {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement : HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(proto.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};
const button = (label: string, scope: ParentNode = document.body) => {
  const roots =
    scope === document.body
      ? [...document.body.querySelectorAll('[role="dialog"]'), document.body]
      : [scope];
  for (const r of roots) {
    const hit = Array.from(r.querySelectorAll("button")).find(
      (b) => b.textContent?.trim() === label,
    );
    if (hit) return hit as HTMLButtonElement;
  }
  throw new Error(`No button "${label}"`);
};

// ---------- fixtures ----------
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
  entitlements: { advanced_analytics: true },
  metadata: {},
  ...over,
});
const wholesalePlan = (over: Record<string, unknown> = {}) => ({
  id: "plan-w",
  code: "wholesale-standard",
  name: "Wholesale Standard",
  business_type: "wholesaler",
  kind: "standard",
  active: true,
  publicly_visible: false,
  billing_plan_versions: [version()],
  ...over,
});
const check = (key: string, label: string, over: Record<string, unknown> = {}) => ({
  key,
  label,
  blocking: true,
  ok: true,
  detail: "",
  ...over,
});
type World = {
  mode?: "disabled" | "shadow" | "active";
  failing?: string[];
  days?: number;
  orders?: number;
  live?: number;
  recon?: Record<string, number> | "error";
  review?: "unavailable" | { fee_formula?: number; rows?: unknown[] };
};
function world(w: World = {}) {
  const failing = w.failing ?? [];
  const checks = [
    check("zero_commission", "Paystack platform commission is zero"),
    check("subscriptions", "At least one business has a subscription", {
      detail: "2 subscriptions",
    }),
    check("reconciliation", "The billing books agree"),
    check("scheduler", "The scheduled billing run is running", { detail: "Last ran today" }),
    check("issuer", "Invoices say who they are from and how to pay"),
    check("plans", "There is a switched-on plan with a published version for wholesalers"),
    check("shadow_history", "Shadow billing has run for at least 14 days", { blocking: false }),
    check("terms", "Payment terms", { blocking: false, detail: "14 days to pay" }),
  ].map((c) => (failing.includes(c.key) ? { ...c, ok: false } : c));
  const readiness = {
    platform_mode: w.mode ?? "shadow",
    ready: failing.length === 0,
    checks,
    shadow: {
      since: "2026-09-20T00:00:00Z",
      days: w.days ?? 20,
      businesses: 3,
      orders_assessed: w.orders ?? 120,
      estimated_revenue: 840,
    },
    live: { live: w.live ?? 0, held_back: 3, disabled: 0, waiting: 0 },
  };
  const recon = {
    checked_at: "2026-10-14T10:00:00Z",
    healthy: !w.recon,
    checks: [
      {
        check: "delivered_order_not_assessed",
        severity: "critical",
        count: typeof w.recon === "object" ? (w.recon.delivered_order_not_assessed ?? 0) : 0,
        details: [],
      },
    ],
  };
  const reviewBody = {
    checked_at: "2026-10-14T10:00:00Z",
    assessments_total: 120,
    recomputed: 100,
    recorded_fee_total: 840,
    recalculated_fee_total: 840,
    checks: [
      {
        key: "fee_formula",
        label: "Each fee matches the order value and the plan terms",
        severity: "critical",
        count: typeof w.review === "object" ? (w.review.fee_formula ?? 0) : 0,
      },
    ],
    rows: typeof w.review === "object" ? (w.review.rows ?? []) : [],
  };
  rpc.mockImplementation(async (fn: string) => {
    switch (fn) {
      case "admin_billing_readiness":
        return { data: readiness, error: null };
      case "admin_billing_reconciliation":
        return w.recon === "error"
          ? { data: null, error: { message: "Reconciliation is unavailable." } }
          : { data: recon, error: null };
      case "admin_billing_shadow_review":
        return w.review === "unavailable"
          ? { data: null, error: { code: "PGRST202", message: "Could not find the function" } }
          : { data: reviewBody, error: null };
      case "admin_billing_organizations":
        return { data: { total: 0, rows: [] }, error: null };
      default:
        return { data: null, error: null };
    }
  });
  tables.data.billing_plans = [wholesalePlan()];
}
const open = async () => {
  await render(<BillingSetup />);
  await flush();
  await flush();
};
const calls = (fn: string) => rpc.mock.calls.filter((c) => c[0] === fn);

// ---------- the page ----------

it("shows what stops activation, in plain words, with the four stages", async () => {
  world({
    mode: "disabled",
    failing: ["zero_commission", "issuer", "subscriptions", "scheduler"],
    days: 0,
    orders: 0,
  });
  await open();
  expect(text("setup-headline")).toMatch(/things stop activation/);
  const blockers = byId("setup-blockers")!.textContent!;
  expect(blockers).toContain("Paystack platform commission is zero");
  expect(blockers).toContain("Invoices say who they are from and how to pay");
  expect(blockers).toContain("The shadow test has been started");
  for (const k of ["configure", "invoices", "shadow", "activate"])
    expect(byId(`stage-tile-${k}`)).not.toBeNull();
  expect(host.textContent).toContain("Configure Billing");
  expect(host.textContent).toContain("Set Up Invoices");
  expect(host.textContent).toContain("Run 14-Day Shadow Test");
  expect(host.textContent).toContain("Activate Pilot Businesses");
  expect(text("stage-status-configure")).toBe("In progress");
  // the stage with something to do is open; the others are folded away
  expect(byId("items-configure")).not.toBeNull();
  expect(byId("items-activate")).toBeNull();
  // activation is locked and offers no switch
  expect(byId("activation-card")).toBeNull();
});

it("keeps real billing locked until the shadow test is complete, and says what is missing", async () => {
  world({ days: 4 });
  await open();
  expect(text("setup-headline")).toBe("1 thing stops activation");
  expect(text("setup-blockers")).toContain("The test has run for 14 days");
  await act(async () => byId("stage-tile-activate")!.click());
  expect(byId("activation-locked")?.textContent).toContain("Locked");
  expect(byId("activation-card")).toBeNull();
  expect(calls("admin_billing_activate_platform")).toHaveLength(0);
});

it("offers the switch only when everything is done, with every business held back", async () => {
  world();
  await open();
  expect(text("setup-headline")).toBe("Ready to activate pilot businesses");
  expect(byId("setup-blockers")).toBeNull();
  expect(text("stage-status-activate")).toBe("In progress");
  expect(byId("activation-card")).not.toBeNull();
  // hold-back cannot be switched off from this page
  expect(byId("hold-back-locked")).not.toBeNull();
  expect(host.querySelector('input[type="checkbox"]')).toBeNull();

  const go = host.querySelector<HTMLButtonElement>('[data-testid="activate-billing"]')!;
  expect(go.disabled).toBe(true);
  await type(host.querySelector<HTMLInputElement>("#act-phrase")!, "ACTIVATE BILLING");
  expect(go.disabled).toBe(true); // a reason is still needed
  await type(host.querySelector<HTMLTextAreaElement>("#act-why")!, "Pilot wholesalers are ready");
  expect(go.disabled).toBe(false);
  await act(async () => go.click());
  expect(calls("admin_billing_activate_platform")).toEqual([
    [
      "admin_billing_activate_platform",
      {
        p_hold_back: true,
        p_confirmation: "ACTIVATE BILLING",
        p_reason: "Pilot wholesalers are ready",
      },
    ],
  ]);
});

it("never offers the switch while the independent recalculation disagrees, and shows both figures", async () => {
  world({
    failing: [],
    review: {
      fee_formula: 1,
      rows: [
        {
          check: "fee_formula",
          order_id: "o1",
          order_number: "ORD-0042",
          business_name: "Beta Wholesale",
          recorded: 75.5,
          recalculated: 75,
          difference: 0.5,
          note: "The fee should be 75.00 for an order value of 10000.00 at 0.7500%",
        },
      ],
    },
  });
  await open();
  expect(text("setup-headline")).toBe("1 thing stops activation");
  expect(text("setup-blockers")).toContain("Every shadow fee matches its recalculation");
  expect(text("stage-status-shadow")).toBe("Needs attention");
  expect(byId("activation-card")).toBeNull();
  await act(async () => byId("stage-tile-shadow")!.click());
  const rows = byId("review-rows")!;
  expect(rows.textContent).toContain("ORD-0042");
  expect(rows.textContent).toContain("Beta Wholesale");
  expect(rows.textContent).toContain("75.50");
  expect(rows.textContent).toContain("75.00");
  expect(rows.textContent).toContain("0.50");
  expect(text("checks-headline")).toBe("1 thing needs attention. Nothing was changed.");
});

it("a reconciliation finding blocks activation and is listed by its name", async () => {
  world({ failing: ["reconciliation"], recon: { delivered_order_not_assessed: 3 } });
  await open();
  expect(byId("activation-card")).toBeNull();
  await act(async () => byId("stage-tile-shadow")!.click());
  expect(text("reconciliation-problems")).toContain("Delivered orders that were not assessed");
  expect(text("reconciliation-problems")).toContain("3");
});

it("does not block on a review that has not been added to the database yet, and says so", async () => {
  world({ review: "unavailable" });
  await open();
  expect(text("setup-headline")).toBe("Ready to activate pilot businesses");
  await act(async () => byId("stage-tile-shadow")!.click());
  expect(text("review-unavailable")).toContain("not available yet");
});

it("treats a reconciliation that cannot run as not agreeing", async () => {
  world({ recon: "error" });
  await open();
  expect(text("setup-headline")).toBe("1 thing stops activation");
  expect(text("setup-blockers")).toContain("The billing books agree (reconciliation)");
  await act(async () => byId("stage-tile-shadow")!.click());
  expect(host.textContent).toContain("Reconciliation is unavailable.");
});

it("shows the pilot businesses to put live, not the switch, once real billing is on", async () => {
  world({ mode: "active", live: 0 });
  await open();
  expect(text("setup-headline")).toBe("Real billing is on");
  expect(byId("activation-card")).toBeNull();
  await act(async () => byId("stage-tile-activate")!.click());
  expect(byId("pilot-table")).not.toBeNull();
  expect(calls("admin_billing_activate_platform")).toHaveLength(0);
});

it("starts the shadow test with a reason, then reloads", async () => {
  world({ mode: "disabled", failing: ["scheduler"], days: 0, orders: 0 });
  await open();
  await act(async () => byId("stage-tile-shadow")!.click());
  await act(async () => byId("start-shadow")!.click());
  await act(async () => button("Switch to shadow").click());
  expect(document.body.querySelector('[role="alert"]')?.textContent).toContain("reason");
  expect(calls("admin_billing_set_mode")).toHaveLength(0);
  await type(
    document.body.querySelector<HTMLTextAreaElement>("textarea")!,
    "Start the 14 day shadow test",
  );
  const before = calls("admin_billing_readiness").length;
  await act(async () => button("Switch to shadow").click());
  await flush();
  expect(calls("admin_billing_set_mode")).toEqual([
    ["admin_billing_set_mode", { p_mode: "shadow", p_reason: "Start the 14 day shadow test" }],
  ]);
  expect(calls("admin_billing_readiness").length).toBeGreaterThan(before);
});

it("saves wholesaler pricing through the audited operations and keeps what the form does not edit", async () => {
  world();
  await open();
  await act(async () => byId("stage-tile-configure")!.click());
  await type(host.querySelector<HTMLInputElement>("#price-wholesaler-subscription_amount")!, "249");
  expect(text("pricing-changes-wholesaler")).toContain("199 → 249");
  expect(text("pricing-preview-wholesaler")).toContain("publish version 2 (replacing version 1)");
  const save = host.querySelector<HTMLButtonElement>('[data-testid="pricing-save-wholesaler"]')!;
  await act(async () => save.click());
  expect(text("pricing-error-wholesaler")).toContain("reason");
  expect(calls("admin_billing_publish_plan_version")).toHaveLength(0);
  await type(
    host.querySelector<HTMLTextAreaElement>("#price-wholesaler-reason")!,
    "Launch pricing for the pilot",
  );
  await act(async () => save.click());
  const [, args] = calls("admin_billing_publish_plan_version")[0];
  expect(args).toMatchObject({ p_plan_id: "plan-w", p_reason: "Launch pricing for the pilot" });
  expect(args.p_params).toMatchObject({
    subscription_amount: 249,
    transaction_fee_percentage: 1.5,
    currency: "GHS",
    entitlements: { advanced_analytics: true },
  });
  // the plan is already on, so it is not switched on again, and no second plan is made
  expect(calls("admin_billing_set_plan_availability")).toHaveLength(0);
  expect(calls("admin_billing_create_plan")).toHaveLength(0);
});

it("will not save an impossible fee, and shows why", async () => {
  world();
  await open();
  await act(async () => byId("stage-tile-configure")!.click());
  await type(
    host.querySelector<HTMLInputElement>("#price-wholesaler-transaction_fee_percentage")!,
    "150",
  );
  await type(
    host.querySelector<HTMLTextAreaElement>("#price-wholesaler-reason")!,
    "Launch pricing for the pilot",
  );
  await act(async () =>
    host.querySelector<HTMLButtonElement>('[data-testid="pricing-save-wholesaler"]')!.click(),
  );
  expect(text("pricing-error-wholesaler")).toContain("between 0 and 100");
  expect(
    rpc.mock.calls.filter((c) => /publish|create|availability/.test(String(c[0]))),
  ).toHaveLength(0);
});

it("offers nothing to save when the figures are unchanged", async () => {
  world();
  await open();
  await act(async () => byId("stage-tile-configure")!.click());
  expect(
    host.querySelector<HTMLButtonElement>('[data-testid="pricing-save-wholesaler"]')!.disabled,
  ).toBe(true);
  expect(text("pricing-preview-wholesaler")).toContain("Nothing has changed");
});

// ---------- the switch, on its own ----------

it("the activation switch refuses to be used while the setup says something is missing, even with the phrase and a reason", async () => {
  world();
  const done = vi.fn();
  const readiness = (await rpc("admin_billing_readiness")).data;
  await render(
    <ActivationCard
      readiness={readiness}
      onDone={done}
      extraBlockers={["The test has run for 14 days"]}
      lockHoldBack
      compact
    />,
  );
  await type(host.querySelector<HTMLInputElement>("#act-phrase")!, "ACTIVATE BILLING");
  await type(host.querySelector<HTMLTextAreaElement>("#act-why")!, "Trying to switch it on early");
  const go = host.querySelector<HTMLButtonElement>('[data-testid="activate-billing"]')!;
  expect(go.disabled).toBe(true);
  expect(text("activation-blockers")).toContain("The test has run for 14 days");
  await act(async () => go.click());
  expect(calls("admin_billing_activate_platform")).toHaveLength(0);
});
