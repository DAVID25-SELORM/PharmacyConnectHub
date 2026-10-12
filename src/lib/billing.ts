// Platform billing, from the screens' side. Everything here is READ-ONLY: the browser asks the database what a business's billing looks like and shows it. It never calculates a fee,
// never decides a state and never sends an amount; the figures come from the database functions behind billing_my_overview and the admin_billing_* views.
import { supabase } from "@/integrations/supabase/client";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type BillingState =
  | "no_subscription"
  | "not_started"
  | "trialing"
  | "active"
  | "past_due"
  | "grace_period"
  | "suspended"
  | "paused"
  | "cancelled";

export type MyBillingPeriod = {
  period_start: string;
  period_end: string;
  status: string;
  subscription_amount: number;
  transaction_fees_amount: number | null;
  debits_amount: number;
  credits_amount: number;
  amount_due: number;
  amount_paid: number;
  outstanding_amount: number;
  billable_gmv?: number | null;
  eligible_orders?: number | null;
  free_onboarding_orders?: number | null;
  free_monthly_orders?: number | null;
  chargeable_orders?: number | null;
  fees_before_cap?: number | null;
  cap?: number | null;
  cap_remaining?: number | null;
};

export type BillingOrderRow = {
  order_number: string;
  delivered_at: string | null;
  assessed_at: string;
  kind: "primary" | "adjustment";
  adjustment_seq: number;
  billable_gmv: number;
  outcome: string;
  free_source: "onboarding" | "monthly" | null;
  free_seq: number | null;
  percentage: number | null;
  fee_after_limits: number | null;
  cap_adjustment: number | null;
  charged_amount: number;
};

export type MyBilling = {
  state: BillingState;
  business_type: "pharmacy" | "wholesaler";
  business_name?: string;
  currency?: string;
  plan?: {
    name: string | null;
    code: string;
    subscription_amount: number;
    billing_interval_months: number;
    free_trial_days: number;
    onboarding_free_orders: number | null;
    monthly_free_orders: number | null;
    transaction_fee_percentage: number | null;
    transaction_fee_min: number | null;
    transaction_fee_max: number | null;
    transaction_fee_cycle_cap: number | null;
  } | null;
  subscription?: {
    status: string;
    billing_starts_at: string;
    trial_start: string | null;
    trial_end: string | null;
    trial_days_left: number | null;
    next_billing_date: string | null;
    cancel_at_period_end: boolean;
    ends_at: string | null;
    paused: boolean;
    exempt_from_transaction_fees: boolean | null;
  };
  free_orders?: {
    launch_granted: number;
    launch_used: number;
    launch_remaining: number;
    monthly_allowance: number;
    monthly_used: number;
  } | null;
  current_period?: MyBillingPeriod | null;
  periods?: MyBillingPeriod[];
  orders?: BillingOrderRow[];
  credits_and_adjustments?: {
    created_at: string;
    entry_type: string;
    charged_amount: number;
    credit_amount: number;
    reason: string | null;
  }[];
};

/** What a business sees on its own Billing & Subscription page (real billing only; never anyone else's, never shadow numbers). */
export async function fetchMyBilling(businessId: string): Promise<MyBilling> {
  const { data, error } = await db.rpc("billing_my_overview", { p_business_id: businessId });
  if (error) throw new Error(error.message);
  return data as MyBilling;
}

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------
export const STATE_LABELS: Record<BillingState, string> = {
  no_subscription: "No plan yet",
  not_started: "Billing hasn't started",
  trialing: "Free trial",
  active: "Active",
  past_due: "Payment overdue",
  grace_period: "Payment overdue (grace period)",
  suspended: "Suspended",
  paused: "Paused",
  cancelled: "Cancelled",
};

export function stateMessage(state: BillingState): string {
  switch (state) {
    case "no_subscription":
      return "Your business isn't on a plan yet. Nothing is being charged.";
    case "not_started":
      return "Billing hasn't started for your business yet. Nothing is being charged. Your plan is shown below so you can see what will apply.";
    case "trialing":
      return "You're in your free trial. The subscription is free until the trial ends.";
    case "active":
      return "Your subscription is active.";
    case "past_due":
    case "grace_period":
      return "A payment is overdue. Your account keeps working during the grace period; please settle the balance.";
    case "suspended":
      return "Your subscription is suspended. Please contact DrugXOne.";
    case "paused":
      return "Billing is paused for your business. Nothing is being charged while it is paused.";
    case "cancelled":
      return "This subscription has ended.";
  }
}

/** How one order was billed, in plain business words. */
export function describeBilledOrder(
  row: BillingOrderRow,
  formatMoney: (n: number) => string,
): string {
  const adj = row.kind === "adjustment" ? "Change after delivery: " : "";
  switch (row.outcome) {
    case "free_onboarding":
      return `${adj}Free: launch order ${row.free_seq}`;
    case "free_monthly":
      return `${adj}Free: monthly allowance ${row.free_seq}`;
    case "free_adjustment":
      return `${adj}Free (the order was free)`;
    case "exempt":
      return `${adj}No fee: your business is exempt`;
    case "excluded":
      return `${adj}Not billed`;
    case "below_minimum":
      return `${adj}No fee: below the minimum order value`;
    case "chargeable": {
      const charged = Number(row.charged_amount);
      const capped = Number(row.cap_adjustment ?? 0);
      if (charged < 0) return `${adj}Platform fee credited ${formatMoney(-charged)}`;
      if (capped > 0 && charged === 0) return `${adj}Monthly fee cap reached: no fee`;
      if (capped > 0) return `${adj}Platform fee ${formatMoney(charged)} (monthly cap reached)`;
      return `${adj}Platform fee ${formatMoney(charged)}`;
    }
    default:
      return row.outcome;
  }
}

/** How far through the monthly fee cap a period is, as a percentage (0 to 100), or null when there is no cap. */
export function capProgress(period: {
  transaction_fees_amount: number | null;
  cap?: number | null;
}): number | null {
  if (period.cap === null || period.cap === undefined || period.cap <= 0) return null;
  const used = Number(period.transaction_fees_amount ?? 0);
  return Math.max(0, Math.min(100, Math.round((used / period.cap) * 100)));
}

export function periodLabel(start: string, end: string): string {
  const fmt = (iso: string, withYear: boolean) =>
    new Date(iso).toLocaleDateString("en-GB", {
      day: "numeric",
      month: "short",
      ...(withYear ? { year: "numeric" } : {}),
      timeZone: "UTC",
    });
  // The end is exclusive: show the last day the period covers.
  const lastDay = new Date(new Date(end).getTime() - 1).toISOString();
  return `${fmt(start, false)} – ${fmt(lastDay, true)}`;
}

export function planSummary(
  plan: NonNullable<MyBilling["plan"]>,
  formatMoney: (n: number) => string,
): string[] {
  const every =
    plan.billing_interval_months === 1 ? "month" : `${plan.billing_interval_months} months`;
  const lines = [`${formatMoney(plan.subscription_amount)} / ${every}`];
  if (plan.free_trial_days > 0) lines.push(`${plan.free_trial_days}-day free trial`);
  const launch = plan.onboarding_free_orders ?? 0;
  const monthly = plan.monthly_free_orders ?? 0;
  if (launch > 0) lines.push(`${launch} free launch ${launch === 1 ? "order" : "orders"}`);
  if (monthly > 0) lines.push(`${monthly} free ${monthly === 1 ? "order" : "orders"} every month`);
  if (plan.transaction_fee_percentage !== null && Number(plan.transaction_fee_percentage) > 0) {
    lines.push(
      `${Number(plan.transaction_fee_percentage)}% platform fee on eligible orders after the free ones`,
    );
    if (plan.transaction_fee_min !== null)
      lines.push(`at least ${formatMoney(plan.transaction_fee_min)} per order`);
    if (plan.transaction_fee_max !== null)
      lines.push(`at most ${formatMoney(plan.transaction_fee_max)} per order`);
    if (plan.transaction_fee_cycle_cap !== null)
      lines.push(`platform fees capped at ${formatMoney(plan.transaction_fee_cycle_cap)} a month`);
  }
  return lines;
}

export const ENTRY_LABELS: Record<string, string> = {
  manual_credit: "Credit",
  manual_debit: "Adjustment",
  promotional_credit: "Promotional credit",
  fee_waiver: "Fee waived",
  refund: "Platform fee credited",
  reversal: "Reversal",
};

// ---------------------------------------------------------------------------
// The administrator's views
// ---------------------------------------------------------------------------
export type FlavorSummary = {
  subscription_revenue: number;
  transaction_fee_revenue: number;
  other_debits: number;
  credits: number;
  accrued_revenue: number;
  eligible_gmv: number;
  eligible_orders: number;
  free_orders: number;
  chargeable_orders: number;
  free_order_share_percent: number | null;
  take_rate_percent: number | null;
  invoiced: number;
  collected: number;
  outstanding: number;
  overdue: number;
  not_yet_invoiced: number;
};

export type AdminBillingOverview = {
  from: string;
  to: string;
  platform_mode: "disabled" | "shadow" | "active";
  currency: string;
  marketplace: {
    created_orders: number;
    created_value: number;
    cancelled_value: number;
    completed_orders: number;
    completed_gmv: number;
  };
  real: FlavorSummary;
  shadow: FlavorSummary;
  subscriptions: {
    total: number;
    trialing: number;
    active: number;
    past_due: number;
    suspended: number;
    cancelled: number;
    paused: number;
    exempt: number;
    paying_pharmacies: number;
    paying_wholesalers: number;
    contracted_mrr: number;
  };
  revenue_per_paying_organization: number | null;
  paying_organizations_in_period: number;
};

export type AdminBillingFilters = {
  from?: Date | null;
  to?: Date | null;
  businessType?: "pharmacy" | "wholesaler" | null;
  planCode?: string | null;
  status?: string | null;
};

export async function fetchAdminBillingOverview(
  filters: AdminBillingFilters,
): Promise<AdminBillingOverview> {
  const { data, error } = await db.rpc("admin_billing_overview", {
    p_from: filters.from?.toISOString() ?? null,
    p_to: filters.to?.toISOString() ?? null,
    p_business_type: filters.businessType ?? null,
    p_plan_code: filters.planCode ?? null,
    p_subscription_status: filters.status ?? null,
  });
  if (error) throw new Error(error.message);
  return data as AdminBillingOverview;
}

export type OrganizationRow = {
  business_id: string;
  name: string;
  type: "pharmacy" | "wholesaler";
  plan_code: string | null;
  plan_name: string | null;
  status: string;
  billing_mode: string | null;
  effective_mode: "disabled" | "shadow" | "active";
  billing_starts_at: string;
  trial_end: string | null;
  exempt: boolean;
  paused: boolean;
  period_start: string | null;
  period_end: string | null;
  subscription_amount: number;
  transaction_fees_amount: number;
  eligible_orders: number;
  free_onboarding_orders: number;
  free_monthly_orders: number;
  chargeable_orders: number;
  amount_due: number;
  outstanding_amount: number;
  launch_granted: number;
  launch_used: number;
  last_assessed_at: string | null;
};

export async function fetchAdminBillingOrganizations(input: {
  flavor: "real" | "shadow";
  businessType?: string | null;
  planCode?: string | null;
  status?: string | null;
  search?: string | null;
  limit: number;
  offset: number;
}): Promise<{ total: number; rows: OrganizationRow[] }> {
  const { data, error } = await db.rpc("admin_billing_organizations", {
    p_flavor: input.flavor,
    p_business_type: input.businessType ?? null,
    p_plan_code: input.planCode ?? null,
    p_status: input.status ?? null,
    p_search: input.search ?? null,
    p_limit: input.limit,
    p_offset: input.offset,
  });
  if (error) throw new Error(error.message);
  return data as { total: number; rows: OrganizationRow[] };
}

export type BusinessBillingDetail = {
  business: { id: string; name: string; type: string; license_number: string | null };
  has_subscription: boolean;
  flavor?: "real" | "shadow";
  effective_mode?: string;
  subscription?: Record<string, unknown>;
  terms_now?: Record<string, unknown> | null;
  terms_history?: {
    effective_from: string;
    plan_code: string;
    plan_version: number;
    overrides: Record<string, unknown>;
    reason: string;
  }[];
  grants?: {
    id: string;
    quantity: number;
    source: string;
    reason: string;
    created_at: string;
    expires_at: string | null;
    used: number;
  }[];
  periods?: (MyBillingPeriod & { id: string; fees_before_cap: number })[];
  assessments?: (BillingOrderRow & {
    order_id?: string;
    calculated_fee: number | null;
    rule_version: string;
  })[];
  ledger?: {
    created_at: string;
    entry_type: string;
    gross_amount: number | null;
    percentage: number | null;
    calculated_fee: number | null;
    charged_amount: number;
    credit_amount: number;
    reason: string | null;
    source: string;
  }[];
  audit?: {
    created_at: string;
    activity: string;
    performed_by_email: string | null;
    details: Record<string, unknown>;
  }[];
  queue?: {
    order_id: string;
    kind: string;
    status: string;
    attempts: number;
    error: string | null;
  }[];
  invoices?: {
    id: string;
    invoice_number: string;
    period_start: string;
    period_end: string;
    issued_at: string;
    due_at: string;
    total_amount: number;
    amount_paid: number;
    outstanding_amount: number;
    status: "issued" | "partially_paid" | "paid" | "overdue";
  }[];
  payments?: {
    id: string;
    invoice_number: string;
    kind: "payment" | "reversal";
    amount: number;
    method: string;
    reference: string | null;
    received_at: string;
    recorded_at: string;
    reason: string | null;
  }[];
  credit_available?: number;
  windows?: {
    id: string;
    starts_at: string;
    ends_at: string;
    overrides: Record<string, unknown>;
    source: "promotion" | "admin";
    promotion_code: string | null;
    reason: string;
    ended_early_at: string | null;
    running: boolean;
  }[];
  promotions?: {
    code: string;
    name: string;
    redeemed_at: string;
    applied: Record<string, unknown>;
    reason: string;
  }[];
};

export async function fetchAdminBusinessBilling(
  businessId: string,
  flavor: "real" | "shadow",
): Promise<BusinessBillingDetail> {
  const { data, error } = await db.rpc("admin_billing_business_detail", {
    p_business_id: businessId,
    p_flavor: flavor,
  });
  if (error) throw new Error(error.message);
  return data as BusinessBillingDetail;
}

export type ReconciliationReport = {
  checked_at: string;
  healthy: boolean;
  checks: { check: string; severity: "critical" | "warning"; count: number; details: unknown }[];
};

export async function fetchReconciliation(): Promise<ReconciliationReport> {
  const { data, error } = await db.rpc("admin_billing_reconciliation");
  if (error) throw new Error(error.message);
  return data as ReconciliationReport;
}

export const RECONCILIATION_LABELS: Record<string, string> = {
  delivered_order_not_assessed: "Delivered orders that were not assessed",
  duplicate_primary_assessment: "Orders assessed more than once",
  assessment_business_differs_from_order: "Assessments on the wrong business",
  period_transaction_fees_differ_from_ledger: "Period fee totals that differ from the ledger",
  period_credits_differ_from_ledger: "Period credit totals that differ from the ledger",
  period_subscription_differs_from_ledger: "Period subscription totals that differ from the ledger",
  period_counters_differ_from_assessments: "Period order counts that differ from the assessments",
  assessment_charge_differs_from_ledger: "Assessments whose charge differs from the ledger",
  free_order_numbers_not_contiguous: "Free-order numbers with a gap",
  onboarding_grant_overused: "Launch free orders used more than granted",
  period_fees_exceed_the_cap: "Periods whose fees exceed the cap",
  billing_queue_stuck: "Billing retries that are stuck",
  invoice_lines_differ_from_total: "Invoice lines that do not add up to the invoice total",
  invoice_differs_from_its_period: "Invoices that differ from their billing period",
  invoice_paid_differs_from_payments: "Invoices whose paid amount differs from their payments",
  period_paid_or_status_differs_from_invoice:
    "Periods whose paid amount or status differs from their invoice",
  payment_exceeds_invoice_or_reversal_differs:
    "Payments larger than their invoice, or reversals that do not match",
  entries_added_to_an_invoiced_period: "Entries added to a period after it was invoiced",
  invoice_numbers_have_a_gap: "Invoice numbers with a gap",
  credit_used_more_than_available: "Credit used beyond what was available",
  period_not_invoiced_when_it_should_be: "Ended periods that were not invoiced in time",
  period_debits_differ_from_ledger: "Period charge totals that differ from the ledger",
  fee_waived_more_than_charged: "Fee waivers larger than the fee charged",
  promotion_redeemed_beyond_its_limit: "Promotions given to more businesses than their limit",
  admin_ledger_entry_without_audit: "Credits or charges by an administrator with no audit record",
  invoice_overdue_but_not_marked: "Unpaid invoices past their due date that are not marked overdue",
};

export type PlanRow = {
  id: string;
  code: string;
  name: string;
  business_type: "pharmacy" | "wholesaler";
  kind: string;
  active: boolean;
  publicly_visible: boolean;
  billing_plan_versions: {
    version: number;
    status: string;
    subscription_amount: number;
    free_trial_days: number;
    onboarding_free_orders: number;
    monthly_free_orders: number;
    transaction_fee_percentage: number;
    transaction_fee_min: number | null;
    transaction_fee_max: number | null;
    transaction_fee_cycle_cap: number | null;
    billing_interval_months: number;
  }[];
};

export async function fetchPlans(): Promise<PlanRow[]> {
  const { data, error } = await db
    .from("billing_plans")
    .select(
      "id, code, name, business_type, kind, active, publicly_visible, billing_plan_versions(version, status, subscription_amount, free_trial_days, onboarding_free_orders, monthly_free_orders, transaction_fee_percentage, transaction_fee_min, transaction_fee_max, transaction_fee_cycle_cap, billing_interval_months)",
    )
    .order("business_type")
    .order("code");
  if (error) throw new Error(error.message);
  return (data ?? []) as PlanRow[];
}
