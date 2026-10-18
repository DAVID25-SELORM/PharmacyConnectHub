// Pricing & Plans, from the screens' side. The database decides who may change pricing (only the platform owner), when a scheduled price takes effect, and who it reaches; this file sends plain requests,
// shows the preview the database returns, and words the confirmation. Nothing here works out a price, a fee or a date of effect.
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

async function call<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

// ---------- who may change pricing ----------

/** The platform owner (Super Admin) may change billing; every other administrator may only look. The database enforces this too. */
export async function fetchIsPlatformOwner(userId: string): Promise<boolean> {
  const { data, error } = await db.rpc("is_platform_owner", { _user_id: userId });
  if (error) return false;
  return data === true;
}

export const OWNER_ONLY_NOTICE =
  "Only the platform owner (Super Admin) can change pricing. You can see everything here, and nothing you do on this page changes it.";

// ---------- the recommended starting terms ----------

/** Offered as a starting point only. Choosing it fills the form; nothing is saved until the owner reviews it, gives a reason and confirms. */
export const RECOMMENDED_TERMS: Record<"wholesaler" | "pharmacy", Record<string, string>> = {
  wholesaler: {
    subscription_amount: "50",
    billing_interval_months: "1",
    free_trial_days: "30",
    onboarding_free_orders: "10",
    monthly_free_orders: "5",
    transaction_fee_percentage: "1",
    transaction_fee_min: "",
    transaction_fee_max: "50",
    transaction_fee_cycle_cap: "",
    min_billable_order_amount: "",
    max_users: "",
    max_branches: "",
  },
  pharmacy: {
    subscription_amount: "0",
    billing_interval_months: "1",
    free_trial_days: "0",
    onboarding_free_orders: "0",
    monthly_free_orders: "0",
    transaction_fee_percentage: "0",
    transaction_fee_min: "",
    transaction_fee_max: "",
    transaction_fee_cycle_cap: "",
    min_billable_order_amount: "",
    max_users: "",
    max_branches: "",
  },
};

// ---------- the calls ----------

export type PriceAudience = "new_only" | "new_and_existing";

export type PreviewBusiness = {
  business_id: string;
  business_name: string;
  current_version: number;
  current_amount: number;
  current_fee_pct: number;
  has_overrides: boolean;
  in_trial: boolean;
  change_from: string;
  skip_reason: string | null;
};

export type PricePreview = {
  plan: { id: string; code: string; name: string; business_type: "pharmacy" | "wholesaler" };
  current_version: number | null;
  current_terms: Record<string, unknown> | null;
  proposed_terms: Record<string, unknown>;
  effective_from: string | null;
  audience: PriceAudience;
  keep_overrides: boolean;
  changes: { field: string; label: string; from: unknown; to: unknown }[];
  warnings: string[];
  existing: {
    total: number;
    affected: number;
    skipped: number;
    businesses: PreviewBusiness[];
    truncated: boolean;
  };
};

export const previewPriceChange = (input: {
  planId: string;
  params: Record<string, unknown>;
  effectiveFrom: string | null;
  audience: PriceAudience;
  keepOverrides: boolean;
}) =>
  call<PricePreview>("admin_billing_preview_price_change", {
    p_plan_id: input.planId,
    p_params: input.params,
    p_effective_from: input.effectiveFrom,
    p_audience: input.audience,
    p_keep_overrides: input.keepOverrides,
  });

export const schedulePriceChange = (input: {
  planId: string;
  params: Record<string, unknown>;
  effectiveFrom: string;
  audience: PriceAudience;
  keepOverrides: boolean;
  expectedAffected: number | null;
  reason: string;
}) =>
  call<string>("admin_billing_schedule_price_change", {
    p_plan_id: input.planId,
    p_params: input.params,
    p_effective_from: input.effectiveFrom,
    p_audience: input.audience,
    p_keep_overrides: input.keepOverrides,
    p_expected_affected: input.expectedAffected,
    p_reason: input.reason,
  });

export const cancelScheduledChange = (changeId: string, reason: string) =>
  call<null>("admin_billing_cancel_scheduled_change", { p_change_id: changeId, p_reason: reason });

export type ScheduledChange = {
  id: string;
  plan_id: string;
  plan_code: string;
  plan_name: string;
  version: number;
  effective_from: string;
  status: "pending" | "applied" | "cancelled";
  audience: PriceAudience;
  keep_overrides: boolean;
  reason: string;
  created_at: string;
  created_by: string | null;
  applied_at: string | null;
  applied_result: {
    moved?: number;
    skipped?: number;
    skipped_businesses?: { business: string; why: string }[];
  } | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancel_reason: string | null;
  expected_affected: number | null;
  subscription_amount: number;
  free_trial_days: number;
  onboarding_free_orders: number;
  monthly_free_orders: number;
  transaction_fee_percentage: number;
  transaction_fee_min: number | null;
  transaction_fee_max: number | null;
  transaction_fee_cycle_cap: number | null;
};

export const fetchScheduledChanges = (limit = 50) =>
  call<ScheduledChange[]>("admin_billing_scheduled_changes", { p_limit: limit });

export type PlanHistoryRow = {
  id: string;
  version: number;
  status: "published" | "scheduled" | "retired" | "cancelled";
  effective_from: string;
  created_at: string;
  created_by: string | null;
  reason: string;
  retired_at: string | null;
  cancelled_at: string | null;
  subscription_amount: number;
  billing_interval_months: number;
  free_trial_days: number;
  onboarding_free_orders: number;
  monthly_free_orders: number;
  transaction_fee_percentage: number;
  transaction_fee_min: number | null;
  transaction_fee_max: number | null;
  transaction_fee_cycle_cap: number | null;
  min_billable_order_amount: number | null;
  businesses_on_it: number;
  audience: PriceAudience | null;
  change_status: "pending" | "applied" | "cancelled" | null;
  keep_overrides: boolean | null;
};

export const fetchPlanHistory = (planId: string) =>
  call<PlanHistoryRow[]>("admin_billing_plan_history", { p_plan_id: planId });

export const setCharging = (subscriptions: boolean, commissions: boolean, reason: string) =>
  call<{ subscriptions: boolean; commissions: boolean }>("admin_billing_set_charging", {
    p_subscriptions: subscriptions,
    p_commissions: commissions,
    p_reason: reason,
  });

export type ChargingSwitches = { subscriptions_enabled: boolean; commissions_enabled: boolean };

/** The two switches, read straight from the settings row (administrators may read it). */
export async function fetchChargingSwitches(): Promise<ChargingSwitches> {
  const { data, error } = await db
    .from("billing_settings")
    .select("subscriptions_enabled, commissions_enabled")
    .eq("id", true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  // before the database update that adds the switches, both are simply on
  return {
    subscriptions_enabled: data?.subscriptions_enabled ?? true,
    commissions_enabled: data?.commissions_enabled ?? true,
  };
}

// ---------- wording and dates ----------

export const AUDIENCE_LABELS: Record<PriceAudience, string> = {
  new_only: "New subscribers only",
  new_and_existing: "New and existing subscribers",
};

const DAY = 86_400_000;

/** A start date typed into a date box: it must be tomorrow or later (a price never starts in the past) and within a year. Returns plain words when it cannot be used. */
export function scheduleDateError(value: string, now: Date = new Date()): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return "Choose the date the new price starts.";
  const start = Date.parse(`${value}T00:00:00Z`);
  if (Number.isNaN(start)) return "Choose a real date.";
  const todayStart = Date.parse(`${now.toISOString().slice(0, 10)}T00:00:00Z`);
  if (start <= todayStart)
    return "A new price starts tomorrow at the earliest. It can never start in the past.";
  if (start > now.getTime() + 365 * DAY)
    return "A price change can be scheduled at most a year ahead.";
  return null;
}

/** The moment a date box means: the start of that day, in UTC. */
export function startOfDayUtc(value: string): string {
  return new Date(`${value}T00:00:00Z`).toISOString();
}

/** Tomorrow's date as a date-box value, the earliest a price can start. */
export function tomorrow(now: Date = new Date()): string {
  return new Date(Date.parse(`${now.toISOString().slice(0, 10)}T00:00:00Z`) + DAY)
    .toISOString()
    .slice(0, 10);
}

export const dateLabel = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "short",
        year: "numeric",
        timeZone: "UTC",
      })
    : "–";

type TermsLike = {
  subscription_amount: number | string | null;
  free_trial_days: number | string | null;
  onboarding_free_orders: number | string | null;
  monthly_free_orders: number | string | null;
  transaction_fee_percentage: number | string | null;
  transaction_fee_max: number | string | null;
  billing_interval_months?: number | string | null;
};

/** One line for a version's terms, for tables and confirmations. */
export function summariseTerms(t: TermsLike): string {
  const months = Number(t.billing_interval_months ?? 1);
  const parts = [
    `${formatGHS(Number(t.subscription_amount ?? 0))} per ${months === 1 ? "month" : `${months} months`}`,
    Number(t.free_trial_days) > 0 ? `${Number(t.free_trial_days)}-day trial` : "no trial",
  ];
  const free = Number(t.onboarding_free_orders) + Number(t.monthly_free_orders);
  if (free > 0)
    parts.push(
      `${Number(t.onboarding_free_orders)} launch + ${Number(t.monthly_free_orders)} monthly free orders`,
    );
  const pct = Number(t.transaction_fee_percentage ?? 0);
  parts.push(
    pct > 0
      ? `${pct}% commission${t.transaction_fee_max != null && t.transaction_fee_max !== "" ? ` (at most ${formatGHS(Number(t.transaction_fee_max))} an order)` : ""}`
      : "no commission",
  );
  return parts.join(" · ");
}

/** The sentences a money-related confirmation shows before anything is saved. */
export function confirmationLines(input: {
  preview: PricePreview;
  scheduled: boolean;
  startsOn: string | null;
}): string[] {
  const { preview, scheduled, startsOn } = input;
  const lines: string[] = [];
  for (const c of preview.changes) {
    const show = (v: unknown) => (v === null || v === undefined ? "none" : String(v));
    lines.push(`${c.label}: ${show(c.from)} → ${show(c.to)}`);
  }
  if (!scheduled) {
    lines.push("It takes effect at once for every business that subscribes from now on.");
    lines.push(
      preview.existing.total > 0
        ? `${preview.existing.total} existing business(es) on this plan keep their current terms until you move them.`
        : "No existing business is on this plan.",
    );
    return lines;
  }
  lines.push(
    `It starts on ${startsOn ?? "the date chosen"}. Businesses that subscribe before then are not affected.`,
  );
  if (preview.audience === "new_and_existing") {
    lines.push(
      preview.existing.affected > 0
        ? `${preview.existing.affected} existing business(es) move to it at the start of their own next billing cycle on or after that date.`
        : "No existing business would be moved.",
    );
    if (preview.existing.skipped > 0)
      lines.push(`${preview.existing.skipped} business(es) are left out (see the list).`);
  } else {
    lines.push("Existing businesses stay on their current terms until you move them.");
  }
  return lines;
}

/** What a business-level confirmation must say about what is NOT touched, so the owner knows. */
export const PROTECTED_NOTE =
  "Invoices already issued, orders already assessed and the money ledger are never changed by a price change.";
