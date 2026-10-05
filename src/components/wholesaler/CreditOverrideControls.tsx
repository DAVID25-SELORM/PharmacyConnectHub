import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
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
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

export type OverrideLine = {
  pharmacy_id: string;
  pharmacy_name: string;
  available_ghs: number;
  status: "active" | "suspended" | "blocked";
  override_max_order_ghs?: number | null;
  override_expires_at?: string | null;
  override_reason?: string | null;
};

/**
 * A one-time approval for a single credit order above this pharmacy's limit. It is consumed by the
 * first order that needs it, expires, never overrides a suspended or blocked line, and does not
 * raise the limit. The database enforces every rule; this only collects the input.
 */
export function CreditOverrideControls({
  wholesalerId,
  line,
  onChanged,
}: {
  wholesalerId: string;
  line: OverrideLine;
  onChanged: () => void;
}) {
  const [mode, setMode] = useState<"grant" | "revoke" | null>(null);
  const [amount, setAmount] = useState("");
  const [days, setDays] = useState("7");
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);

  // != null (not !== null): before the database migration is applied these fields are absent, not null.
  const hasOverride = line.override_max_order_ghs != null && line.override_expires_at != null;
  // The credit list only carries these columns once the override migration has been applied (they are
  // null when there is no override). Until then the feature is simply not offered.
  const supported = line.override_max_order_ghs !== undefined;
  const close = () => {
    setMode(null);
    setAmount("");
    setDays("7");
    setReason("");
  };

  const amountNumber = Number(amount);
  const daysNumber = Number(days);
  const reasonOk = reason.trim().length >= 5;
  const grantValid =
    Number.isFinite(amountNumber) &&
    amountNumber > Number(line.available_ghs) &&
    amountNumber <= 10_000_000 &&
    Number.isInteger(daysNumber) &&
    daysNumber >= 1 &&
    daysNumber <= 30 &&
    reasonOk;

  const submit = async () => {
    setSaving(true);
    const { error } =
      mode === "grant"
        ? await rpc("grant_credit_override", {
            p_wholesaler_id: wholesalerId,
            p_pharmacy_id: line.pharmacy_id,
            p_max_order_ghs: amountNumber,
            p_valid_days: daysNumber,
            p_reason: reason.trim(),
          })
        : await rpc("revoke_credit_override", {
            p_wholesaler_id: wholesalerId,
            p_pharmacy_id: line.pharmacy_id,
            p_reason: reason.trim(),
          });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't save this override.");
    toast.success(
      mode === "grant"
        ? `One-time override approved for ${line.pharmacy_name}.`
        : `Override revoked for ${line.pharmacy_name}.`,
    );
    close();
    onChanged();
  };

  if (!supported) return null;

  return (
    <div className="w-full border-t border-border pt-2 text-xs">
      {hasOverride ? (
        <div className="flex flex-wrap items-center justify-between gap-2">
          <span>
            <span className="font-medium">One-time override:</span> one order up to{" "}
            {formatGHS(line.override_max_order_ghs!)} until{" "}
            {formatReportDate(line.override_expires_at)}
            {line.override_reason ? ` · ${line.override_reason}` : ""}
          </span>
          <Button size="sm" variant="outline" onClick={() => setMode("revoke")}>
            Revoke override
          </Button>
        </div>
      ) : (
        line.status === "active" && (
          <Button size="sm" variant="ghost" onClick={() => setMode("grant")}>
            Approve a one-time override
          </Button>
        )
      )}

      <Dialog open={mode !== null} onOpenChange={(open) => !open && close()}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {mode === "grant" ? "Approve a one-time override" : "Revoke the override"}
            </DialogTitle>
            <DialogDescription>
              {mode === "grant"
                ? `${line.pharmacy_name} has ${formatGHS(line.available_ghs)} of credit left. This lets them place ONE credit order above that, up to the amount you set. It is used once, expires, and does not change their limit. It is recorded with your reason.`
                : `${line.pharmacy_name} will no longer be able to place the over-limit order. Recorded with your reason.`}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3 text-sm">
            {mode === "grant" && (
              <>
                <label className="block">
                  <span className="mb-1 block text-muted-foreground">
                    Largest order covered (GHS) — above {formatGHS(line.available_ghs)}
                  </span>
                  <Input
                    type="number"
                    min={0.01}
                    step="0.01"
                    value={amount}
                    onChange={(event) => setAmount(event.target.value)}
                  />
                </label>
                {amount !== "" && !(amountNumber > Number(line.available_ghs)) && (
                  <p className="text-xs text-destructive">
                    No override is needed for an amount that already fits the remaining credit.
                  </p>
                )}
                <label className="block">
                  <span className="mb-1 block text-muted-foreground">Valid for (days, 1–30)</span>
                  <Input
                    type="number"
                    min={1}
                    max={30}
                    value={days}
                    onChange={(event) => setDays(event.target.value)}
                  />
                </label>
              </>
            )}
            <label className="block">
              <span className="mb-1 block text-muted-foreground">Reason (required)</span>
              <Textarea
                value={reason}
                maxLength={500}
                rows={3}
                onChange={(event) => setReason(event.target.value)}
              />
            </label>
            {reason.length > 0 && !reasonOk && (
              <p className="text-xs text-destructive">Enter at least 5 characters.</p>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={close} disabled={saving}>
              Cancel
            </Button>
            <Button
              onClick={() => void submit()}
              disabled={saving || (mode === "grant" ? !grantValid : !reasonOk)}
            >
              {saving ? "Saving…" : mode === "grant" ? "Approve override" : "Revoke override"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
