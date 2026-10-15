// The guided Billing Setup: four stages (Configure Billing, Set Up Invoices, Run the 14-Day Shadow Test, Activate Pilot Businesses) and one readiness picture.
// Nothing here works out a bill. The stages are read off the database's own readiness checklist and reconciliation, plus the independent shadow review; what is added is plain wording and a stricter
// rule for the screens: real billing is not offered until a shadow period has actually run (at least 14 days, with orders assessed) and every automatic check agrees.
import { supabase } from "@/integrations/supabase/client";
import type { PlanRow, ReconciliationReport } from "@/lib/billing";
import { RECONCILIATION_LABELS } from "@/lib/billing";
import {
  createPlan,
  latestVersion,
  paramsFromTermsForm,
  publishPlanVersion,
  setPlanAvailability,
  describeTermsChange,
  termsFormFromVersion,
} from "@/lib/billing-plans";
import type { Readiness, ReadinessCheck } from "@/lib/billing-rollout";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export const SHADOW_DAYS_REQUIRED = 14;

// ---------- the independent shadow review ----------

export type ShadowReviewCheck = {
  key: string;
  label: string;
  severity: "critical" | "warning";
  count: number;
};
export type ShadowReviewRow = {
  check: string;
  order_id: string;
  order_number: string;
  business_name: string;
  recorded: number;
  recalculated: number;
  difference: number;
  note: string;
};
export type ShadowReview = {
  checked_at: string;
  assessments_total: number;
  recomputed: number;
  recorded_fee_total: number;
  recalculated_fee_total: number;
  checks: ShadowReviewCheck[];
  rows: ShadowReviewRow[];
};

/** The review function is added by a separate database update; until it is applied the page says so instead of failing. */
export type ShadowReviewResult =
  { available: true; review: ShadowReview } | { available: false; reason: string };

export async function fetchShadowReview(limit = 25): Promise<ShadowReviewResult> {
  const { data, error } = await db.rpc("admin_billing_shadow_review", { p_limit: limit });
  if (error) {
    const text = `${error.code ?? ""} ${error.message ?? ""}`;
    if (/PGRST202|42883|could not find the function|does not exist/i.test(text))
      return {
        available: false,
        reason: "The shadow review has not been added to the database yet.",
      };
    throw new Error(error.message);
  }
  return { available: true, review: data as ShadowReview };
}

// ---------- the four stages ----------

export type StageKey = "configure" | "invoices" | "shadow" | "activate";
export type ItemStatus = "done" | "pending" | "problem" | "advice";
export type SetupItem = {
  key: string;
  label: string;
  status: ItemStatus;
  /** An unfinished blocking item stops real billing being switched on. */
  blocking: boolean;
  detail: string;
};
export type StageStatus = "complete" | "current" | "upcoming" | "attention";
export type SetupStage = {
  key: StageKey;
  number: number;
  title: string;
  summary: string;
  status: StageStatus;
  items: SetupItem[];
  done: number;
  total: number;
};
export type SetupStatus = {
  stages: SetupStage[];
  /** The first stage that still has something to do. */
  current: StageKey | null;
  /** Everything the screens require before real billing can be switched on. */
  blockers: string[];
  canActivate: boolean;
  /** Share of the required items that are done, 0 to 100. */
  percent: number;
};

export const STAGE_TITLES: Record<StageKey, string> = {
  configure: "Configure Billing",
  invoices: "Set Up Invoices",
  shadow: "Run 14-Day Shadow Test",
  activate: "Activate Pilot Businesses",
};
const STAGE_ORDER: StageKey[] = ["configure", "invoices", "shadow", "activate"];

const check = (r: Readiness, key: string): ReadinessCheck | undefined =>
  r.checks.find((c) => c.key === key);

const item = (
  key: string,
  label: string,
  ok: boolean,
  detail: string,
  opts: { blocking?: boolean; problem?: boolean } = {},
): SetupItem => ({
  key,
  label,
  blocking: opts.blocking ?? true,
  status: ok ? "done" : opts.problem ? "problem" : (opts.blocking ?? true) ? "pending" : "advice",
  detail,
});

/** A plan a business of this kind can be started on: switched on, with a published version. */
export function activePlan(plans: PlanRow[], type: "pharmacy" | "wholesaler"): PlanRow | undefined {
  return plans.find(
    (p) =>
      p.business_type === type &&
      p.active &&
      p.billing_plan_versions.some((v) => v.status === "published"),
  );
}

function criticalFindings(
  recon: ReconciliationReport | null,
  review: ShadowReviewResult | null,
): { reconciliation: number; review: number; reviewKnown: boolean } {
  return {
    reconciliation: recon
      ? recon.checks.filter((c) => c.count > 0 && c.severity === "critical").length
      : 0,
    review:
      review && review.available
        ? review.review.checks.filter((c) => c.severity === "critical" && c.count > 0).length
        : 0,
    reviewKnown: Boolean(review && review.available),
  };
}

export function buildSetupStatus(input: {
  readiness: Readiness;
  plans: PlanRow[];
  reconciliation: ReconciliationReport | null;
  review: ShadowReviewResult | null;
}): SetupStatus {
  const { readiness: r, plans, reconciliation, review } = input;
  const wholesale = activePlan(plans, "wholesaler");
  const pharmacy = activePlan(plans, "pharmacy");
  const found = criticalFindings(reconciliation, review);
  const shadowRunning = r.platform_mode !== "disabled";
  const days = r.shadow.days;

  const configure: SetupItem[] = [
    item(
      "wholesale_pricing",
      "Wholesaler pricing is set and switched on",
      Boolean(wholesale),
      wholesale
        ? `${wholesale.name}: subscription, free orders, fee and limits are saved.`
        : "Set the subscription, trial, free orders, fee percentage, limits and cap.",
    ),
    item(
      "pharmacy_pricing",
      "Pharmacy pricing is set and switched on",
      Boolean(pharmacy),
      pharmacy ? `${pharmacy.name} is on.` : "Needed only if pharmacies will be billed.",
      { blocking: false },
    ),
    item(
      "zero_commission",
      "Paystack platform commission is zero",
      check(r, "zero_commission")?.ok ?? false,
      "Billing is the only revenue mechanism, so a business is never charged twice. This is set under Payments.",
    ),
  ];

  const invoices: SetupItem[] = [
    item(
      "issuer",
      "Invoices say who they are from and how to pay",
      check(r, "issuer")?.ok ?? false,
      "Enter the issuer name and the payment instructions.",
    ),
    item(
      "terms",
      "Payment terms are chosen",
      true,
      check(r, "terms")?.detail ||
        "Days to pay, grace period and what happens when an invoice is not paid.",
      { blocking: false },
    ),
  ];

  const reconDone = reconciliation !== null && found.reconciliation === 0;
  const reviewDone = found.reviewKnown && found.review === 0;
  const shadow: SetupItem[] = [
    item(
      "shadow_started",
      "The shadow test has been started",
      shadowRunning,
      shadowRunning
        ? "Billing is recording what would be charged. Nothing is charged."
        : "Start it, so billing records what each business would be charged.",
    ),
    item(
      "subscriptions",
      "At least one business is on a plan in the test",
      check(r, "subscriptions")?.ok ?? false,
      check(r, "subscriptions")?.detail || "Add a business to the test.",
    ),
    item(
      "scheduler",
      "The scheduled billing run is running",
      check(r, "scheduler")?.ok ?? false,
      check(r, "scheduler")?.detail ?? "",
    ),
    item(
      "orders",
      "Real orders have been assessed",
      r.shadow.orders_assessed > 0,
      r.shadow.orders_assessed > 0
        ? `${r.shadow.orders_assessed} orders assessed across ${r.shadow.businesses} businesses.`
        : "No order has been assessed yet. A test with no orders proves nothing.",
    ),
    item(
      "days",
      `The test has run for ${SHADOW_DAYS_REQUIRED} days`,
      days >= SHADOW_DAYS_REQUIRED,
      r.shadow.since
        ? `Day ${Math.min(days, SHADOW_DAYS_REQUIRED)} of ${SHADOW_DAYS_REQUIRED}.`
        : "Not started.",
    ),
    item(
      "reconciliation",
      "The billing books agree (reconciliation)",
      reconDone,
      reconciliation === null
        ? "Not checked yet."
        : found.reconciliation === 0
          ? "Every consistency check agrees."
          : `${found.reconciliation} checks disagree. See the automatic checks below.`,
      { problem: reconciliation !== null && found.reconciliation > 0 },
    ),
    item(
      "recalculation",
      "Every shadow fee matches its recalculation",
      reviewDone,
      !review || !review.available
        ? "The independent recalculation is not available until the database update is applied."
        : found.review === 0
          ? `${review.review.recomputed} fees recalculated; none differ.`
          : "Some fees differ from their recalculation. See the automatic checks below.",
      // Until the database update is applied the page cannot look, so it does not block; once it can look, it must agree.
      { blocking: found.reviewKnown, problem: found.reviewKnown && found.review > 0 },
    ),
  ];

  const live = r.live.live;
  const activate: SetupItem[] = [
    item(
      "authorized",
      "A platform administrator confirms and gives a reason",
      r.platform_mode === "active",
      r.platform_mode === "active"
        ? "Real billing is switched on."
        : "Switching on needs the confirmation phrase and a written reason. It is audited.",
    ),
    item(
      "held_back",
      "Every business starts held back in shadow",
      r.platform_mode === "active" ? r.live.waiting === 0 : true,
      "Nobody is charged until you put a business live yourself.",
      { blocking: false },
    ),
    item(
      "pilots_live",
      "Pilot businesses are put live one at a time",
      live > 0,
      live > 0 ? `${live} business${live === 1 ? " is" : "es are"} live.` : "None is live yet.",
      { blocking: false },
    ),
  ];

  const groups: [StageKey, SetupItem[], string][] = [
    ["configure", configure, "Prices, trial, free orders, fee, limits and cap."],
    ["invoices", invoices, "Who invoices are from, and how to pay."],
    ["shadow", shadow, "Billing records what it would charge, and nothing is charged."],
    ["activate", activate, "Switch real billing on, then put each pilot live."],
  ];
  const stages: SetupStage[] = groups.map(([key, items, summary]) => ({
    key,
    number: STAGE_ORDER.indexOf(key) + 1,
    title: STAGE_TITLES[key],
    summary,
    status: "upcoming",
    items,
    done: items.filter((i) => i.status === "done").length,
    total: items.length,
  }));

  // What stops real billing being switched on: every unfinished required item in the first three stages, then anything the database itself still requires.
  const gated = stages.filter((s) => s.key !== "activate");
  const unfinished = (s: SetupStage) => s.items.filter((i) => i.blocking && i.status !== "done");
  const covered = new Set([
    "zero_commission",
    "issuer",
    "subscriptions",
    "scheduler",
    "reconciliation",
  ]);
  const fromDatabase = r.checks
    .filter((c) => c.blocking && !c.ok && !covered.has(c.key) && !(c.key === "plans" && !wholesale))
    .map((c) => c.label);
  const blockers = [
    ...new Set([...gated.flatMap((s) => unfinished(s).map((i) => i.label)), ...fromDatabase]),
  ];
  const required = gated.flatMap((s) => s.items.filter((i) => i.blocking));
  const percent = required.length
    ? Math.round((required.filter((i) => i.status === "done").length / required.length) * 100)
    : 0;
  const isActive = r.platform_mode === "active";
  const canActivate = blockers.length === 0 && !isActive;

  // The current stage is the first with something left to do; a disagreement is shown as needing attention.
  const firstOpen = gated.find(
    (s) => unfinished(s).length > 0 || (s.key === "configure" && fromDatabase.length > 0),
  );
  const current: StageKey | null = firstOpen
    ? firstOpen.key
    : isActive && live > 0
      ? null
      : "activate";
  for (const s of stages) {
    if (s.key === "activate") {
      s.status =
        isActive && live > 0 ? "complete" : current === "activate" ? "current" : "upcoming";
    } else if (unfinished(s).length === 0 && !(s.key === "configure" && fromDatabase.length > 0)) {
      s.status = "complete";
    } else if (s.items.some((i) => i.status === "problem")) {
      s.status = "attention";
    } else {
      s.status = s.key === current ? "current" : "upcoming";
    }
  }
  return { stages, current, blockers, canActivate, percent };
}

/** The reconciliation's failing checks in the administrator's words, worst first. */
export function reconciliationProblems(
  report: ReconciliationReport | null,
): { label: string; count: number; severity: "critical" | "warning"; details: unknown }[] {
  if (!report) return [];
  return report.checks
    .filter((c) => c.count > 0)
    .map((c) => ({
      label: RECONCILIATION_LABELS[c.check] ?? c.check.replace(/_/g, " "),
      count: c.count,
      severity: c.severity,
      details: c.details,
    }))
    .sort((a, b) =>
      a.severity === b.severity ? b.count - a.count : a.severity === "critical" ? -1 : 1,
    );
}

/** One sentence for the top of the automatic checks. */
export function checksHeadline(
  report: ReconciliationReport | null,
  review: ShadowReviewResult | null,
): { tone: "good" | "bad" | "unknown"; text: string } {
  if (!report) return { tone: "unknown", text: "The checks have not run yet." };
  const problems = reconciliationProblems(report).length;
  const reviewProblems =
    review && review.available ? review.review.checks.filter((c) => c.count > 0).length : 0;
  const total = problems + reviewProblems;
  if (total === 0)
    return {
      tone: "good",
      text:
        review && review.available
          ? `Everything agrees: ${report.checks.length} consistency checks and ${review.review.recomputed} recalculated fees.`
          : `The ${report.checks.length} consistency checks agree.`,
    };
  return {
    tone: "bad",
    text: `${total} thing${total === 1 ? " needs" : "s need"} attention. Nothing was changed.`,
  };
}

// ---------- configuring the pricing ----------

export type PricingStep = "create" | "publish" | "activate";

export const STANDARD_PLAN: Record<"pharmacy" | "wholesaler", { code: string; name: string }> = {
  wholesaler: { code: "wholesale-standard", name: "Wholesale Standard" },
  pharmacy: { code: "pharmacy-standard", name: "Pharmacy Standard" },
};

/** The plan the pricing form edits: the switched-on plan for that kind of business, or failing that the newest standard plan. */
export function pricingTarget(
  plans: PlanRow[],
  type: "pharmacy" | "wholesaler",
): PlanRow | undefined {
  const ofType = plans.filter((p) => p.business_type === type && p.kind === "standard");
  return ofType.find((p) => p.active) ?? ofType[0];
}

/**
 * What saving the pricing needs to do, given what exists. Each step checks current state first, so saving again after a failure carries on from where it stopped.
 * Returns no steps when nothing would change.
 */
export function pricingSteps(
  plan: PlanRow | undefined,
  type: "pharmacy" | "wholesaler",
  values: Record<string, string>,
): PricingStep[] {
  if (!plan) return ["create", "publish", "activate"];
  const latest = latestVersion(plan);
  const published = plan.billing_plan_versions.some((v) => v.status === "published");
  const steps: PricingStep[] = [];
  if (!published || describeTermsChange(termsFormFromVersion(latest), values, type).length > 0)
    steps.push("publish");
  if (!plan.active) steps.push("activate");
  return steps;
}

/** What the saving of the pricing changed, in words. */
export function describePricingSave(steps: PricingStep[], name: string): string {
  if (steps.length === 0) return "Nothing changed.";
  const parts: string[] = [];
  if (steps.includes("create")) parts.push("the plan was created");
  if (steps.includes("publish")) parts.push("the new terms were published");
  if (steps.includes("activate")) parts.push("the plan was switched on");
  const text = parts.join(", ");
  return `${name}: ${text.charAt(0).toUpperCase()}${text.slice(1)}.`;
}

export type PricingSaveResult = { steps: PricingStep[]; planId: string };

/**
 * Saves pricing through the existing audited plan operations: create the plan if there is none, publish a new version if the terms changed, and switch the plan on if it is off.
 * A failed step reports which step failed and what was already done.
 */
export async function savePricing(input: {
  plan: PlanRow | undefined;
  type: "pharmacy" | "wholesaler";
  values: Record<string, string>;
  reason: string;
}): Promise<PricingSaveResult> {
  const { plan, type, values, reason } = input;
  const latest = plan ? latestVersion(plan) : undefined;
  const { params, error } = paramsFromTermsForm(values, type, {
    currency: latest?.currency,
    entitlements: latest?.entitlements,
    metadata: latest?.metadata,
  });
  if (error) throw new Error(error);
  const steps = pricingSteps(plan, type, values);
  if (steps.length === 0) return { steps, planId: plan!.id };
  const done: PricingStep[] = [];
  const fail = (step: PricingStep, e: unknown): never => {
    const what = {
      create: "creating the plan",
      publish: "publishing the terms",
      activate: "switching the plan on",
    }[step];
    const already = done.length
      ? ` Already done: ${describePricingSave(done, "this save").replace("this save: ", "").toLowerCase()}`
      : "";
    throw new Error(
      `Stopped while ${what}: ${e instanceof Error ? e.message : "it did not work."}${already} Save again to carry on.`,
    );
  };
  let planId = plan?.id ?? "";
  if (steps.includes("create")) {
    try {
      planId = await createPlan({
        code: STANDARD_PLAN[type].code,
        businessType: type,
        name: STANDARD_PLAN[type].name,
        description: "",
        kind: "standard",
        reason,
      });
      done.push("create");
    } catch (e) {
      fail("create", e);
    }
  }
  if (steps.includes("publish")) {
    try {
      await publishPlanVersion(planId, params, reason);
      done.push("publish");
    } catch (e) {
      fail("publish", e);
    }
  }
  if (steps.includes("activate")) {
    try {
      await setPlanAvailability(planId, true, plan?.publicly_visible ?? false, reason);
      done.push("activate");
    } catch (e) {
      fail("activate", e);
    }
  }
  return { steps, planId };
}
