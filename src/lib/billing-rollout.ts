// Going live, from the screens' side: the readiness checklist, switching real billing on, putting businesses live one at a time, the account-status policy and the notices.
// Every action is one request to an audited database function that decides whether it is allowed; nothing here works out a bill.
import { supabase } from "@/integrations/supabase/client";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

async function call<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

export const ACTIVATION_PHRASE = "ACTIVATE BILLING";

export type ReadinessCheck = {
  key: string;
  label: string;
  blocking: boolean;
  ok: boolean;
  detail: string;
};

export type Readiness = {
  platform_mode: "disabled" | "shadow" | "active";
  ready: boolean;
  checks: ReadinessCheck[];
  shadow: {
    since: string | null;
    days: number;
    businesses: number;
    orders_assessed: number;
    estimated_revenue: number;
  };
  live: { live: number; held_back: number; disabled: number; waiting: number };
};

export const fetchReadiness = () => call<Readiness>("admin_billing_readiness", {});

export type NotificationSettings = {
  invoice_issued: boolean;
  payment_received: boolean;
  invoice_overdue: boolean;
  trial_ending: boolean;
  free_orders_low: boolean;
  grace_ending: boolean;
  suspended: boolean;
  restored: boolean;
  trial_days_before: number[];
  grace_days_before: number;
  free_orders_threshold: number;
};

export type RolloutStatus = {
  platform: {
    mode: "disabled" | "shadow" | "active";
    enforcement: "none" | "block_new_orders";
    grace_days: number;
    payment_terms_days: number;
    notifications: NotificationSettings;
    updated_at: string;
  };
  run: {
    last_run_at: string | null;
    runs: number;
    minutes_since: number | null;
    stale: boolean;
    last_result: Record<string, unknown>;
  };
  counts: {
    subscriptions: number;
    live: number;
    held_back: number;
    disabled: number;
    past_due: number;
    grace_period: number;
    suspended: number;
    overdue_invoices: number;
    overdue_amount: number;
  };
  recent_notices: {
    event_type: string;
    sent_at: string;
    recipients: number;
    business_name: string | null;
  }[];
};

export const fetchRolloutStatus = () => call<RolloutStatus>("admin_billing_rollout_status", {});

export const activatePlatform = (holdBack: boolean, confirmation: string, reason: string) =>
  call<{ mode: string; held_back: number; live: number }>("admin_billing_activate_platform", {
    p_hold_back: holdBack,
    p_confirmation: confirmation,
    p_reason: reason,
  });

export const goLiveBusiness = (businessId: string, activateAt: Date | null, reason: string) =>
  call<{ activated_at: string; trial_end: string | null; status: string }>(
    "admin_billing_go_live_business",
    {
      p_business_id: businessId,
      p_activate_at: activateAt ? activateAt.toISOString() : null,
      p_reason: reason,
    },
  );

export const setGraceDays = (days: number, reason: string) =>
  call<number>("admin_billing_set_grace_days", { p_days: days, p_reason: reason });

export const setEnforcement = (policy: "none" | "block_new_orders", reason: string) =>
  call<string>("admin_billing_set_enforcement", { p_policy: policy, p_reason: reason });

export const setNotificationSettings = (config: Partial<NotificationSettings>, reason: string) =>
  call<NotificationSettings>("admin_billing_set_notification_settings", {
    p_config: config,
    p_reason: reason,
  });

export const extendGrace = (businessId: string, until: Date, reason: string) =>
  call<{ until: string; status: string }>("admin_billing_extend_grace", {
    p_business_id: businessId,
    p_until: until.toISOString(),
    p_reason: reason,
  });

// ---------------------------------------------------------------------------
// Wording and small checks (pure, tested)
// ---------------------------------------------------------------------------
export const ENFORCEMENT_LABELS: Record<
  RolloutStatus["platform"]["enforcement"],
  { label: string; help: string }
> = {
  none: {
    label: "Warnings only",
    help: "A business that does not pay is warned and its status changes, but nothing is blocked.",
  },
  block_new_orders: {
    label: "Block new orders after the grace period",
    help: "A suspended business cannot place new orders, and suppliers who are suspended stop receiving new ones. Orders already in progress carry on.",
  },
};

export const NOTICE_LABELS: { key: keyof NotificationSettings; label: string }[] = [
  { key: "invoice_issued", label: "An invoice is ready" },
  { key: "payment_received", label: "A payment was received" },
  { key: "invoice_overdue", label: "An invoice is overdue" },
  { key: "trial_ending", label: "The free trial is ending" },
  { key: "free_orders_low", label: "Free orders are almost used up, or used up" },
  { key: "grace_ending", label: "The grace period is ending" },
  { key: "suspended", label: "The account is suspended" },
  { key: "restored", label: "The account is back in good standing" },
];

export const NOTICE_EVENT_LABELS: Record<string, string> = {
  invoice_issued: "Invoice ready",
  payment_received: "Payment received",
  invoice_overdue: "Invoice overdue",
  trial_ending: "Trial ending",
  free_orders_low: "Free orders low",
  grace_ending: "Grace ending",
  suspended: "Suspended",
  restored: "Restored",
  admin: "Administrator alert",
};

/** The activation button stays disabled until the exact phrase is typed and a reason is given. */
export function canActivate(input: { ready: boolean; phrase: string; reason: string }): boolean {
  return (
    input.ready && input.phrase.trim() === ACTIVATION_PHRASE && input.reason.trim().length >= 5
  );
}

/** What is still in the way, in the checklist's own words (blocking items only). */
export function blockers(r: Pick<Readiness, "checks">): string[] {
  return r.checks.filter((c) => c.blocking && !c.ok).map((c) => c.label);
}

/** "3 days of shadow data" / "no shadow data yet". */
export function shadowSummary(s: Readiness["shadow"]): string {
  if (!s.since) return "No shadow billing data yet.";
  const d = s.days === 1 ? "1 day" : `${s.days} days`;
  return `${d} of shadow data: ${s.orders_assessed} ${s.orders_assessed === 1 ? "order" : "orders"} across ${s.businesses} ${s.businesses === 1 ? "business" : "businesses"}.`;
}

/** Where a business stands in the rollout. */
export function rolloutStage(
  row: {
    activated_at?: string | null;
    effective_mode: string;
    billing_mode: string | null;
    status: string;
  },
  now: Date = new Date(),
): {
  label: string;
  tone: "live" | "scheduled" | "held" | "off" | "ended";
} {
  if (row.status === "cancelled") return { label: "Ended", tone: "ended" };
  if (row.activated_at) {
    return new Date(row.activated_at).getTime() > now.getTime()
      ? { label: "Going live soon", tone: "scheduled" }
      : { label: "Live", tone: "live" };
  }
  if (row.billing_mode === "disabled" || row.effective_mode === "disabled")
    return { label: "Off", tone: "off" };
  return { label: "Held back (shadow)", tone: "held" };
}
