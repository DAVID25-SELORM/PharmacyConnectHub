import { WholesalerCreditRequests } from "@/components/credit/CreditAccountRequests";
import { useCallback, useEffect, useState } from "react";
import { CreditCard } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { termsLabel, validateCreditForm, type DueBasis } from "@/lib/credit-terms";
import { CreditOverrideControls } from "@/components/wholesaler/CreditOverrideControls";
import { CreditScheduleControls } from "@/components/wholesaler/CreditScheduleControls";
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

type CreditLine = {
  pharmacy_id: string;
  pharmacy_name: string;
  credit_limit_ghs: number;
  payment_terms_days: number;
  due_basis?: DueBasis;
  outstanding_ghs: number;
  available_ghs: number;
  internal_note: string | null;
  updated_at: string;
  status: "active" | "suspended" | "blocked";
  status_reason: string | null;
  status_changed_at: string | null;
  override_max_order_ghs?: number | null;
  override_expires_at?: string | null;
  override_reason?: string | null;
  starts_on?: string | null;
  scheduled_credit_limit_ghs?: number | null;
  scheduled_payment_terms_days?: number | null;
  scheduled_effective_date?: string | null;
  scheduled_note?: string | null;
};

type StatusChange = { line: CreditLine; next: "active" | "suspended" | "blocked" };

const STATUS_LABELS = { active: "Active", suspended: "Suspended", blocked: "Blocked" } as const;

/** Approved credit limits per pharmacy. Settling a credit order still goes through "Confirm payment" once delivered. */
export function CreditTermsCard({ wholesalerId }: { wholesalerId: string }) {
  const [pharmacies, setPharmacies] = useState<Array<{ id: string; name: string }>>([]);
  const [lines, setLines] = useState<CreditLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [dueBasis, setDueBasis] = useState<DueBasis>("order_date");
  const [pharmacyId, setPharmacyId] = useState("");
  const [limit, setLimit] = useState("");
  const [days, setDays] = useState("30");
  const [note, setNote] = useState("");
  const [effectiveDate, setEffectiveDate] = useState("");
  const [saving, setSaving] = useState(false);
  const [statusChange, setStatusChange] = useState<StatusChange | null>(null);
  const [statusReason, setStatusReason] = useState("");
  const [statusSaving, setStatusSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const [{ data: pharmacyData, error: pharmacyError }, { data, error: rpcError }] =
      await Promise.all([
        supabase
          .from("businesses")
          .select("id,name")
          .eq("type", "pharmacy")
          .eq("verification_status", "approved")
          .order("name"),
        rpc("list_wholesaler_credit_terms", { p_wholesaler_id: wholesalerId }),
      ]);
    setPharmacies((pharmacyData as Array<{ id: string; name: string }>) ?? []);
    if (rpcError || pharmacyError) setError(true);
    else setLines(Array.isArray(data) ? (data as CreditLine[]) : []);
    setLoading(false);
  }, [wholesalerId]);

  useEffect(() => {
    void load();
  }, [load]);

  const selectedLine = lines.find((line) => line.pharmacy_id === pharmacyId);

  const selectPharmacy = (id: string) => {
    const line = lines.find((item) => item.pharmacy_id === id);
    setPharmacyId(id);
    setLimit(line ? String(line.credit_limit_ghs) : "");
    setDays(line ? String(line.payment_terms_days) : "30");
    setDueBasis(line?.due_basis ?? "order_date");
    setNote(line?.internal_note ?? "");
    setEffectiveDate("");
  };

  const save = async () => {
    if (saving || loading || error) return;
    if (!pharmacyId) return toast.error("Choose a pharmacy.");
    const parsed = validateCreditForm({ limit, days });
    if (parsed.error) return toast.error(parsed.error);
    // A future date schedules the terms (today's terms stay in force until then); no date applies now.
    const today = new Date().toISOString().slice(0, 10);
    if (effectiveDate && effectiveDate <= today) {
      return toast.error(
        "The effective date must be in the future. Clear it to apply the terms now.",
      );
    }
    setSaving(true);
    const { error: rpcError } = effectiveDate
      ? await rpc("schedule_credit_terms", {
          p_wholesaler_id: wholesalerId,
          p_pharmacy_id: pharmacyId,
          p_credit_limit: parsed.limit,
          p_payment_terms_days: parsed.days,
          p_effective_date: effectiveDate,
          p_note: note.trim() || null,
        })
      : await rpc("set_credit_terms", {
          p_wholesaler_id: wholesalerId,
          p_pharmacy_id: pharmacyId,
          p_credit_limit: parsed.limit,
          p_payment_terms_days: parsed.days,
          p_note: note.trim() || null,
        });
    if (rpcError) {
      setSaving(false);
      return toast.error(rpcError.message || "We couldn't save this credit line.");
    }
    // The payment-clock choice is its own change (audited, applies to new orders), made only when it differs.
    if (dueBasis !== (selectedLine?.due_basis ?? "order_date")) {
      const { error: basisError } = await rpc("set_credit_due_basis", {
        p_wholesaler_id: wholesalerId,
        p_pharmacy_id: pharmacyId,
        p_basis: dueBasis,
      });
      if (basisError) {
        setSaving(false);
        void load();
        return toast.error(
          basisError.message || "The terms were saved, but we couldn't change the payment clock.",
        );
      }
    }
    setSaving(false);
    toast.success(
      effectiveDate
        ? `Credit terms scheduled from ${formatReportDate(effectiveDate)}.`
        : selectedLine
          ? "Credit terms updated."
          : "Pharmacy approved as a credit client.",
    );
    setEffectiveDate("");
    setPharmacyId("");
    setDays("30");
    setLimit("");
    setNote("");
    void load();
  };

  const applyStatus = async () => {
    if (!statusChange || statusReason.trim().length < 5) return;
    setStatusSaving(true);
    const { error: rpcError } = await rpc("set_credit_status", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: statusChange.line.pharmacy_id,
      p_status: statusChange.next,
      p_reason: statusReason.trim(),
    });
    setStatusSaving(false);
    if (rpcError) return toast.error(rpcError.message || "We couldn't change this credit status.");
    toast.success(
      `${statusChange.line.pharmacy_name}: credit ${STATUS_LABELS[statusChange.next].toLowerCase()}.`,
    );
    setStatusChange(null);
    setStatusReason("");
    void load();
  };

  const revoke = async (line: CreditLine) => {
    if (
      !window.confirm(
        `Revoke credit for ${line.pharmacy_name}? They will need another payment method for new orders. Existing invoices remain payable.`,
      )
    )
      return;
    const { error: rpcError } = await rpc("revoke_credit_terms", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: line.pharmacy_id,
    });
    if (rpcError) return toast.error(rpcError.message || "We couldn't revoke this credit line.");
    toast.success("Credit revoked.");
    void load();
  };

  return (
    <div className="space-y-4">
      <WholesalerCreditRequests wholesalerId={wholesalerId} onReviewed={() => void load()} />
      <Card className="p-5">
        <div className="flex items-center gap-2">
          <CreditCard className="h-5 w-5 text-primary" aria-hidden="true" />
          <h2 className="font-display text-xl font-bold">Credit clients</h2>
        </div>
        <p className="mt-1 text-sm text-muted-foreground">
          Choose the pharmacies you want to approve as credit clients. Set a limit and payment terms
          for each pharmacy; approval applies only to orders from your business. Checkout blocks any
          credit order that would push their balance over the limit. Settle a credit order the same
          way as a cash order, by confirming payment once it is delivered.
        </p>

        <div className="mt-4 grid gap-3 md:grid-cols-4">
          <label className="block text-sm md:col-span-2">
            <span className="mb-1 block text-muted-foreground">Pharmacy</span>
            <select
              className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
              value={pharmacyId}
              disabled={loading || error || saving}
              onChange={(event) => selectPharmacy(event.target.value)}
            >
              <option value="">Choose a pharmacy</option>
              {pharmacies.map((pharmacy) => (
                <option key={pharmacy.id} value={pharmacy.id}>
                  {pharmacy.name}
                  {lines.some((line) => line.pharmacy_id === pharmacy.id) ? " (credit client)" : ""}
                </option>
              ))}
            </select>
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Credit limit (GHS)</span>
            <Input
              type="number"
              min={0.01}
              step="0.01"
              value={limit}
              onChange={(event) => setLimit(event.target.value)}
            />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Payment terms (days)</span>
            <Input
              type="number"
              min={1}
              max={365}
              value={days}
              onChange={(event) => setDays(event.target.value)}
            />
          </label>
        </div>
        <label className="mt-3 block text-sm md:max-w-md">
          <span className="mb-1 block text-muted-foreground">Payment clock starts on</span>
          <select
            className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
            value={dueBasis}
            disabled={saving}
            onChange={(event) => setDueBasis(event.target.value as DueBasis)}
          >
            <option value="order_date">The order date</option>
            <option value="delivery_date">The delivery date</option>
          </select>
          <span className="mt-1 block text-xs text-muted-foreground">
            {dueBasis === "delivery_date"
              ? "A new credit order has no due date until it is delivered; then it is due the payment terms after delivery."
              : "A new credit order is due the payment terms after the day it is placed."}{" "}
            This applies to new orders from now on; invoices already issued keep their due dates.
          </span>
        </label>
        <label className="mt-3 block text-sm">
          <span className="mb-1 block text-muted-foreground">Note (optional, internal)</span>
          <Input value={note} maxLength={500} onChange={(event) => setNote(event.target.value)} />
        </label>
        <label className="mt-3 block text-sm">
          <span className="mb-1 block text-muted-foreground">
            Takes effect on (optional) — leave empty to apply now; a future date keeps today's terms
            in force until then
          </span>
          <Input
            type="date"
            value={effectiveDate}
            min={new Date(Date.now() + 86_400_000).toISOString().slice(0, 10)}
            onChange={(event) => setEffectiveDate(event.target.value)}
          />
        </label>
        <Button
          className="mt-4"
          size="sm"
          variant="hero"
          disabled={saving || loading || error || !pharmacyId}
          onClick={() => void save()}
        >
          {saving
            ? "Saving..."
            : effectiveDate
              ? "Schedule credit terms"
              : selectedLine
                ? "Update credit terms"
                : "Approve credit client"}
        </Button>

        <div className="mt-6">
          {loading ? (
            <p className="text-sm text-muted-foreground" role="status">
              Loading...
            </p>
          ) : error ? (
            <p role="alert" className="text-sm">
              We couldn&apos;t load pharmacies or credit terms.{" "}
              <button type="button" className="text-primary underline" onClick={() => void load()}>
                Try again
              </button>
            </p>
          ) : lines.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              You have not approved any pharmacies as credit clients yet.
            </p>
          ) : (
            <ul className="divide-y divide-border rounded-xl border border-border text-sm">
              {lines.map((line) => (
                <li
                  key={line.pharmacy_id}
                  className="flex flex-wrap items-center justify-between gap-3 p-3"
                >
                  <div>
                    <div className="font-medium">{line.pharmacy_name}</div>
                    <div className="text-muted-foreground">
                      {formatGHS(line.outstanding_ghs)} owed of {formatGHS(line.credit_limit_ghs)} ·{" "}
                      {termsLabel(line.payment_terms_days, line.due_basis)} · updated{" "}
                      {formatReportDate(line.updated_at)}
                      {line.internal_note ? ` · ${line.internal_note}` : ""}
                    </div>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-xs">
                      <Badge variant={line.status === "active" ? "secondary" : "destructive"}>
                        {STATUS_LABELS[line.status]}
                      </Badge>
                      <span className="text-muted-foreground">
                        {formatGHS(line.available_ghs)} available
                        {line.status !== "active" && line.status_reason
                          ? ` · ${line.status_reason}`
                          : ""}
                      </span>
                    </div>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => selectPharmacy(line.pharmacy_id)}
                    >
                      Edit terms
                    </Button>
                    {line.status !== "active" && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setStatusChange({ line, next: "active" })}
                      >
                        Reactivate
                      </Button>
                    )}
                    {line.status === "active" && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setStatusChange({ line, next: "suspended" })}
                      >
                        Suspend
                      </Button>
                    )}
                    {line.status !== "blocked" && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setStatusChange({ line, next: "blocked" })}
                      >
                        Block
                      </Button>
                    )}
                    <Button size="sm" variant="outline" onClick={() => void revoke(line)}>
                      Revoke
                    </Button>
                  </div>
                  <CreditScheduleControls
                    wholesalerId={wholesalerId}
                    line={line}
                    onChanged={() => void load()}
                  />
                  <CreditOverrideControls
                    wholesalerId={wholesalerId}
                    line={line}
                    onChanged={() => void load()}
                  />
                </li>
              ))}
            </ul>
          )}
        </div>
        <Dialog
          open={statusChange !== null}
          onOpenChange={(open) => {
            if (!open) {
              setStatusChange(null);
              setStatusReason("");
            }
          }}
        >
          <DialogContent className="sm:max-w-md">
            <DialogHeader>
              <DialogTitle>
                {statusChange?.next === "active"
                  ? "Reactivate credit"
                  : statusChange?.next === "suspended"
                    ? "Suspend credit"
                    : "Block credit"}
              </DialogTitle>
              <DialogDescription>
                {statusChange
                  ? statusChange.next === "active"
                    ? `${statusChange.line.pharmacy_name} will be able to place credit orders again.`
                    : `${statusChange.line.pharmacy_name} won't be able to place new credit orders. Existing invoices stay payable. They are notified with your reason.`
                  : ""}
              </DialogDescription>
            </DialogHeader>
            <label className="block text-sm">
              <span className="mb-1 block text-muted-foreground">Reason (required)</span>
              <Textarea
                value={statusReason}
                maxLength={500}
                rows={3}
                onChange={(event) => setStatusReason(event.target.value)}
              />
            </label>
            {statusReason.length > 0 && statusReason.trim().length < 5 && (
              <p className="text-xs text-destructive">Enter at least 5 characters.</p>
            )}
            <DialogFooter>
              <Button
                variant="outline"
                onClick={() => {
                  setStatusChange(null);
                  setStatusReason("");
                }}
                disabled={statusSaving}
              >
                Cancel
              </Button>
              <Button
                onClick={() => void applyStatus()}
                disabled={statusSaving || statusReason.trim().length < 5}
              >
                {statusSaving ? "Saving…" : "Confirm"}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </Card>
    </div>
  );
}
