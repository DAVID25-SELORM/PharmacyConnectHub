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
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

export type ScheduleLine = {
  pharmacy_id: string;
  pharmacy_name: string;
  starts_on?: string | null;
  scheduled_credit_limit_ghs?: number | null;
  scheduled_payment_terms_days?: number | null;
  scheduled_effective_date?: string | null;
  scheduled_note?: string | null;
};

/**
 * Shows what is scheduled on a credit line (a line that has not started yet, or a change to a
 * running line) and lets an owner or manager cancel it, with a reason. The database enforces every
 * rule and audits the change.
 */
export function CreditScheduleControls({
  wholesalerId,
  line,
  onChanged,
}: {
  wholesalerId: string;
  line: ScheduleLine;
  onChanged: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);

  const notStarted = line.starts_on != null;
  const hasChange = line.scheduled_effective_date != null;
  if (!notStarted && !hasChange) return null;

  const reasonOk = reason.trim().length >= 5;
  const close = () => {
    setOpen(false);
    setReason("");
  };

  const cancel = async () => {
    setSaving(true);
    const { error } = await rpc("cancel_scheduled_credit_terms", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: line.pharmacy_id,
      p_reason: reason.trim(),
    });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't cancel this.");
    toast.success(notStarted ? "Credit line cancelled." : "Scheduled change cancelled.");
    close();
    onChanged();
  };

  return (
    <div className="w-full border-t border-border pt-2 text-xs">
      <div className="flex flex-wrap items-center justify-between gap-2">
        {notStarted ? (
          <span>
            <span className="font-medium">Not started:</span> this credit line begins on{" "}
            {formatReportDate(line.starts_on)}. The pharmacy can&apos;t use credit before then.
          </span>
        ) : (
          <span>
            <span className="font-medium">Scheduled change:</span>{" "}
            {formatGHS(line.scheduled_credit_limit_ghs ?? 0)} limit,{" "}
            {line.scheduled_payment_terms_days}-day terms from{" "}
            {formatReportDate(line.scheduled_effective_date)}. Today&apos;s terms stay in force
            until then.
            {line.scheduled_note ? ` · ${line.scheduled_note}` : ""}
          </span>
        )}
        <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
          {notStarted ? "Cancel this line" : "Cancel scheduled change"}
        </Button>
      </div>

      <Dialog open={open} onOpenChange={(next) => !next && close()}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {notStarted ? "Cancel the scheduled credit line" : "Cancel the scheduled change"}
            </DialogTitle>
            <DialogDescription>
              {notStarted
                ? `${line.pharmacy_name}'s credit line will be closed before it starts. Recorded with your reason.`
                : `${line.pharmacy_name} keeps today's terms. The scheduled change will not take effect. Recorded with your reason.`}
            </DialogDescription>
          </DialogHeader>
          <label className="block text-sm">
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
          <DialogFooter>
            <Button variant="outline" onClick={close} disabled={saving}>
              Keep it
            </Button>
            <Button onClick={() => void cancel()} disabled={saving || !reasonOk}>
              {saving ? "Saving…" : "Cancel it"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
