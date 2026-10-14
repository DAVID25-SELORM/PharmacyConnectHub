// Plan administration, from the screens' side: creating a plan, publishing a new immutable version of its terms, switching it on or off, starting a business on it, and the platform and per-business billing mode.
// Each action is one request to an audited database function that decides whether it is allowed. The browser only checks that what was typed is a number in range, so that a typo is caught before it is sent.
import { supabase } from "@/integrations/supabase/client";
import type { PlanRow } from "@/lib/billing";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

async function call<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

/** The plan code the database accepts: lower case, starts with a letter, 2 to 40 characters. */
export function planCodeError(code: string): string | null {
  return /^[a-z][a-z0-9_-]{1,39}$/.test(code.trim())
    ? null
    : "The code starts with a lower-case letter and uses only lower-case letters, digits, - or _ (2 to 40 characters).";
}

export function planNameError(name: string): string | null {
  const n = name.trim().length;
  return n >= 2 && n <= 80 ? null : "The name is 2 to 80 characters.";
}

export type PlanTermsKey =
  | "billing_interval_months"
  | "subscription_amount"
  | "free_trial_days"
  | "onboarding_free_orders"
  | "monthly_free_orders"
  | "transaction_fee_percentage"
  | "transaction_fee_min"
  | "transaction_fee_max"
  | "transaction_fee_cycle_cap"
  | "min_billable_order_amount"
  | "max_users"
  | "max_branches";

type FieldKind = "int" | "money" | "percent";
export const PLAN_TERM_FIELDS: {
  key: PlanTermsKey;
  label: string;
  kind: FieldKind;
  /** An empty box means "no limit" (stored as nothing) instead of zero. */
  optional: boolean;
  min: number;
  max?: number;
  help?: string;
  /** Used by a wholesaler's plan only. */
  wholesalerOnly?: boolean;
}[] = [
  {
    key: "subscription_amount",
    label: "Subscription per billing period (GHS)",
    kind: "money",
    optional: false,
    min: 0,
    help: "0 for a plan with no subscription charge.",
  },
  {
    key: "billing_interval_months",
    label: "Billing period (months)",
    kind: "int",
    optional: false,
    min: 1,
    max: 12,
  },
  {
    key: "free_trial_days",
    label: "Free trial (days)",
    kind: "int",
    optional: false,
    min: 0,
    max: 730,
  },
  {
    key: "onboarding_free_orders",
    label: "Launch free orders (once)",
    kind: "int",
    optional: false,
    min: 0,
    max: 10000,
    wholesalerOnly: true,
  },
  {
    key: "monthly_free_orders",
    label: "Free orders each period",
    kind: "int",
    optional: false,
    min: 0,
    max: 10000,
    wholesalerOnly: true,
  },
  {
    key: "transaction_fee_percentage",
    label: "Platform fee (% of the order)",
    kind: "percent",
    optional: false,
    min: 0,
    max: 100,
    wholesalerOnly: true,
  },
  {
    key: "transaction_fee_min",
    label: "Smallest fee per order (GHS)",
    kind: "money",
    optional: true,
    min: 0,
    help: "Empty means no minimum.",
    wholesalerOnly: true,
  },
  {
    key: "transaction_fee_max",
    label: "Largest fee per order (GHS)",
    kind: "money",
    optional: true,
    min: 0,
    help: "Empty means no maximum.",
    wholesalerOnly: true,
  },
  {
    key: "transaction_fee_cycle_cap",
    label: "Most in fees per period (GHS)",
    kind: "money",
    optional: true,
    min: 0,
    help: "Empty means no monthly cap.",
    wholesalerOnly: true,
  },
  {
    key: "min_billable_order_amount",
    label: "Orders below this are not charged (GHS)",
    kind: "money",
    optional: true,
    min: 0,
    wholesalerOnly: true,
  },
  { key: "max_users", label: "Most users", kind: "int", optional: true, min: 1 },
  { key: "max_branches", label: "Most branches", kind: "int", optional: true, min: 1 },
];

/** What a plan version carries that the form does not edit. Publishing starts a new version from the form alone, so these are sent back unchanged or they would be lost. */
export type PlanCarry = {
  currency?: string | null;
  entitlements?: Record<string, unknown> | null;
  metadata?: Record<string, unknown> | null;
};

export type PlanVersionTerms = Partial<Record<PlanTermsKey, number | string | null>> & PlanCarry;

/** The latest published version's figures as the text boxes show them. */
export function termsFormFromVersion(
  v: PlanVersionTerms | null | undefined,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of PLAN_TERM_FIELDS) {
    const raw = v?.[f.key];
    out[f.key] =
      raw === null || raw === undefined
        ? f.optional
          ? ""
          : f.key === "billing_interval_months"
            ? "1"
            : "0"
        : String(Number(raw));
  }
  return out;
}

/**
 * Turns the plan form into the terms sent to the database. A pharmacy's plan has no per-order fee, so its fee figures are sent as zero/none whatever the boxes hold.
 * Returns an error in plain words instead when a value cannot be used.
 */
export function paramsFromTermsForm(
  values: Record<string, string>,
  businessType: "pharmacy" | "wholesaler",
  carry: PlanCarry = {},
): { params: Record<string, unknown>; error: string | null } {
  const params: Record<string, unknown> = {};
  for (const f of PLAN_TERM_FIELDS) {
    if (f.wholesalerOnly && businessType !== "wholesaler") {
      if (f.optional) continue;
      params[f.key] = 0;
      continue;
    }
    const raw = (values[f.key] ?? "").trim();
    if (raw === "") {
      if (f.optional) continue;
      return { params: {}, error: `${f.label}: enter a number.` };
    }
    const pattern =
      f.kind === "int" ? /^\d+$/ : f.kind === "money" ? /^\d+(\.\d{1,2})?$/ : /^\d+(\.\d{1,4})?$/;
    if (!pattern.test(raw)) {
      const hint =
        f.kind === "int"
          ? "a whole number"
          : f.kind === "money"
            ? "an amount with at most two decimals"
            : "a percentage with at most four decimals";
      return { params: {}, error: `${f.label}: enter ${hint}.` };
    }
    const n = Number(raw);
    if (n < f.min || (f.max !== undefined && n > f.max))
      return {
        params: {},
        error: `${f.label}: must be ${f.max !== undefined ? `between ${f.min} and ${f.max}` : `at least ${f.min}`}.`,
      };
    params[f.key] = n;
  }
  const min = params.transaction_fee_min as number | undefined;
  const max = params.transaction_fee_max as number | undefined;
  if (min !== undefined && max !== undefined && max < min)
    return { params: {}, error: "The largest fee per order cannot be less than the smallest." };
  if (carry.currency) params.currency = carry.currency;
  if (carry.entitlements && Object.keys(carry.entitlements).length)
    params.entitlements = carry.entitlements;
  if (carry.metadata && Object.keys(carry.metadata).length) params.metadata = carry.metadata;
  return { params, error: null };
}

/** What changes between two versions, as short sentences for the confirmation. */
export function describeTermsChange(
  before: Record<string, string>,
  after: Record<string, string>,
  businessType: "pharmacy" | "wholesaler",
): string[] {
  const out: string[] = [];
  for (const f of PLAN_TERM_FIELDS) {
    if (f.wholesalerOnly && businessType !== "wholesaler") continue;
    const a = (before[f.key] ?? "").trim();
    const b = (after[f.key] ?? "").trim();
    if (a === b) continue;
    out.push(`${f.label}: ${a === "" ? "none" : a} → ${b === "" ? "none" : b}`);
  }
  return out;
}

export const createPlan = (input: {
  code: string;
  businessType: "pharmacy" | "wholesaler";
  name: string;
  description: string;
  kind: "standard" | "custom";
  reason: string;
}) =>
  call<string>("admin_billing_create_plan", {
    p_code: input.code.trim(),
    p_business_type: input.businessType,
    p_name: input.name.trim(),
    p_description: input.description.trim() || null,
    p_kind: input.kind,
    p_reason: input.reason,
  });

export const publishPlanVersion = (
  planId: string,
  params: Record<string, unknown>,
  reason: string,
) =>
  call<string>("admin_billing_publish_plan_version", {
    p_plan_id: planId,
    p_params: params,
    p_reason: reason,
  });

export const setPlanAvailability = (
  planId: string,
  active: boolean,
  publiclyVisible: boolean,
  reason: string,
) =>
  call<null>("admin_billing_set_plan_availability", {
    p_plan_id: planId,
    p_active: active,
    p_publicly_visible: publiclyVisible,
    p_reason: reason,
  });

/** "follow" is the platform setting; the database stores that as no mode at all. */
export type SubscriptionModeChoice = "follow" | "shadow" | "disabled";

export const startSubscription = (input: {
  businessId: string;
  planCode: string;
  startsAt: Date | null;
  mode: SubscriptionModeChoice;
  reason: string;
}) =>
  call<{ subscription_id: string; launch_grant: string }>("admin_billing_start_subscription", {
    p_business_id: input.businessId,
    p_plan_code: input.planCode,
    p_billing_starts_at: input.startsAt ? input.startsAt.toISOString() : null,
    p_billing_mode: input.mode === "follow" ? null : input.mode,
    p_reason: input.reason,
  });

export const setSubscriptionMode = (
  businessId: string,
  mode: SubscriptionModeChoice,
  reason: string,
) =>
  call<null>("admin_billing_set_subscription_mode", {
    p_business_id: businessId,
    p_mode: mode === "follow" ? null : mode,
    p_reason: reason,
  });

export const setPlatformMode = (mode: "disabled" | "shadow", reason: string) =>
  call<string>("admin_billing_set_mode", { p_mode: mode, p_reason: reason });

export type RunResult = Record<string, unknown>;
export const runBillingNow = (reason: string) =>
  call<RunResult>("admin_billing_run_now", { p_reason: reason });

export const SUBSCRIPTION_MODE_LABELS: Record<SubscriptionModeChoice, string> = {
  follow: "Follow the platform setting",
  shadow: "Shadow: record what would be charged, charge nothing",
  disabled: "Off: no assessment at all",
};

/** The one-line summary of a scheduled run for the toast and the "last run" card. */
export function describeRun(result: RunResult | null | undefined): string {
  if (!result) return "Nothing has run yet.";
  const parts = Object.entries(result)
    .filter(([, v]) => typeof v === "number" && Number.isFinite(v))
    .map(([k, v]) => `${k.replace(/_/g, " ")}: ${v}`);
  return parts.length ? parts.join(" · ") : "The run finished with nothing to do.";
}

export type UnsubscribedBusiness = { id: string; name: string; type: "pharmacy" | "wholesaler" };

/**
 * Approved businesses that are not on a plan yet, matching a name search, at most 50.
 * The "no subscription" test is made by the database (a left join that keeps only the businesses with nothing on the other side), never by sending a long list of ids back: that request is rejected as too long once a few hundred businesses match.
 * The database still refuses a second subscription, so a stale list is harmless.
 */
export async function fetchUnsubscribedBusinesses(search: string): Promise<UnsubscribedBusiness[]> {
  let q = db
    .from("businesses")
    .select("id, name, type, billing_subscriptions(id)")
    .eq("verification_status", "approved")
    .is("billing_subscriptions", null)
    .order("name")
    .limit(50);
  const term = search.trim().replace(/[%,()]/g, " ");
  if (term) q = q.ilike("name", `%${term}%`);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return ((data ?? []) as UnsubscribedBusiness[]).map((b) => ({
    id: b.id,
    name: b.name,
    type: b.type,
  }));
}

/** The newest published version, or failing that the newest of any status. */
export function latestVersion(plan: PlanRow): PlanRow["billing_plan_versions"][number] | undefined {
  const all = [...plan.billing_plan_versions].sort((a, b) => b.version - a.version);
  return all.find((v) => v.status === "published") ?? all[0];
}

/** Plans a business of this kind can be started on: switched on, and with a published version. */
export function plansFor(plans: PlanRow[], type: "pharmacy" | "wholesaler"): PlanRow[] {
  return plans.filter(
    (p) =>
      p.business_type === type &&
      p.active &&
      p.billing_plan_versions.some((v) => v.status === "published"),
  );
}
