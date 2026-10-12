// The administrator's billing controls, from the screens' side. Every action here sends a plain request (what to change, and why) to an audited database function; the browser never works
// out a fee or a balance. The database refuses what is not allowed and its message is shown as it is.
import { supabase } from "@/integrations/supabase/client";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

async function call<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

export const extendTrial = (businessId: string, newTrialEnd: Date, reason: string) =>
  call<{ new_trial_end: string; periods_waived: number; waived_amount: number }>(
    "admin_billing_extend_trial",
    {
      p_business_id: businessId,
      p_new_trial_end: newTrialEnd.toISOString(),
      p_reason: reason,
    },
  );

export const grantFreeOrders = (
  businessId: string,
  quantity: number,
  expiresAt: Date | null,
  reason: string,
  requestKey: string,
) =>
  call<{ grant_id: string; replayed: boolean }>("admin_billing_grant_free_orders", {
    p_business_id: businessId,
    p_quantity: quantity,
    p_expires_at: expiresAt ? expiresAt.toISOString() : null,
    p_reason: reason,
    p_request_key: requestKey,
  });

export const applyCredit = (
  businessId: string,
  amount: number,
  kind: "manual_credit" | "promotional_credit",
  reason: string,
  requestKey: string,
) =>
  call<{ ledger_entry_id: string; replayed: boolean }>("admin_billing_apply_credit", {
    p_business_id: businessId,
    p_amount: amount,
    p_kind: kind,
    p_reason: reason,
    p_request_key: requestKey,
  });

export const applyCharge = (
  businessId: string,
  amount: number,
  reason: string,
  requestKey: string,
) =>
  call<{ ledger_entry_id: string; replayed: boolean }>("admin_billing_apply_charge", {
    p_business_id: businessId,
    p_amount: amount,
    p_reason: reason,
    p_request_key: requestKey,
  });

export const waiveFee = (businessId: string, orderId: string, reason: string) =>
  call<{ ledger_entry_id: string; amount: number; order_number: string }>(
    "admin_billing_waive_fee",
    {
      p_business_id: businessId,
      p_order_id: orderId,
      p_reason: reason,
    },
  );

export const setExemption = (businessId: string, exempt: boolean, reason: string) =>
  call("admin_billing_set_exemption", {
    p_business_id: businessId,
    p_exempt: exempt,
    p_reason: reason,
  });

export const setPaused = (businessId: string, paused: boolean, reason: string) =>
  call("admin_billing_set_paused", {
    p_business_id: businessId,
    p_paused: paused,
    p_reason: reason,
  });

export const setCancellation = (businessId: string, cancel: boolean, reason: string) =>
  call<string | null>("admin_billing_set_cancellation", {
    p_business_id: businessId,
    p_cancel: cancel,
    p_reason: reason,
  });

export const setCustomTerms = (
  businessId: string,
  overrides: Record<string, number | null>,
  effectiveFrom: Date | null,
  reason: string,
) =>
  call<{ terms_id: string; effective_from: string }>("admin_billing_set_custom_terms", {
    p_business_id: businessId,
    p_overrides: overrides,
    p_effective_from: effectiveFrom ? effectiveFrom.toISOString() : null,
    p_reason: reason,
  });

export const changePlan = (
  businessId: string,
  planCode: string,
  effectiveFrom: Date | null,
  keepOverrides: boolean,
  reason: string,
) =>
  call<{ terms_id: string; effective_from: string; plan_version: number }>(
    "admin_billing_change_plan",
    {
      p_business_id: businessId,
      p_plan_code: planCode,
      p_effective_from: effectiveFrom ? effectiveFrom.toISOString() : null,
      p_keep_overrides: keepOverrides,
      p_reason: reason,
    },
  );

export const addTemporaryTerms = (
  businessId: string,
  overrides: Record<string, number | boolean | null>,
  startsAt: Date | null,
  endsAt: Date,
  reason: string,
) =>
  call<{ window_id: string; starts_at: string; ends_at: string }>(
    "admin_billing_add_temporary_terms",
    {
      p_business_id: businessId,
      p_overrides: overrides,
      p_starts_at: startsAt ? startsAt.toISOString() : null,
      p_ends_at: endsAt.toISOString(),
      p_reason: reason,
    },
  );

export const endTemporaryTerms = (windowId: string, reason: string) =>
  call("admin_billing_end_temporary_terms", { p_window_id: windowId, p_reason: reason });

export type PromotionBenefits = {
  free_trial_days?: number;
  free_orders?: number;
  subscription_discount_percent?: number;
  discount_days?: number;
  fee_percentage?: number;
  fee_days?: number;
  fee_waiver_days?: number;
};

export type PromotionStatus = "running" | "off" | "not_started" | "ended" | "full";

export type PromotionRow = {
  id: string;
  code: string;
  name: string;
  description: string | null;
  business_type: "pharmacy" | "wholesaler";
  benefits: PromotionBenefits;
  valid_from: string;
  valid_until: string | null;
  max_redemptions: number | null;
  active: boolean;
  created_at: string;
  reason: string;
  redeemed: number;
  status: PromotionStatus;
};

export const fetchPromotions = () => call<PromotionRow[]>("admin_billing_promotions", {});

export const createPromotion = (input: {
  code: string;
  name: string;
  description: string;
  businessType: "pharmacy" | "wholesaler";
  benefits: PromotionBenefits;
  validFrom: Date | null;
  validUntil: Date | null;
  maxRedemptions: number | null;
  reason: string;
}) =>
  call<string>("admin_billing_create_promotion", {
    p_code: input.code,
    p_name: input.name,
    p_description: input.description || null,
    p_business_type: input.businessType,
    p_benefits: input.benefits,
    p_valid_from: input.validFrom ? input.validFrom.toISOString() : null,
    p_valid_until: input.validUntil ? input.validUntil.toISOString() : null,
    p_max_redemptions: input.maxRedemptions,
    p_reason: input.reason,
  });

export const setPromotionActive = (promotionId: string, active: boolean, reason: string) =>
  call("admin_billing_set_promotion_active", {
    p_promotion_id: promotionId,
    p_active: active,
    p_reason: reason,
  });

export const applyPromotion = (businessId: string, code: string, reason: string) =>
  call<{ redemption_id: string; applied: Record<string, unknown> }>(
    "admin_billing_apply_promotion",
    {
      p_business_id: businessId,
      p_code: code,
      p_reason: reason,
    },
  );

// ---------------------------------------------------------------------------
// Wording and small checks (pure, tested)
// ---------------------------------------------------------------------------
export const PROMOTION_STATUS_LABELS: Record<PromotionStatus, string> = {
  running: "Running",
  off: "Switched off",
  not_started: "Not started",
  ended: "Ended",
  full: "Full",
};

export const OVERRIDE_FIELDS: {
  key: string;
  label: string;
  kind: "money" | "percent" | "count";
  limit?: boolean;
}[] = [
  { key: "subscription_amount", label: "Subscription per period (GH₵)", kind: "money" },
  { key: "transaction_fee_percentage", label: "Platform fee (%)", kind: "percent" },
  { key: "transaction_fee_min", label: "Smallest fee per order (GH₵)", kind: "money", limit: true },
  { key: "transaction_fee_max", label: "Largest fee per order (GH₵)", kind: "money", limit: true },
  {
    key: "transaction_fee_cycle_cap",
    label: "Fee cap per period (GH₵)",
    kind: "money",
    limit: true,
  },
  { key: "monthly_free_orders", label: "Free orders every period", kind: "count" },
  {
    key: "min_billable_order_amount",
    label: "Smallest order that counts (GH₵)",
    kind: "money",
    limit: true,
  },
];

/** A reason must say something: at least five characters once trimmed. */
export function reasonError(reason: string): string | null {
  return reason.trim().length >= 5 ? null : "Give a reason of at least 5 characters.";
}

/** An amount of money typed by a person: more than zero, at most two decimals. Returns the number, or null when it is not valid. */
export function parseMoney(text: string): number | null {
  const t = text.trim();
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  const n = Number(t);
  return n > 0 ? n : null;
}

/**
 * Turns the custom-pricing form into the overrides sent to the database. A field left empty is not overridden (the plan decides); "none" in a limit field removes the limit.
 * Returns an error in plain words instead when a value cannot be used.
 */
export function overridesFromForm(values: Record<string, string>): {
  overrides: Record<string, number | null>;
  error: string | null;
} {
  const overrides: Record<string, number | null> = {};
  for (const f of OVERRIDE_FIELDS) {
    const raw = (values[f.key] ?? "").trim();
    if (raw === "") continue;
    if (f.limit && raw.toLowerCase() === "none") {
      overrides[f.key] = null;
      continue;
    }
    if (!/^\d+(\.\d+)?$/.test(raw))
      return { overrides: {}, error: `${f.label}: enter a number${f.limit ? ' or "none"' : ""}.` };
    const n = Number(raw);
    if (f.kind === "percent" && n > 100)
      return { overrides: {}, error: `${f.label}: a percentage cannot be more than 100.` };
    if (f.kind === "count" && !Number.isInteger(n))
      return { overrides: {}, error: `${f.label}: enter a whole number.` };
    overrides[f.key] = n;
  }
  return { overrides, error: null };
}

/** The overrides as short sentences, for the history and the confirmation. */
export function describeOverrides(overrides: Record<string, unknown> | null | undefined): string[] {
  if (!overrides) return [];
  const out: string[] = [];
  for (const f of OVERRIDE_FIELDS) {
    if (!(f.key in overrides)) continue;
    const v = overrides[f.key];
    const label = f.label.replace(/ \(.*\)$/, "");
    out.push(
      v === null
        ? `${label}: no limit`
        : f.kind === "percent"
          ? `${label}: ${v}%`
          : f.kind === "money"
            ? `${label}: GH₵ ${Number(v).toFixed(2)}`
            : `${label}: ${v}`,
    );
  }
  if (overrides.exempt_from_transaction_fees === true) out.push("No platform fee");
  return out;
}

/** What a promotion gives, in plain words. */
export function describeBenefits(b: PromotionBenefits): string[] {
  const out: string[] = [];
  const days = (n: number) => `${n} ${n === 1 ? "day" : "days"}`;
  if (b.free_trial_days) out.push(`${days(b.free_trial_days)} more free trial`);
  if (b.free_orders) out.push(`${b.free_orders} free ${b.free_orders === 1 ? "order" : "orders"}`);
  if (b.subscription_discount_percent && b.discount_days)
    out.push(
      `${b.subscription_discount_percent}% off the subscription for ${days(b.discount_days)}`,
    );
  if (b.fee_percentage !== undefined && b.fee_days)
    out.push(`${b.fee_percentage}% platform fee for ${days(b.fee_days)}`);
  if (b.fee_waiver_days) out.push(`no platform fee for ${days(b.fee_waiver_days)}`);
  return out;
}

/** The benefits form → the benefits object sent to the database (empty fields are left out). */
export function benefitsFromForm(values: Record<string, string>): {
  benefits: PromotionBenefits;
  error: string | null;
} {
  const keys: (keyof PromotionBenefits)[] = [
    "free_trial_days",
    "free_orders",
    "subscription_discount_percent",
    "discount_days",
    "fee_percentage",
    "fee_days",
    "fee_waiver_days",
  ];
  const benefits: PromotionBenefits = {};
  for (const k of keys) {
    const raw = (values[k] ?? "").trim();
    if (raw === "") continue;
    if (!/^\d+(\.\d+)?$/.test(raw)) return { benefits: {}, error: "Benefits must be numbers." };
    benefits[k] = Number(raw);
  }
  if (Object.keys(benefits).length === 0)
    return { benefits, error: "Choose at least one benefit." };
  if (
    (benefits.subscription_discount_percent !== undefined) !==
    (benefits.discount_days !== undefined)
  )
    return { benefits, error: "A subscription discount needs both the percentage and the days." };
  if ((benefits.fee_percentage !== undefined) !== (benefits.fee_days !== undefined))
    return { benefits, error: "A lower fee needs both the percentage and the days." };
  return { benefits, error: null };
}

/** A date typed into a date box → the moment it means: midday UTC, or null when empty. */
export function dateFromInput(value: string): Date | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const d = new Date(`${value}T12:00:00Z`);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function newKey(prefix = "adm"): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? `${prefix}-${crypto.randomUUID()}`
    : `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}
