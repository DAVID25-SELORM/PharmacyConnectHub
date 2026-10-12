import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { formatGHS } from "@/lib/format";
import {
  OVERRIDE_FIELDS,
  addTemporaryTerms,
  applyCharge,
  applyCredit,
  applyPromotion,
  changePlan,
  dateFromInput,
  describeBenefits,
  describeOverrides,
  endTemporaryTerms,
  extendTrial,
  fetchPromotions,
  grantFreeOrders,
  newKey,
  overridesFromForm,
  parseMoney,
  reasonError,
  setCancellation,
  setCustomTerms,
  setExemption,
  setPaused,
  waiveFee,
  type PromotionRow,
} from "@/lib/billing-controls";
import { fetchPlans, type BusinessBillingDetail, type PlanRow } from "@/lib/billing";
import { dateText } from "@/lib/billing-invoices";
import { extendGrace, fetchRolloutStatus, goLiveBusiness } from "@/lib/billing-rollout";

type Field = {
  key: string;
  label: string;
  type: "text" | "date" | "select" | "checkbox";
  options?: { value: string; label: string }[];
  help?: string;
  initial?: string;
};

type Action = {
  id: string;
  label: string;
  description: string;
  fields: Field[];
  submit: string;
  destructive?: boolean;
  /** Returns the success message, or throws with a message in plain words. */
  run: (v: Record<string, string>, requestKey: string) => Promise<string>;
};

const todayPlus = (days: number) =>
  new Date(Date.now() + days * 86_400_000).toISOString().slice(0, 10);

function currentOverrides(detail: BusinessBillingDetail): Record<string, unknown> {
  const rows = (detail.terms_history ?? []).filter(
    (t) => new Date(t.effective_from).getTime() <= Date.now(),
  );
  return (rows[0]?.overrides as Record<string, unknown>) ?? {};
}

/** The things an administrator can do to one business's billing. Each opens a small form, asks for a reason, and sends one request; the database decides whether it is allowed. */
export function BillingControls({
  detail,
  onChanged,
}: {
  detail: BusinessBillingDetail;
  onChanged: () => void;
}) {
  const businessId = detail.business.id;
  const isWholesaler = detail.business.type === "wholesaler";
  const sub = (detail.subscription ?? {}) as Record<string, unknown>;
  const [plans, setPlans] = useState<PlanRow[]>([]);
  const [promos, setPromos] = useState<PromotionRow[]>([]);
  const [platformMode, setPlatformMode] = useState<string>("disabled");
  const [open, setOpen] = useState<Action | null>(null);
  const [ending, setEnding] = useState<string | null>(null);

  useEffect(() => {
    fetchPlans()
      .then(setPlans)
      .catch(() => setPlans([]));
    fetchPromotions()
      .then(setPromos)
      .catch(() => setPromos([]));
    fetchRolloutStatus()
      .then((st) => setPlatformMode(st.platform.mode))
      .catch(() => setPlatformMode("disabled"));
  }, []);

  const actions = useMemo<Action[]>(() => {
    const overrides = currentOverrides(detail);
    const trialEnd = sub.trial_end ? String(sub.trial_end) : null;
    const list: Action[] = [];
    list.push({
      id: "trial",
      label: "Extend the free trial",
      description: `The trial ${trialEnd ? `now ends ${dateText(trialEnd)}` : "has no end date set"}. Choose a later end date. Subscription charges already on a bill that is still open and start before the new end are cancelled with a credit.`,
      fields: [{ key: "date", label: "New trial end date", type: "date", initial: todayPlus(30) }],
      submit: "Extend trial",
      run: async (v, _k) => {
        const d = dateFromInput(v.date);
        if (!d) throw new Error("Choose the new end date.");
        const r = await extendTrial(businessId, d, v.reason.trim());
        return r.periods_waived > 0
          ? `Trial extended. ${formatGHS(r.waived_amount)} of subscription was waived.`
          : "Trial extended.";
      },
    });
    if (isWholesaler)
      list.push({
        id: "orders",
        label: "Grant free orders",
        description:
          "Extra launch-style free orders. They are used before the monthly free orders, in the order they were granted.",
        fields: [
          { key: "quantity", label: "Number of free orders", type: "text", initial: "5" },
          { key: "expires", label: "Expires on (optional)", type: "date" },
        ],
        submit: "Grant free orders",
        run: async (v, k) => {
          const n = Number(v.quantity);
          if (!Number.isInteger(n) || n < 1) throw new Error("Enter a whole number of orders.");
          const exp = v.expires ? dateFromInput(v.expires) : null;
          const r = await grantFreeOrders(businessId, n, exp, v.reason.trim(), k);
          return r.replayed
            ? "That grant was already recorded."
            : `${n} free ${n === 1 ? "order" : "orders"} granted.`;
        },
      });
    list.push({
      id: "credit",
      label: "Give a credit",
      description:
        "Money off the current bill (it needs real billing to be running). If it is larger than the bill, the rest comes off the next invoice.",
      fields: [
        { key: "amount", label: "Amount (GH₵)", type: "text" },
        {
          key: "kind",
          label: "Kind",
          type: "select",
          initial: "manual_credit",
          options: [
            { value: "manual_credit", label: "Manual credit" },
            { value: "promotional_credit", label: "Promotional credit" },
          ],
        },
      ],
      submit: "Give credit",
      run: async (v, k) => {
        const a = parseMoney(v.amount);
        if (a === null)
          throw new Error("Enter an amount of more than zero, with at most two decimals.");
        const r = await applyCredit(
          businessId,
          a,
          v.kind as "manual_credit" | "promotional_credit",
          v.reason.trim(),
          k,
        );
        return r.replayed
          ? "That credit was already recorded."
          : `${formatGHS(a)} credited to the current bill.`;
      },
    });
    list.push({
      id: "charge",
      label: "Add a charge",
      description:
        "A manual charge on the current bill (it needs real billing to be running), for example to correct an invoice that was too low.",
      fields: [{ key: "amount", label: "Amount (GH₵)", type: "text" }],
      submit: "Add charge",
      run: async (v, k) => {
        const a = parseMoney(v.amount);
        if (a === null)
          throw new Error("Enter an amount of more than zero, with at most two decimals.");
        const r = await applyCharge(businessId, a, v.reason.trim(), k);
        return r.replayed
          ? "That charge was already recorded."
          : `${formatGHS(a)} added to the current bill.`;
      },
    });
    if (isWholesaler) {
      const charged = (detail.assessments ?? []).filter(
        (a) => a.kind === "primary" && a.charged_amount > 0 && a.order_id,
      );
      list.push({
        id: "waive",
        label: "Waive an order's fee",
        description:
          "Credits whatever platform fee is still charged on one order (it needs real billing to be running). Only orders that were charged a fee are listed.",
        fields: [
          {
            key: "order",
            label: "Order",
            type: "select",
            options: charged.map((a) => ({
              value: String(a.order_id),
              label: `${a.order_number} · fee ${formatGHS(a.charged_amount)}`,
            })),
            help: charged.length === 0 ? "No recent order was charged a fee." : undefined,
          },
        ],
        submit: "Waive the fee",
        run: async (v) => {
          if (!v.order) throw new Error("Choose the order.");
          const r = await waiveFee(businessId, v.order, v.reason.trim());
          return `The ${formatGHS(r.amount)} fee on ${r.order_number} was waived.`;
        },
      });
      const exempt = sub.exempt_from_transaction_fees === true;
      list.push({
        id: "exempt",
        label: exempt ? "Remove the fee exemption" : "Exempt from platform fees",
        description: exempt
          ? "From now on orders are charged the platform fee again."
          : "From now on orders are recorded as exempt and charged no platform fee, and use no free orders.",
        fields: [],
        submit: exempt ? "Remove exemption" : "Exempt",
        run: async (v) => {
          await setExemption(businessId, !exempt, v.reason.trim());
          return exempt
            ? "The exemption was removed."
            : "The business is now exempt from platform fees.";
        },
      });
    }
    const paused = sub.billing_paused === true;
    list.push({
      id: "pause",
      label: paused ? "Resume billing" : "Pause billing",
      description: paused
        ? "Billing starts again from now. Orders delivered during the pause stay unbilled."
        : "No new orders are billed and new periods carry no subscription charge until you resume. The bill already running is not changed.",
      fields: [],
      submit: paused ? "Resume" : "Pause",
      run: async (v) => {
        await setPaused(businessId, !paused, v.reason.trim());
        return paused ? "Billing resumed." : "Billing paused.";
      },
    });
    const cancelling = sub.cancel_at_period_end === true;
    list.push({
      id: "cancel",
      label: cancelling
        ? "Withdraw the cancellation"
        : "End the subscription at the end of this period",
      description: cancelling
        ? "The subscription will carry on."
        : "The subscription ends at the end of the current billing period. You can withdraw this until then.",
      fields: [],
      submit: cancelling ? "Withdraw" : "Schedule the end",
      destructive: !cancelling,
      run: async (v) => {
        const end = await setCancellation(businessId, !cancelling, v.reason.trim());
        return cancelling
          ? "The cancellation was withdrawn."
          : `The subscription ends ${end ? dateText(end) : "at the end of the period"}.`;
      },
    });
    const fieldsFor = isWholesaler
      ? OVERRIDE_FIELDS
      : OVERRIDE_FIELDS.filter((f) => f.key === "subscription_amount");
    list.push({
      id: "pricing",
      label: "Set custom pricing",
      description:
        "These replace the plan's figures for this business from the date chosen (now if left empty). Leave a box empty to use the plan's value; type none to remove a limit. Orders already billed keep the terms they were billed under.",
      fields: [
        ...fieldsFor.map((f) => ({
          key: f.key,
          label: f.label,
          type: "text" as const,
          initial:
            overrides[f.key] === undefined
              ? ""
              : overrides[f.key] === null
                ? "none"
                : String(overrides[f.key]),
        })),
        { key: "from", label: "Starts on (optional)", type: "date" },
      ],
      submit: "Save pricing",
      run: async (v) => {
        const { overrides: o, error } = overridesFromForm(v);
        if (error) throw new Error(error);
        const from = v.from ? dateFromInput(v.from) : null;
        await setCustomTerms(businessId, o, from, v.reason.trim());
        const lines = describeOverrides(o);
        return lines.length
          ? `Custom pricing saved: ${lines.join("; ")}.`
          : "Custom pricing removed: the plan's own terms apply.";
      },
    });
    const planOptions = plans
      .filter(
        (p) =>
          p.business_type === detail.business.type &&
          p.active &&
          p.billing_plan_versions.some((v) => v.status === "published"),
      )
      .map((p) => ({ value: p.code, label: `${p.name} (${p.code})` }));
    list.push({
      id: "plan",
      label: "Change the plan",
      description:
        "Moves the business to another plan, or to the newest version of its own. By default from the start of its next billing period, so the bill already running is not re-priced.",
      fields: [
        { key: "plan", label: "Plan", type: "select", options: planOptions },
        { key: "from", label: "Starts on (optional, default: next period)", type: "date" },
        { key: "keep", label: "Keep the custom pricing", type: "checkbox", initial: "true" },
      ],
      submit: "Change plan",
      run: async (v) => {
        if (!v.plan) throw new Error("Choose the plan.");
        const from = v.from ? dateFromInput(v.from) : null;
        const r = await changePlan(businessId, v.plan, from, v.keep === "true", v.reason.trim());
        return `Plan change saved: from ${dateText(r.effective_from)}.`;
      },
    });
    list.push({
      id: "temporary",
      label: "Add a temporary change",
      description:
        "A discount, a lower fee or a fee-free spell between two dates. It stops by itself; nothing needs to be put back. Leave a box empty for no change to that figure.",
      fields: [
        ...fieldsFor.map((f) => ({ key: f.key, label: f.label, type: "text" as const })),
        ...(isWholesaler
          ? [
              {
                key: "waiver",
                label: "No platform fee during this time",
                type: "checkbox" as const,
              },
            ]
          : []),
        { key: "from", label: "Starts on (optional, default now)", type: "date" as const },
        { key: "to", label: "Ends on", type: "date" as const, initial: todayPlus(30) },
      ],
      submit: "Add temporary change",
      run: async (v) => {
        const { overrides: o, error } = overridesFromForm(v);
        if (error) throw new Error(error);
        const all: Record<string, number | boolean | null> = { ...o };
        if (v.waiver === "true") all.exempt_from_transaction_fees = true;
        if (Object.keys(all).length === 0) throw new Error("Say what changes for the period.");
        const to = dateFromInput(v.to);
        if (!to) throw new Error("Choose the end date.");
        await addTemporaryTerms(
          businessId,
          all,
          v.from ? dateFromInput(v.from) : null,
          to,
          v.reason.trim(),
        );
        return "Temporary change added.";
      },
    });
    const type = detail.business.type;
    const applicable = promos.filter((p) => p.business_type === type && p.status === "running");
    list.push({
      id: "promotion",
      label: "Apply a promotion",
      description:
        "Gives the business a promotion's benefits, once. Only promotions that are running for this kind of business are listed.",
      fields: [
        {
          key: "code",
          label: "Promotion",
          type: "select",
          options: applicable.map((p) => ({
            value: p.code,
            label: `${p.code} · ${describeBenefits(p.benefits).join(", ")}`,
          })),
          help:
            applicable.length === 0
              ? "No promotion is running for this kind of business."
              : undefined,
        },
      ],
      submit: "Apply promotion",
      run: async (v) => {
        if (!v.code) throw new Error("Choose the promotion.");
        await applyPromotion(businessId, v.code, v.reason.trim());
        return "Promotion applied.";
      },
    });
    const status = String(sub.status ?? "");
    if (
      platformMode === "active" &&
      !sub.activated_at &&
      status !== "cancelled" &&
      sub.billing_mode !== "disabled"
    ) {
      list.push({
        id: "golive",
        label: "Put this business live",
        description:
          "Starts its real billing. Its first real bill starts at that moment, its free trial restarts from it, and no earlier order is ever charged. Leave the date empty to start now (or choose a day up to 90 days ahead).",
        fields: [{ key: "from", label: "Starts on (optional)", type: "date" }],
        submit: "Go live",
        run: async (v) => {
          const r = await goLiveBusiness(
            businessId,
            v.from ? dateFromInput(v.from) : null,
            v.reason.trim(),
          );
          return `Live from ${dateText(r.activated_at)}${r.trial_end ? `; free trial to ${dateText(r.trial_end)}` : ""}.`;
        },
      });
    }
    if (["past_due", "grace_period", "suspended"].includes(status)) {
      list.push({
        id: "grace",
        label: "Extend the grace period",
        description:
          "Gives a business with an overdue invoice more time (for example a promise to pay). Until that date its account is in its grace period instead of suspended.",
        fields: [
          { key: "until", label: "Grace lasts until", type: "date", initial: todayPlus(14) },
        ],
        submit: "Extend grace",
        run: async (v) => {
          const d = dateFromInput(v.until);
          if (!d) throw new Error("Choose the date.");
          const r = await extendGrace(businessId, d, v.reason.trim());
          return `Grace extended to ${dateText(r.until)}.`;
        },
      });
    }
    return list;
  }, [
    detail,
    plans,
    promos,
    platformMode,
    sub.activated_at,
    sub.status,
    sub.billing_mode,
    businessId,
    isWholesaler,
    sub.trial_end,
    sub.exempt_from_transaction_fees,
    sub.billing_paused,
    sub.cancel_at_period_end,
  ]);

  // running now or still to come: not ended early and not yet over
  const windows = (detail.windows ?? []).filter(
    (w) => !w.ended_early_at && new Date(w.ends_at).getTime() > Date.now(),
  );

  return (
    <section className="space-y-3" data-testid="billing-controls">
      <h4 className="font-semibold">Actions</h4>
      <p className="text-xs text-muted-foreground">
        Every action needs a reason and is kept in the audit trail. The database refuses anything
        that is not allowed.
      </p>
      <div className="flex flex-wrap gap-2">
        {actions.map((a) => (
          <Button
            key={a.id}
            variant="outline"
            size="sm"
            onClick={() => setOpen(a)}
            data-testid={`action-${a.id}`}
          >
            {a.label}
          </Button>
        ))}
      </div>
      {windows.length > 0 && (
        <Card className="space-y-1 p-3" data-testid="temporary-changes">
          <div className="font-medium">Temporary changes</div>
          {windows.map((w) => (
            <div key={w.id} className="flex flex-wrap items-center justify-between gap-2 text-sm">
              <span>
                {describeOverrides(w.overrides).join("; ")} · {dateText(w.starts_at)} to{" "}
                {dateText(w.ends_at)}
                {w.promotion_code ? ` · promotion ${w.promotion_code}` : ""}
              </span>
              <Button variant="ghost" size="sm" onClick={() => setEnding(w.id)}>
                End now
              </Button>
            </div>
          ))}
        </Card>
      )}
      <ActionDialog
        action={open}
        onClose={() => setOpen(null)}
        onDone={() => {
          setOpen(null);
          onChanged();
        }}
      />
      <EndWindowDialog
        windowId={ending}
        onClose={() => setEnding(null)}
        onDone={() => {
          setEnding(null);
          onChanged();
        }}
      />
    </section>
  );
}

function ActionDialog({
  action,
  onClose,
  onDone,
}: {
  action: Action | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [values, setValues] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [requestKey, setRequestKey] = useState(() => newKey());
  useEffect(() => {
    if (!action) return;
    const init: Record<string, string> = { reason: "" };
    for (const f of action.fields) init[f.key] = f.initial ?? "";
    setValues(init);
    setError(null);
    setRequestKey(newKey());
  }, [action]);
  if (!action) return null;
  const set = (k: string, v: string) => setValues((x) => ({ ...x, [k]: v }));

  const submit = async () => {
    const problem = reasonError(values.reason ?? "");
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      toast.success(await action.run(values, requestKey));
      onDone();
    } catch (e) {
      setError(e instanceof Error ? e.message : "That could not be done.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{action.label}</DialogTitle>
          <DialogDescription>{action.description}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          {action.fields.map((f) => (
            <div key={f.key} className="grid gap-1">
              {f.type === "checkbox" ? (
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={values[f.key] === "true"}
                    onChange={(e) => set(f.key, e.target.checked ? "true" : "false")}
                  />
                  {f.label}
                </label>
              ) : (
                <>
                  <Label htmlFor={`act-${f.key}`}>{f.label}</Label>
                  {f.type === "select" ? (
                    <Select value={values[f.key] ?? ""} onValueChange={(v) => set(f.key, v)}>
                      <SelectTrigger id={`act-${f.key}`}>
                        <SelectValue placeholder="Choose…" />
                      </SelectTrigger>
                      <SelectContent>
                        {(f.options ?? []).map((o) => (
                          <SelectItem key={o.value} value={o.value}>
                            {o.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  ) : (
                    <Input
                      id={`act-${f.key}`}
                      type={f.type === "date" ? "date" : "text"}
                      value={values[f.key] ?? ""}
                      onChange={(e) => set(f.key, e.target.value)}
                    />
                  )}
                </>
              )}
              {f.help && <p className="text-xs text-muted-foreground">{f.help}</p>}
            </div>
          ))}
          <div className="grid gap-1">
            <Label htmlFor="act-reason">Reason (kept in the audit trail)</Label>
            <Textarea
              id="act-reason"
              rows={2}
              value={values.reason ?? ""}
              onChange={(e) => set("reason", e.target.value)}
            />
          </div>
          {error && (
            <p className="text-sm text-destructive" role="alert" data-testid="action-error">
              {error}
            </p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button
            variant={action.destructive ? "destructive" : "default"}
            onClick={() => void submit()}
            disabled={busy}
            data-testid="action-submit"
          >
            {busy ? "Working…" : action.submit}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function EndWindowDialog({
  windowId,
  onClose,
  onDone,
}: {
  windowId: string | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setReason("");
    setError(null);
  }, [windowId]);
  if (!windowId) return null;
  const submit = async () => {
    const problem = reasonError(reason);
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    try {
      await endTemporaryTerms(windowId, reason.trim());
      toast.success("The temporary change was ended.");
      onDone();
    } catch (e) {
      setError(e instanceof Error ? e.message : "That could not be done.");
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog open onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>End this temporary change now?</DialogTitle>
          <DialogDescription>
            From now on the business is billed on its normal terms. Orders already billed are not
            changed.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-1">
          <Label htmlFor="end-reason">Reason (kept in the audit trail)</Label>
          <Textarea
            id="end-reason"
            rows={2}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </div>
        {error && (
          <p className="text-sm text-destructive" role="alert">
            {error}
          </p>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Keep it
          </Button>
          <Button variant="destructive" onClick={() => void submit()} disabled={busy}>
            {busy ? "Ending…" : "End now"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
