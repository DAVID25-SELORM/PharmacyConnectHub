import { beforeEach, describe, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({}), rpc } }));

import type { PlanRow, ReconciliationReport } from "./billing";
import type { Readiness } from "./billing-rollout";
import {
  buildSetupStatus,
  checksHeadline,
  describePricingSave,
  fetchShadowReview,
  pricingSteps,
  pricingTarget,
  reconciliationProblems,
  savePricing,
  type ShadowReview,
  type ShadowReviewResult,
} from "./billing-setup";

beforeEach(() => rpc.mockReset());

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
const plan = (over: Partial<PlanRow> = {}): PlanRow =>
  ({
    id: "plan-1",
    code: "wholesale-standard",
    name: "Wholesale Standard",
    business_type: "wholesaler",
    kind: "standard",
    active: true,
    publicly_visible: false,
    billing_plan_versions: [version()],
    ...over,
  }) as PlanRow;

const ok = (key: string, label: string, over: Record<string, unknown> = {}) => ({
  key,
  label,
  blocking: true,
  ok: true,
  detail: "",
  ...over,
});
const readiness = (over: Partial<Readiness> = {}, failing: string[] = []): Readiness => {
  const checks = [
    ok("zero_commission", "Paystack platform commission is zero"),
    ok("subscriptions", "At least one business has a subscription", { detail: "1 subscriptions" }),
    ok("reconciliation", "The billing books agree"),
    ok("scheduler", "The scheduled billing run is running", { detail: "Last ran today" }),
    ok("issuer", "Invoices say who they are from and how to pay"),
    ok("plans", "There is a switched-on plan with a published version for wholesalers"),
    ok("shadow_history", "Shadow billing has run for at least 14 days", { blocking: false }),
    ok("terms", "Payment terms and grace period are what you intend", {
      blocking: false,
      detail: "14 days to pay, 7 days of grace, enforcement: none",
    }),
  ].map((c) => (failing.includes(c.key) ? { ...c, ok: false } : c));
  return {
    platform_mode: "shadow",
    ready: failing.length === 0,
    checks,
    shadow: {
      since: "2026-09-20T00:00:00Z",
      days: 20,
      businesses: 3,
      orders_assessed: 120,
      estimated_revenue: 840,
    },
    live: { live: 0, held_back: 3, disabled: 0, waiting: 0 },
    ...over,
  } as Readiness;
};
const reconciliation = (counts: Record<string, number> = {}): ReconciliationReport => ({
  checked_at: "2026-10-14T10:00:00Z",
  healthy: Object.values(counts).every((n) => n === 0),
  checks: [
    {
      check: "delivered_order_not_assessed",
      severity: "critical",
      count: counts.delivered_order_not_assessed ?? 0,
      details: [],
    },
    {
      check: "invoice_numbers_have_a_gap",
      severity: "warning",
      count: counts.invoice_numbers_have_a_gap ?? 0,
      details: [],
    },
    {
      check: "period_fees_exceed_the_cap",
      severity: "critical",
      count: counts.period_fees_exceed_the_cap ?? 0,
      details: [],
    },
  ],
});
const review = (
  counts: Record<string, number> = {},
  rows: ShadowReview["rows"] = [],
): ShadowReviewResult => ({
  available: true,
  review: {
    checked_at: "2026-10-14T10:00:00Z",
    assessments_total: 120,
    recomputed: 100,
    recorded_fee_total: 840,
    recalculated_fee_total: 840,
    checks: [
      {
        key: "fee_formula",
        label: "Each fee matches",
        severity: "critical",
        count: counts.fee_formula ?? 0,
      },
      {
        key: "order_value",
        label: "No order changed unnoticed",
        severity: "warning",
        count: counts.order_value ?? 0,
      },
    ],
    rows,
  },
});
const unavailable: ShadowReviewResult = { available: false, reason: "not added yet" };

const status = (
  r: Readiness,
  plans: PlanRow[],
  recon: ReconciliationReport | null,
  rev: ShadowReviewResult | null,
) =>
  buildSetupStatus({
    readiness: r,
    plans,
    reconciliation: recon,
    review: rev,
  });
const stageOf = (s: ReturnType<typeof status>, key: string) => s.stages.find((x) => x.key === key)!;
const pharmacyPlan = plan({
  id: "p2",
  code: "pharmacy-standard",
  name: "Pharmacy Standard",
  business_type: "pharmacy",
});

describe("the four stages", () => {
  it("names them in order", () => {
    const s = status(readiness(), [plan()], reconciliation(), review());
    expect(s.stages.map((x) => x.title)).toEqual([
      "Configure Billing",
      "Set Up Invoices",
      "Run 14-Day Shadow Test",
      "Activate Pilot Businesses",
    ]);
    expect(s.stages.map((x) => x.number)).toEqual([1, 2, 3, 4]);
  });

  it("starts at Configure Billing when nothing has been done", () => {
    const r = readiness(
      {
        platform_mode: "disabled",
        shadow: { since: null, days: 0, businesses: 0, orders_assessed: 0, estimated_revenue: 0 },
      },
      ["zero_commission", "subscriptions", "scheduler", "issuer", "plans"],
    );
    const s = status(r, [], null, null);
    expect(s.current).toBe("configure");
    expect(s.canActivate).toBe(false);
    expect(stageOf(s, "configure").status).toBe("current");
    expect(stageOf(s, "invoices").status).toBe("upcoming");
    expect(s.blockers).toContain("Wholesaler pricing is set and switched on");
    expect(s.blockers).toContain("Invoices say who they are from and how to pay");
    expect(s.blockers).toContain("The shadow test has been started");
    expect(s.percent).toBeLessThan(30);
  });

  it("moves on to invoices once pricing is set", () => {
    const s = status(readiness({}, ["issuer"]), [plan()], reconciliation(), review());
    expect(stageOf(s, "configure").status).toBe("complete");
    expect(s.current).toBe("invoices");
    expect(stageOf(s, "invoices").status).toBe("current");
  });

  it("is in the shadow stage until 14 days have run", () => {
    const r = readiness({
      shadow: {
        since: "2026-10-10T00:00:00Z",
        days: 4,
        businesses: 2,
        orders_assessed: 30,
        estimated_revenue: 90,
      },
    });
    const s = status(r, [plan()], reconciliation(), review());
    expect(s.current).toBe("shadow");
    expect(s.canActivate).toBe(false);
    expect(s.blockers).toEqual(["The test has run for 14 days"]);
    expect(stageOf(s, "shadow").items.find((i) => i.key === "days")?.detail).toBe("Day 4 of 14.");
  });

  it("needs real orders: fourteen quiet days prove nothing", () => {
    const r = readiness({
      shadow: {
        since: "2026-09-20T00:00:00Z",
        days: 20,
        businesses: 1,
        orders_assessed: 0,
        estimated_revenue: 0,
      },
    });
    const s = status(r, [plan()], reconciliation(), review());
    expect(s.canActivate).toBe(false);
    expect(s.blockers).toEqual(["Real orders have been assessed"]);
  });

  it("offers activation only when every required item is done", () => {
    const s = status(readiness(), [plan()], reconciliation(), review());
    expect(s.blockers).toEqual([]);
    expect(s.canActivate).toBe(true);
    expect(s.current).toBe("activate");
    expect(s.percent).toBe(100);
    expect(stageOf(s, "activate").status).toBe("current");
    for (const k of ["configure", "invoices", "shadow"])
      expect(stageOf(s, k).status).toBe("complete");
  });

  it("does not block on pharmacy pricing unless the database says it is needed", () => {
    const s = status(readiness(), [plan()], reconciliation(), review());
    expect(s.canActivate).toBe(true);
    expect(stageOf(s, "configure").items.find((i) => i.key === "pharmacy_pricing")?.status).toBe(
      "advice",
    );
    // a pharmacy has subscribed, so the database requires a pharmacy plan too
    const needs = status(readiness({}, ["plans"]), [plan()], reconciliation(), review());
    expect(needs.canActivate).toBe(false);
    expect(needs.blockers).toEqual([
      "There is a switched-on plan with a published version for wholesalers",
    ]);
    const fixed = status(readiness(), [plan(), pharmacyPlan], reconciliation(), review());
    expect(
      stageOf(fixed, "configure").items.find((i) => i.key === "pharmacy_pricing")?.status,
    ).toBe("done");
  });

  it("is never offered when the Paystack commission is not zero", () => {
    const s = status(readiness({}, ["zero_commission"]), [plan()], reconciliation(), review());
    expect(s.canActivate).toBe(false);
    expect(s.blockers).toEqual(["Paystack platform commission is zero"]);
  });
});

describe("disagreements", () => {
  it("a reconciliation finding blocks activation and needs attention", () => {
    const s = status(
      readiness({}, ["reconciliation"]),
      [plan()],
      reconciliation({ delivered_order_not_assessed: 2 }),
      review(),
    );
    expect(s.canActivate).toBe(false);
    expect(stageOf(s, "shadow").status).toBe("attention");
    expect(s.blockers).toEqual(["The billing books agree (reconciliation)"]);
  });

  it("a warning alone does not block", () => {
    const s = status(
      readiness(),
      [plan()],
      reconciliation({ invoice_numbers_have_a_gap: 1 }),
      review(),
    );
    expect(s.canActivate).toBe(true);
  });

  it("a fee that differs from its recalculation blocks activation", () => {
    const s = status(readiness(), [plan()], reconciliation(), review({ fee_formula: 3 }));
    expect(s.canActivate).toBe(false);
    expect(stageOf(s, "shadow").status).toBe("attention");
    expect(s.blockers).toEqual(["Every shadow fee matches its recalculation"]);
  });

  it("an order value warning in the review does not block", () => {
    const s = status(readiness(), [plan()], reconciliation(), review({ order_value: 4 }));
    expect(s.canActivate).toBe(true);
  });

  it("a review that cannot run yet does not block, and says so", () => {
    const s = status(readiness(), [plan()], reconciliation(), unavailable);
    expect(s.canActivate).toBe(true);
    const item = stageOf(s, "shadow").items.find((i) => i.key === "recalculation")!;
    expect(item.status).toBe("advice");
    expect(item.detail).toContain("not available");
  });

  it("checks that have not run yet block nothing they did not find, but do not count as agreeing", () => {
    const s = status(readiness({}, []), [plan()], null, null);
    expect(s.canActivate).toBe(false);
    expect(s.blockers).toEqual(["The billing books agree (reconciliation)"]);
  });
});

describe("after real billing is on", () => {
  it("is not offered again, and stays current until a pilot is live", () => {
    const active = readiness({ platform_mode: "active" });
    const s = status(active, [plan()], reconciliation(), review());
    expect(s.canActivate).toBe(false);
    expect(s.current).toBe("activate");
    const live = status(
      readiness({
        platform_mode: "active",
        live: { live: 2, held_back: 1, disabled: 0, waiting: 0 },
      }),
      [plan()],
      reconciliation(),
      review(),
    );
    expect(stageOf(live, "activate").status).toBe("complete");
    expect(live.current).toBeNull();
  });
});

describe("what the automatic checks say", () => {
  it("lists reconciliation findings in words, worst first", () => {
    const list = reconciliationProblems(
      reconciliation({
        invoice_numbers_have_a_gap: 5,
        delivered_order_not_assessed: 2,
        period_fees_exceed_the_cap: 7,
      }),
    );
    expect(list.map((p) => [p.label, p.count, p.severity])).toEqual([
      ["Periods whose fees exceed the cap", 7, "critical"],
      ["Delivered orders that were not assessed", 2, "critical"],
      ["Invoice numbers with a gap", 5, "warning"],
    ]);
    expect(reconciliationProblems(null)).toEqual([]);
  });

  it("has a plain headline", () => {
    expect(checksHeadline(null, null).tone).toBe("unknown");
    const good = checksHeadline(reconciliation(), review());
    expect(good).toEqual({
      tone: "good",
      text: "Everything agrees: 3 consistency checks and 100 recalculated fees.",
    });
    expect(checksHeadline(reconciliation(), unavailable).text).toBe(
      "The 3 consistency checks agree.",
    );
    expect(
      checksHeadline(
        reconciliation({ delivered_order_not_assessed: 1 }),
        review({ fee_formula: 2 }),
      ).text,
    ).toBe("2 things need attention. Nothing was changed.");
    expect(checksHeadline(reconciliation({ delivered_order_not_assessed: 1 }), review()).text).toBe(
      "1 thing needs attention. Nothing was changed.",
    );
  });
});

describe("the shadow review function", () => {
  it("returns the review when the database has it", async () => {
    rpc.mockResolvedValue({
      data: review().available && (review() as { review: ShadowReview }).review,
      error: null,
    });
    const r = await fetchShadowReview(10);
    expect(rpc).toHaveBeenCalledWith("admin_billing_shadow_review", { p_limit: 10 });
    expect(r.available).toBe(true);
  });

  it.each([
    [
      {
        code: "PGRST202",
        message:
          "Could not find the function public.admin_billing_shadow_review(p_limit) in the schema cache",
      },
    ],
    [
      {
        code: "42883",
        message: "function public.admin_billing_shadow_review(integer) does not exist",
      },
    ],
  ])("reports it as not added yet when the function is missing: %j", async (error) => {
    rpc.mockResolvedValue({ data: null, error });
    const r = await fetchShadowReview();
    expect(r).toEqual({ available: false, reason: expect.stringContaining("not been added") });
  });

  it("still raises a real error", async () => {
    rpc.mockResolvedValue({
      data: null,
      error: { code: "42501", message: "Administrators only." },
    });
    await expect(fetchShadowReview()).rejects.toThrow("Administrators only.");
  });
});

describe("saving pricing", () => {
  const values = {
    subscription_amount: "199",
    billing_interval_months: "1",
    free_trial_days: "30",
    onboarding_free_orders: "20",
    monthly_free_orders: "5",
    transaction_fee_percentage: "1.5",
    transaction_fee_min: "2",
    transaction_fee_max: "250",
    transaction_fee_cycle_cap: "",
    min_billable_order_amount: "",
    max_users: "",
    max_branches: "",
  };

  it("chooses the switched-on standard plan, or failing that the first one", () => {
    const off = plan({ id: "a", active: false });
    const on = plan({ id: "b", active: true });
    const custom = plan({ id: "c", kind: "custom" });
    expect(pricingTarget([off, on, custom], "wholesaler")?.id).toBe("b");
    expect(pricingTarget([off, custom], "wholesaler")?.id).toBe("a");
    expect(pricingTarget([off], "pharmacy")).toBeUndefined();
  });

  it("plans every step for a business kind with no plan", () => {
    expect(pricingSteps(undefined, "wholesaler", values)).toEqual([
      "create",
      "publish",
      "activate",
    ]);
  });

  it("publishes only when the terms changed, and switches on only when it is off", () => {
    expect(pricingSteps(plan(), "wholesaler", values)).toEqual([]);
    expect(pricingSteps(plan(), "wholesaler", { ...values, subscription_amount: "249" })).toEqual([
      "publish",
    ]);
    expect(pricingSteps(plan({ active: false }), "wholesaler", values)).toEqual(["activate"]);
    expect(
      pricingSteps(plan({ active: false }), "wholesaler", { ...values, free_trial_days: "0" }),
    ).toEqual(["publish", "activate"]);
    // a plan that was created but never given terms
    expect(
      pricingSteps(plan({ active: false, billing_plan_versions: [] }), "wholesaler", values),
    ).toEqual(["publish", "activate"]);
  });

  it("describes what was done", () => {
    expect(describePricingSave([], "x")).toBe("Nothing changed.");
    expect(describePricingSave(["create", "publish", "activate"], "Wholesale Standard")).toBe(
      "Wholesale Standard: The plan was created, the new terms were published, the plan was switched on.",
    );
  });

  it("creates, publishes and switches on a new plan, in that order, with the reason each time", async () => {
    rpc.mockImplementation(async (fn: string) => ({
      data: fn === "admin_billing_create_plan" ? "new-id" : null,
      error: null,
    }));
    const r = await savePricing({
      plan: undefined,
      type: "wholesaler",
      values,
      reason: "Launch pricing",
    });
    expect(r).toEqual({ steps: ["create", "publish", "activate"], planId: "new-id" });
    expect(rpc.mock.calls.map((c) => c[0])).toEqual([
      "admin_billing_create_plan",
      "admin_billing_publish_plan_version",
      "admin_billing_set_plan_availability",
    ]);
    expect(rpc.mock.calls[0][1]).toMatchObject({
      p_code: "wholesale-standard",
      p_business_type: "wholesaler",
      p_kind: "standard",
      p_reason: "Launch pricing",
    });
    expect(rpc.mock.calls[1][1]).toMatchObject({ p_plan_id: "new-id", p_reason: "Launch pricing" });
    expect(rpc.mock.calls[1][1].p_params).toMatchObject({
      subscription_amount: 199,
      transaction_fee_percentage: 1.5,
    });
    expect(rpc.mock.calls[2][1]).toEqual({
      p_plan_id: "new-id",
      p_active: true,
      p_publicly_visible: false,
      p_reason: "Launch pricing",
    });
  });

  it("keeps the plan's entitlements when it publishes a new version", async () => {
    rpc.mockResolvedValue({ data: "v", error: null });
    await savePricing({
      plan: plan(),
      type: "wholesaler",
      values: { ...values, subscription_amount: "249" },
      reason: "Price review",
    });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc.mock.calls[0][1].p_params).toMatchObject({
      subscription_amount: 249,
      currency: "GHS",
      entitlements: { advanced_analytics: true },
    });
  });

  it("does nothing, and calls nothing, when nothing changed", async () => {
    const r = await savePricing({ plan: plan(), type: "wholesaler", values, reason: "No change" });
    expect(r.steps).toEqual([]);
    expect(rpc).not.toHaveBeenCalled();
  });

  it("refuses an impossible figure before sending anything", async () => {
    await expect(
      savePricing({
        plan: plan(),
        type: "wholesaler",
        values: { ...values, transaction_fee_percentage: "150" },
        reason: "x reason",
      }),
    ).rejects.toThrow("between 0 and 100");
    expect(rpc).not.toHaveBeenCalled();
  });

  it("says which step failed and what was already done, and carries on when saved again", async () => {
    rpc.mockImplementation(async (fn: string) => {
      if (fn === "admin_billing_create_plan") return { data: "new-id", error: null };
      if (fn === "admin_billing_publish_plan_version")
        return { data: null, error: { message: 'Unknown plan feature "x".' } };
      return { data: null, error: null };
    });
    await expect(
      savePricing({ plan: undefined, type: "wholesaler", values, reason: "Launch pricing" }),
    ).rejects.toThrow(
      /Stopped while publishing the terms: Unknown plan feature "x"\. Already done: the plan was created\. Save again to carry on\./,
    );
    // the plan now exists (created, not yet switched on, no version): saving again publishes and switches on, and does not create a second plan
    rpc.mockReset();
    rpc.mockResolvedValue({ data: "v", error: null });
    const retry = await savePricing({
      plan: plan({ active: false, billing_plan_versions: [] }),
      type: "wholesaler",
      values,
      reason: "Launch pricing",
    });
    expect(retry.steps).toEqual(["publish", "activate"]);
    expect(rpc.mock.calls.map((c) => c[0])).toEqual([
      "admin_billing_publish_plan_version",
      "admin_billing_set_plan_availability",
    ]);
  });
});
