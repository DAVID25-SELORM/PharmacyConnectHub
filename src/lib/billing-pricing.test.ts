import { beforeEach, describe, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
const settings = vi.hoisted(() => ({
  row: null as Record<string, unknown> | null,
  error: null as { message: string } | null,
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc,
    from: () => {
      const q: Record<string, unknown> = {};
      for (const m of ["select", "eq"]) q[m] = () => q;
      q.maybeSingle = () => Promise.resolve({ data: settings.row, error: settings.error });
      return q;
    },
  },
}));

import {
  RECOMMENDED_TERMS,
  cancelScheduledChange,
  confirmationLines,
  fetchChargingSwitches,
  fetchIsPlatformOwner,
  previewPriceChange,
  schedulePriceChange,
  scheduleDateError,
  setCharging,
  startOfDayUtc,
  summariseTerms,
  tomorrow,
  type PricePreview,
} from "./billing-pricing";
import { paramsFromTermsForm } from "./billing-plans";

beforeEach(() => {
  rpc.mockReset();
  settings.row = null;
  settings.error = null;
});

describe("the recommended starting terms", () => {
  it("are the approved wholesaler figures and turn into valid plan terms", () => {
    const { params, error } = paramsFromTermsForm(RECOMMENDED_TERMS.wholesaler, "wholesaler");
    expect(error).toBeNull();
    expect(params).toMatchObject({
      subscription_amount: 50,
      billing_interval_months: 1,
      free_trial_days: 30,
      onboarding_free_orders: 10,
      monthly_free_orders: 5,
      transaction_fee_percentage: 1,
      transaction_fee_max: 50,
    });
    // no minimum, no monthly cap, no limits unless the owner adds them
    for (const k of [
      "transaction_fee_min",
      "transaction_fee_cycle_cap",
      "min_billable_order_amount",
      "max_users",
      "max_branches",
    ])
      expect(params).not.toHaveProperty(k);
  });

  it("make a pharmacy plan free initially", () => {
    const { params, error } = paramsFromTermsForm(RECOMMENDED_TERMS.pharmacy, "pharmacy");
    expect(error).toBeNull();
    expect(params).toMatchObject({
      subscription_amount: 0,
      free_trial_days: 0,
      transaction_fee_percentage: 0,
    });
  });
});

describe("start dates", () => {
  const now = new Date("2026-10-18T15:30:00Z");
  it("must be tomorrow or later: a price never starts in the past", () => {
    expect(scheduleDateError("2026-10-17", now)).toContain("never start in the past");
    expect(scheduleDateError("2026-10-18", now)).toContain("never start in the past");
    expect(scheduleDateError("2026-10-19", now)).toBeNull();
  });
  it("must be a real date within a year", () => {
    expect(scheduleDateError("", now)).toContain("Choose the date");
    expect(scheduleDateError("18/10/2026", now)).toContain("Choose the date");
    expect(scheduleDateError("2026-13-40", now)).toContain("real date");
    expect(scheduleDateError("2027-10-17", now)).toBeNull();
    expect(scheduleDateError("2027-10-20", now)).toContain("at most a year");
  });
  it("mean the start of that day in UTC", () => {
    expect(startOfDayUtc("2026-11-08")).toBe("2026-11-08T00:00:00.000Z");
    expect(tomorrow(now)).toBe("2026-10-19");
  });
});

describe("one-line terms", () => {
  it("describes the approved plan", () => {
    expect(
      summariseTerms({
        subscription_amount: 50,
        free_trial_days: 30,
        onboarding_free_orders: 10,
        monthly_free_orders: 5,
        transaction_fee_percentage: 1,
        transaction_fee_max: 50,
        billing_interval_months: 1,
      }),
    ).toBe(
      "GH₵ 50.00 per month · 30-day trial · 10 launch + 5 monthly free orders · 1% commission (at most GH₵ 50.00 an order)",
    );
  });
  it("says plainly when there is no trial, no free orders or no commission", () => {
    expect(
      summariseTerms({
        subscription_amount: 0,
        free_trial_days: 0,
        onboarding_free_orders: 0,
        monthly_free_orders: 0,
        transaction_fee_percentage: 0,
        transaction_fee_max: null,
      }),
    ).toBe("GH₵ 0.00 per month · no trial · no commission");
    expect(
      summariseTerms({
        subscription_amount: 99,
        free_trial_days: 0,
        onboarding_free_orders: 0,
        monthly_free_orders: 0,
        transaction_fee_percentage: 2.5,
        transaction_fee_max: null,
        billing_interval_months: 3,
      }),
    ).toContain("per 3 months");
  });
});

const preview = (over: Partial<PricePreview> = {}): PricePreview => ({
  plan: {
    id: "p",
    code: "wholesale-standard",
    name: "Wholesale Standard",
    business_type: "wholesaler",
  },
  current_version: 1,
  current_terms: {},
  proposed_terms: {},
  effective_from: "2026-11-08T00:00:00Z",
  audience: "new_and_existing",
  keep_overrides: true,
  changes: [{ field: "subscription_amount", label: "Subscription", from: 50, to: 70 }],
  warnings: [],
  existing: { total: 4, affected: 3, skipped: 1, businesses: [], truncated: false },
  ...over,
});

describe("the confirmation", () => {
  it("states each change, the start date and exactly who is moved", () => {
    const lines = confirmationLines({
      preview: preview(),
      scheduled: true,
      startsOn: "8 Nov 2026",
    });
    expect(lines).toContain("Subscription: 50 → 70");
    expect(lines).toContain(
      "It starts on 8 Nov 2026. Businesses that subscribe before then are not affected.",
    );
    expect(lines.join(" ")).toContain(
      "3 existing business(es) move to it at the start of their own next billing cycle",
    );
    expect(lines.join(" ")).toContain("1 business(es) are left out");
  });
  it("says existing businesses stay put when the change is for new subscribers only", () => {
    const lines = confirmationLines({
      preview: preview({ audience: "new_only" }),
      scheduled: true,
      startsOn: "8 Nov 2026",
    });
    expect(lines).toContain("Existing businesses stay on their current terms until you move them.");
  });
  it("says a change made now reaches new subscribers only", () => {
    const lines = confirmationLines({
      preview: preview({ audience: "new_only" }),
      scheduled: false,
      startsOn: null,
    });
    expect(lines).toContain(
      "It takes effect at once for every business that subscribes from now on.",
    );
    expect(lines.join(" ")).toContain(
      "4 existing business(es) on this plan keep their current terms until you move them.",
    );
    expect(
      confirmationLines({
        preview: preview({
          existing: { total: 0, affected: 0, skipped: 0, businesses: [], truncated: false },
        }),
        scheduled: false,
        startsOn: null,
      }),
    ).toContain("No existing business is on this plan.");
  });
  it("shows an empty value as none", () => {
    const lines = confirmationLines({
      preview: preview({
        changes: [
          {
            field: "transaction_fee_max",
            label: "Largest commission per order",
            from: null,
            to: 50,
          },
        ],
      }),
      scheduled: false,
      startsOn: null,
    });
    expect(lines).toContain("Largest commission per order: none → 50");
  });
});

describe("talking to the database", () => {
  it("asks whether the signed-in user is the platform owner, and treats any failure as no", async () => {
    rpc.mockResolvedValue({ data: true, error: null });
    expect(await fetchIsPlatformOwner("u1")).toBe(true);
    expect(rpc).toHaveBeenCalledWith("is_platform_owner", { _user_id: "u1" });
    rpc.mockResolvedValue({ data: null, error: { message: "boom" } });
    expect(await fetchIsPlatformOwner("u1")).toBe(false);
    rpc.mockResolvedValue({ data: false, error: null });
    expect(await fetchIsPlatformOwner("u1")).toBe(false);
  });

  it("sends a preview and a schedule exactly as the database expects them, including the count it was shown", async () => {
    rpc.mockResolvedValue({ data: preview(), error: null });
    await previewPriceChange({
      planId: "p",
      params: { subscription_amount: 70 },
      effectiveFrom: "2026-11-08T00:00:00Z",
      audience: "new_and_existing",
      keepOverrides: false,
    });
    expect(rpc).toHaveBeenLastCalledWith("admin_billing_preview_price_change", {
      p_plan_id: "p",
      p_params: { subscription_amount: 70 },
      p_effective_from: "2026-11-08T00:00:00Z",
      p_audience: "new_and_existing",
      p_keep_overrides: false,
    });
    rpc.mockResolvedValue({ data: "change-1", error: null });
    await schedulePriceChange({
      planId: "p",
      params: { subscription_amount: 70 },
      effectiveFrom: "2026-11-08T00:00:00Z",
      audience: "new_and_existing",
      keepOverrides: true,
      expectedAffected: 3,
      reason: "Price review",
    });
    expect(rpc).toHaveBeenLastCalledWith("admin_billing_schedule_price_change", {
      p_plan_id: "p",
      p_params: { subscription_amount: 70 },
      p_effective_from: "2026-11-08T00:00:00Z",
      p_audience: "new_and_existing",
      p_keep_overrides: true,
      p_expected_affected: 3,
      p_reason: "Price review",
    });
  });

  it("cancels with a reason and switches charging with a reason", async () => {
    rpc.mockResolvedValue({ data: null, error: null });
    await cancelScheduledChange("c1", "Changed our mind");
    expect(rpc).toHaveBeenLastCalledWith("admin_billing_cancel_scheduled_change", {
      p_change_id: "c1",
      p_reason: "Changed our mind",
    });
    await setCharging(true, false, "Commissions off for now");
    expect(rpc).toHaveBeenLastCalledWith("admin_billing_set_charging", {
      p_subscriptions: true,
      p_commissions: false,
      p_reason: "Commissions off for now",
    });
  });

  it("shows the database's refusal as it is", async () => {
    rpc.mockResolvedValue({
      data: null,
      error: {
        message:
          "Only the platform owner (Super Admin) can change billing. Other administrators can view it.",
      },
    });
    await expect(cancelScheduledChange("c1", "Not allowed")).rejects.toThrow(
      "Only the platform owner (Super Admin) can change billing.",
    );
  });

  it("reads the two switches, and treats missing columns as both on", async () => {
    settings.row = { subscriptions_enabled: true, commissions_enabled: false };
    expect(await fetchChargingSwitches()).toEqual({
      subscriptions_enabled: true,
      commissions_enabled: false,
    });
    settings.row = {};
    expect(await fetchChargingSwitches()).toEqual({
      subscriptions_enabled: true,
      commissions_enabled: true,
    });
    settings.row = null;
    expect(await fetchChargingSwitches()).toEqual({
      subscriptions_enabled: true,
      commissions_enabled: true,
    });
    settings.error = { message: "no" };
    await expect(fetchChargingSwitches()).rejects.toThrow("no");
  });
});
