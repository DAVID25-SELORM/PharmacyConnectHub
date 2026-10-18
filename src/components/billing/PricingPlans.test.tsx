// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
const data = vi.hoisted(() => ({
  plans: [] as unknown[],
  settings: { subscriptions_enabled: true, commissions_enabled: true } as Record<string, unknown>,
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock("@/hooks/use-session", () => ({ useSession: () => ({ user: { id: "owner-1" } }) }));
vi.mock("@/integrations/supabase/client", () => {
  const chain = (rows: unknown, one?: unknown) => {
    const q: Record<string, unknown> = {};
    for (const m of ["select", "eq", "order", "limit", "in", "is", "ilike", "not"]) q[m] = () => q;
    q.maybeSingle = () => Promise.resolve({ data: one ?? null, error: null });
    q.then = (resolve: (v: unknown) => unknown) => resolve({ data: rows, error: null });
    return q;
  };
  return {
    supabase: {
      from: (t: string) =>
        t === "billing_settings" ? chain([], data.settings) : chain(data.plans),
      rpc,
    },
  };
});

import { PricingPlans } from "./PricingPlans";
import { tomorrow, startOfDayUtc } from "@/lib/billing-pricing";

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
  data.plans = [wholesalePlan()];
  data.settings = { subscriptions_enabled: true, commissions_enabled: true };
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  document.body.innerHTML = "";
});
const flush = () => act(async () => void (await new Promise((r) => setTimeout(r, 0))));
const byId = (id: string, scope: ParentNode = document.body) =>
  scope.querySelector<HTMLElement>(`[data-testid="${id}"]`);
const text = (id: string) => byId(id)?.textContent ?? "";
const click = (el: Element | null) => act(async () => (el as HTMLElement).click());
const type = async (el: HTMLInputElement | HTMLTextAreaElement, value: string) => {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement : HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(proto.prototype, "value")!.set!;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
};
const dialog = () => document.body.querySelector('[role="dialog"]')!;
const button = (label: string, scope: ParentNode = dialog()) =>
  Array.from(scope.querySelectorAll("button")).find(
    (b) => b.textContent?.trim() === label,
  ) as HTMLButtonElement;
const alertText = () => document.body.querySelector('[role="alert"]')?.textContent ?? "";
const calls = (fn: string) => rpc.mock.calls.filter((c) => c[0] === fn);

const version = (over: Record<string, unknown> = {}) => ({
  version: 1,
  status: "published",
  subscription_amount: 50,
  free_trial_days: 30,
  onboarding_free_orders: 10,
  monthly_free_orders: 5,
  transaction_fee_percentage: 1,
  transaction_fee_min: null,
  transaction_fee_max: 50,
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
const pending = (over: Record<string, unknown> = {}) => ({
  id: "chg-1",
  plan_id: "plan-w",
  plan_code: "wholesale-standard",
  plan_name: "Wholesale Standard",
  version: 2,
  effective_from: "2026-12-01T00:00:00Z",
  status: "pending",
  audience: "new_and_existing",
  keep_overrides: true,
  reason: "Price review",
  created_at: "2026-10-18T08:00:00Z",
  created_by: "owner@drugxone.com",
  applied_at: null,
  applied_result: null,
  cancelled_at: null,
  cancelled_by: null,
  cancel_reason: null,
  expected_affected: 3,
  subscription_amount: 70,
  free_trial_days: 30,
  onboarding_free_orders: 10,
  monthly_free_orders: 5,
  transaction_fee_percentage: 1,
  transaction_fee_min: null,
  transaction_fee_max: 50,
  transaction_fee_cycle_cap: null,
  ...over,
});
const previewOf = (over: Record<string, unknown> = {}) => ({
  plan: {
    id: "plan-w",
    code: "wholesale-standard",
    name: "Wholesale Standard",
    business_type: "wholesaler",
  },
  current_version: 1,
  current_terms: {},
  proposed_terms: {
    subscription_amount: 70,
    billing_interval_months: 1,
    currency: "GHS",
    entitlements: { advanced_analytics: true },
  },
  effective_from: null,
  audience: "new_only",
  keep_overrides: true,
  changes: [{ field: "subscription_amount", label: "Subscription", from: 50, to: 70 }],
  warnings: ["2 existing business(es) stay on their current terms until you move them."],
  existing: {
    total: 2,
    affected: 2,
    skipped: 0,
    businesses: [
      {
        business_id: "b1",
        business_name: "Alpha Wholesale",
        current_version: 1,
        current_amount: 50,
        current_fee_pct: 1,
        has_overrides: true,
        in_trial: false,
        change_from: "2026-11-08T00:00:00Z",
        skip_reason: null,
      },
      {
        business_id: "b2",
        business_name: "Beta Wholesale",
        current_version: 1,
        current_amount: 50,
        current_fee_pct: 1,
        has_overrides: false,
        in_trial: false,
        change_from: "2026-11-18T00:00:00Z",
        skip_reason: "It already has later terms",
      },
    ],
    truncated: false,
  },
  ...over,
});
function world(
  opts: { owner?: boolean; changes?: unknown[]; history?: unknown[]; preview?: unknown } = {},
) {
  rpc.mockImplementation(async (fn: string) => {
    switch (fn) {
      case "is_platform_owner":
        return { data: opts.owner ?? true, error: null };
      case "admin_billing_scheduled_changes":
        return { data: opts.changes ?? [], error: null };
      case "admin_billing_plan_history":
        return { data: opts.history ?? [], error: null };
      case "admin_billing_preview_price_change":
        return { data: opts.preview ?? previewOf(), error: null };
      default:
        return { data: null, error: null };
    }
  });
}
const open = async () => {
  await act(async () => root.render(<PricingPlans onOpenTab={() => {}} />));
  await flush();
  await flush();
};

// ---------- what is active, what is scheduled ----------

it("shows what is in force, and what is scheduled for each plan", async () => {
  world({ changes: [pending()] });
  await open();
  const row = byId("plan-row")!;
  expect(row.textContent).toContain("Wholesale Standard");
  expect(row.textContent).toContain(
    "GH₵ 50.00 per month · 30-day trial · 10 launch + 5 monthly free orders · 1% commission (at most GH₵ 50.00 an order)",
  );
  expect(byId("plan-scheduled", row)!.textContent).toContain("From 1 Dec 2026");
  expect(byId("plan-scheduled", row)!.textContent).toContain("GH₵ 70.00 per month");
  expect(byId("plan-scheduled", row)!.textContent).toContain("new and existing subscribers");
  expect(text("section-scheduled")).toContain("Pending");
  expect(text("section-scheduled")).toContain("owner@drugxone.com: Price review");
});

it("says so plainly when nothing is scheduled", async () => {
  world();
  await open();
  expect(text("plan-scheduled")).toContain("Nothing scheduled");
  expect(text("no-scheduled")).toContain("No price change has been scheduled");
});

it("shows the two charging switches", async () => {
  world();
  data.settings = { subscriptions_enabled: true, commissions_enabled: false };
  await open();
  expect(text("switch-subscriptions")).toBe("Charged");
  expect(text("switch-commissions")).toBe("Not charged");
});

// ---------- only the owner can change anything ----------

it("lets the platform owner change things", async () => {
  world({ owner: true, changes: [pending()] });
  await open();
  for (const id of [
    "new-plan",
    "change-pricing",
    "plan-availability",
    "cancel-change",
    "change-switches",
  ])
    expect(byId(id), id).not.toBeNull();
  expect(byId("owner-only-notice")).toBeNull();
});

it("shows every other administrator the same screen read-only, with no way to change anything", async () => {
  world({ owner: false, changes: [pending()] });
  await open();
  expect(text("owner-only-notice")).toContain(
    "Only the platform owner (Super Admin) can change pricing",
  );
  for (const id of [
    "new-plan",
    "change-pricing",
    "plan-availability",
    "cancel-change",
    "change-switches",
  ])
    expect(byId(id), id).toBeNull();
  // everything is still visible
  expect(text("plan-row")).toContain("Wholesale Standard");
  expect(text("section-scheduled")).toContain("Pending");
  expect(byId("plan-history")).not.toBeNull();
});

// ---------- changing pricing: preview, then confirm ----------

const openChange = async () => {
  await click(byId("change-pricing"));
  expect(byId("pricing-dialog")).not.toBeNull();
};
const fill = async (id: string, v: string) =>
  type(document.getElementById(id) as HTMLInputElement, v);

it("a price change made now reaches new subscribers only, and is previewed before it is saved", async () => {
  world();
  await open();
  await openChange();
  await fill("pc-subscription_amount", "70");
  expect(text("pricing-edit-changes")).toContain("Subscription per billing period (GHS): 50 → 70");
  await click(byId("when-now"));
  await click(byId("pricing-review-btn"));
  expect(calls("admin_billing_preview_price_change")).toEqual([
    [
      "admin_billing_preview_price_change",
      {
        p_plan_id: "plan-w",
        p_params: expect.objectContaining({
          subscription_amount: 70,
          transaction_fee_percentage: 1,
          currency: "GHS",
          entitlements: { advanced_analytics: true },
        }),
        p_effective_from: null,
        p_audience: "new_only",
        p_keep_overrides: true,
      },
    ],
  ]);
  expect(calls("admin_billing_publish_plan_version")).toHaveLength(0);
  const review = text("pricing-review");
  expect(review).toContain("Subscription: 50 → 70");
  expect(review).toContain(
    "It takes effect at once for every business that subscribes from now on.",
  );
  expect(review).toContain("Alpha Wholesale");
  expect(review).toContain("custom pricing");
  expect(review).toContain("Stays on its current terms");
  expect(review).toContain(
    "Invoices already issued, orders already assessed and the money ledger are never changed by a price change.",
  );
});

it("will not save without a reason and without the money confirmation", async () => {
  world();
  await open();
  await openChange();
  await fill("pc-subscription_amount", "70");
  await click(byId("when-now"));
  await click(byId("pricing-review-btn"));
  await click(byId("pricing-confirm"));
  expect(text("pricing-error")).toContain("reason");
  await type(document.getElementById("pc-reason") as HTMLTextAreaElement, "Annual price review");
  await click(byId("pricing-confirm"));
  expect(text("pricing-error")).toContain(
    "confirm you understand this changes what businesses are charged",
  );
  expect(calls("admin_billing_publish_plan_version")).toHaveLength(0);
  await click(byId("understood"));
  await click(byId("pricing-confirm"));
  expect(calls("admin_billing_publish_plan_version")).toHaveLength(1);
  expect(calls("admin_billing_publish_plan_version")[0][1]).toMatchObject({
    p_plan_id: "plan-w",
    p_reason: "Annual price review",
  });
});

it("schedules a future change for new subscribers only, and says existing businesses stay put", async () => {
  world({
    preview: previewOf({ effective_from: startOfDayUtc(tomorrow()), audience: "new_only" }),
  });
  await open();
  await openChange();
  await fill("pc-subscription_amount", "70");
  await click(byId("audience-new_only"));
  await click(byId("pricing-review-btn"));
  expect(calls("admin_billing_preview_price_change")[0][1]).toMatchObject({
    p_effective_from: startOfDayUtc(tomorrow()),
    p_audience: "new_only",
  });
  expect(text("pricing-review")).toContain(
    "Existing businesses stay on their current terms until you move them.",
  );
  await type(document.getElementById("pc-reason") as HTMLTextAreaElement, "Price rise next month");
  await click(byId("understood"));
  await click(byId("pricing-confirm"));
  const [, args] = calls("admin_billing_schedule_price_change")[0];
  expect(args).toMatchObject({
    p_plan_id: "plan-w",
    p_effective_from: startOfDayUtc(tomorrow()),
    p_audience: "new_only",
    p_keep_overrides: true,
    p_expected_affected: null,
    p_reason: "Price rise next month",
  });
  expect(calls("admin_billing_publish_plan_version")).toHaveLength(0);
});

it("for new AND existing subscribers it shows who moves and when, and sends back the count it showed", async () => {
  world({
    preview: previewOf({
      effective_from: startOfDayUtc(tomorrow()),
      audience: "new_and_existing",
      warnings: [
        "1 existing business(es) move to the new terms at the start of their next billing cycle, never earlier.",
      ],
      existing: { ...previewOf().existing, affected: 1, skipped: 1 },
    }),
  });
  await open();
  await openChange();
  await fill("pc-subscription_amount", "70");
  await click(byId("audience-new_and_existing"));
  expect(byId("keep-custom")).not.toBeNull();
  await click(byId("keep-custom")); // replace custom pricing instead
  await click(byId("pricing-review-btn"));
  expect(calls("admin_billing_preview_price_change")[0][1]).toMatchObject({
    p_audience: "new_and_existing",
    p_keep_overrides: false,
  });
  const review = text("pricing-review");
  expect(review).toContain(
    "1 existing business(es) move to it at the start of their own next billing cycle",
  );
  expect(review).toContain("Not moved: it already has later terms");
  expect(text("pricing-warnings")).toContain("never earlier");
  await type(
    document.getElementById("pc-reason") as HTMLTextAreaElement,
    "Move everyone to the new price",
  );
  await click(byId("understood"));
  await click(byId("pricing-confirm"));
  expect(calls("admin_billing_schedule_price_change")[0][1]).toMatchObject({
    p_audience: "new_and_existing",
    p_keep_overrides: false,
    p_expected_affected: 1,
  });
});

it("refuses a start date that is not in the future before asking the database", async () => {
  world();
  await open();
  await openChange();
  await fill("pc-subscription_amount", "70");
  await fill("pc-date", "2020-01-01");
  await click(byId("pricing-review-btn"));
  expect(text("pricing-error")).toContain("never start in the past");
  expect(calls("admin_billing_preview_price_change")).toHaveLength(0);
});

it("refuses a review when nothing has changed, and an impossible figure", async () => {
  world();
  await open();
  await openChange();
  await click(byId("pricing-review-btn"));
  expect(text("pricing-error")).toContain("Nothing has changed");
  await fill("pc-transaction_fee_percentage", "150");
  await click(byId("pricing-review-btn"));
  expect(text("pricing-error")).toContain("between 0 and 100");
  expect(calls("admin_billing_preview_price_change")).toHaveLength(0);
});

it("the recommended starting terms only fill the form: nothing is saved", async () => {
  data.plans = [
    wholesalePlan({
      billing_plan_versions: [
        version({
          subscription_amount: 99,
          free_trial_days: 0,
          onboarding_free_orders: 0,
          monthly_free_orders: 0,
          transaction_fee_percentage: 2,
          transaction_fee_max: null,
        }),
      ],
    }),
  ];
  world();
  await open();
  await openChange();
  await click(byId("use-recommended"));
  expect((document.getElementById("pc-subscription_amount") as HTMLInputElement).value).toBe("50");
  expect((document.getElementById("pc-free_trial_days") as HTMLInputElement).value).toBe("30");
  expect((document.getElementById("pc-onboarding_free_orders") as HTMLInputElement).value).toBe(
    "10",
  );
  expect((document.getElementById("pc-monthly_free_orders") as HTMLInputElement).value).toBe("5");
  expect((document.getElementById("pc-transaction_fee_percentage") as HTMLInputElement).value).toBe(
    "1",
  );
  expect((document.getElementById("pc-transaction_fee_max") as HTMLInputElement).value).toBe("50");
  expect(
    rpc.mock.calls.filter((c) =>
      /publish|schedule_price|cancel|create|availability|set_charging/.test(String(c[0])),
    ),
  ).toHaveLength(0);
});

it("a pharmacy plan is not offered a per-order commission", async () => {
  data.plans = [
    wholesalePlan({
      id: "plan-p",
      code: "pharmacy-standard",
      name: "Pharmacy Standard",
      business_type: "pharmacy",
      billing_plan_versions: [version({ subscription_amount: 0 })],
    }),
  ];
  world();
  await open();
  await openChange();
  expect(document.getElementById("pc-subscription_amount")).not.toBeNull();
  expect(document.getElementById("pc-transaction_fee_percentage")).toBeNull();
});

it("shows the database's refusal and keeps the dialog open", async () => {
  world();
  rpc.mockImplementation(async (fn: string) => {
    if (fn === "is_platform_owner") return { data: true, error: null };
    if (fn === "admin_billing_scheduled_changes") return { data: [], error: null };
    if (fn === "admin_billing_preview_price_change") return { data: previewOf(), error: null };
    if (fn === "admin_billing_publish_plan_version")
      return {
        data: null,
        error: {
          message:
            "Only the platform owner (Super Admin) can change billing. Other administrators can view it.",
        },
      };
    return { data: null, error: null };
  });
  await open();
  await openChange();
  await fill("pc-subscription_amount", "70");
  await click(byId("when-now"));
  await click(byId("pricing-review-btn"));
  await type(document.getElementById("pc-reason") as HTMLTextAreaElement, "Annual price review");
  await click(byId("understood"));
  await click(byId("pricing-confirm"));
  expect(text("pricing-error")).toContain(
    "Only the platform owner (Super Admin) can change billing.",
  );
  expect(byId("pricing-dialog")).not.toBeNull();
});

// ---------- cancel, switches, history ----------

it("cancels a pending change with a reason", async () => {
  world({ changes: [pending()] });
  await open();
  await click(byId("cancel-change"));
  await click(button("Cancel the change"));
  expect(alertText()).toContain("reason");
  expect(calls("admin_billing_cancel_scheduled_change")).toHaveLength(0);
  await type(dialog().querySelector("textarea")!, "The price rise is postponed");
  await click(button("Cancel the change"));
  expect(calls("admin_billing_cancel_scheduled_change")).toEqual([
    [
      "admin_billing_cancel_scheduled_change",
      { p_change_id: "chg-1", p_reason: "The price rise is postponed" },
    ],
  ]);
});

it("switches commissions off for everyone, with a reason", async () => {
  world();
  await open();
  await click(byId("change-switches"));
  await type(dialog().querySelector("textarea")!, "Waiving commissions this quarter");
  await click(button("Save")); // nothing changed yet
  expect(alertText()).toContain("Nothing has changed");
  const boxes = Array.from(dialog().querySelectorAll<HTMLInputElement>('input[type="checkbox"]'));
  await click(boxes[1]);
  await click(button("Save"));
  expect(calls("admin_billing_set_charging")).toEqual([
    [
      "admin_billing_set_charging",
      { p_subscriptions: true, p_commissions: false, p_reason: "Waiving commissions this quarter" },
    ],
  ]);
});

it("shows every version of a plan: who set it, why, and how many businesses are on it", async () => {
  world({
    history: [
      {
        id: "v2",
        version: 2,
        status: "scheduled",
        effective_from: "2026-12-01T00:00:00Z",
        created_at: "2026-10-18T08:00:00Z",
        created_by: "owner@drugxone.com",
        reason: "Price review",
        retired_at: null,
        cancelled_at: null,
        subscription_amount: 70,
        billing_interval_months: 1,
        free_trial_days: 30,
        onboarding_free_orders: 10,
        monthly_free_orders: 5,
        transaction_fee_percentage: 1,
        transaction_fee_min: null,
        transaction_fee_max: 50,
        transaction_fee_cycle_cap: null,
        min_billable_order_amount: null,
        businesses_on_it: 0,
        audience: "new_only",
        change_status: "pending",
        keep_overrides: true,
      },
      {
        id: "v1",
        version: 1,
        status: "published",
        effective_from: "2026-10-01T00:00:00Z",
        created_at: "2026-10-01T08:00:00Z",
        created_by: "owner@drugxone.com",
        reason: "Launch pricing",
        retired_at: null,
        cancelled_at: null,
        subscription_amount: 50,
        billing_interval_months: 1,
        free_trial_days: 30,
        onboarding_free_orders: 10,
        monthly_free_orders: 5,
        transaction_fee_percentage: 1,
        transaction_fee_min: null,
        transaction_fee_max: 50,
        transaction_fee_cycle_cap: null,
        min_billable_order_amount: null,
        businesses_on_it: 4,
        audience: null,
        change_status: null,
        keep_overrides: null,
      },
    ],
  });
  await open();
  await click(byId("plan-history"));
  await flush();
  expect(calls("admin_billing_plan_history")).toEqual([
    ["admin_billing_plan_history", { p_plan_id: "plan-w" }],
  ]);
  const table = text("history-table");
  expect(table).toContain("v2");
  expect(table).toContain("Scheduled");
  expect(table).toContain("In force");
  expect(table).toContain("Launch pricing");
  expect(table).toContain("GH₵ 70.00 per month");
  expect(table).toContain("4");
});

it("links to promotions and business-specific pricing, which already exist", async () => {
  world();
  const opened: string[] = [];
  await act(async () => root.render(<PricingPlans onOpenTab={(t) => opened.push(t)} />));
  await flush();
  await flush();
  await click(button("Promotions", byId("section-other-pricing")!));
  await click(
    button("A business's custom pricing (Organizations)", byId("section-other-pricing")!),
  );
  expect(opened).toEqual(["promotions", "organizations"]);
});
