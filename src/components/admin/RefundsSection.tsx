import { useState } from "react";
import { Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
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
import { Textarea } from "@/components/ui/textarea";
import { formatGHS, timeAgo } from "@/lib/format";
import {
  REFUND_REASON_LABELS,
  REFUND_STATUS_LABELS,
  describeRefundAction,
  refundAction,
  refundActionsFor,
  type PaymentRefund,
  type RefundAction,
} from "@/lib/payments-admin";

const statusClass = (status: string) =>
  status === "succeeded"
    ? "bg-success/15 text-success border-success/30"
    : status === "failed" || status === "unknown"
      ? "bg-destructive/15 text-destructive border-destructive/30"
      : status === "cancelled"
        ? "bg-muted text-muted-foreground border-border"
        : "bg-warning/15 text-warning-foreground border-warning/30";

const NOTE_HELP: Partial<Record<RefundAction, string>> = {
  confirm_refunded:
    "Check the provider's dashboard first. Say what you found, for example the refund reference. This does not send any money.",
  mark_failed:
    "Check the provider's dashboard first and say what you found (for example: no such refund exists). It can then be retried.",
};

/** The refunds that are open (or recent), and what an administrator may do to each. Nothing is sent without an administrator's approval unless automatic refunds are on. */
export function RefundsSection({
  refunds,
  autoRefunds,
  onChanged,
}: {
  refunds: PaymentRefund[];
  autoRefunds: boolean;
  onChanged: () => Promise<void> | void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [asking, setAsking] = useState<{
    refund: PaymentRefund;
    action: RefundAction;
    label: string;
  } | null>(null);
  const [note, setNote] = useState("");

  const run = async (refund: PaymentRefund, action: RefundAction, text?: string) => {
    setBusy(refund.id);
    try {
      const result = await refundAction(refund.id, action, text);
      toast.info(describeRefundAction(result));
      setAsking(null);
      setNote("");
      await onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not change the refund.");
    } finally {
      setBusy(null);
    }
  };

  return (
    <section aria-labelledby="refunds-heading" className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 id="refunds-heading" className="font-display text-lg font-bold">
          Refunds
        </h2>
        <Badge
          variant="secondary"
          className="border bg-muted text-muted-foreground border-border"
          data-testid="auto-refunds"
        >
          {autoRefunds ? "Automatic refunds on" : "Every refund waits for approval"}
        </Badge>
      </div>
      {refunds.length === 0 ? (
        <Card className="p-4 text-sm text-muted-foreground" data-testid="no-refunds">
          No refunds.
        </Card>
      ) : (
        <Card className="overflow-x-auto p-0">
          <table className="w-full text-sm">
            <thead className="border-b border-border text-left text-xs uppercase tracking-wider text-muted-foreground">
              <tr>
                <th className="px-3 py-2">Requested</th>
                <th className="px-3 py-2">Order</th>
                <th className="px-3 py-2">Why</th>
                <th className="px-3 py-2 text-right">Amount</th>
                <th className="px-3 py-2">Status</th>
                <th className="px-3 py-2">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {refunds.map((refund) => (
                <tr key={refund.id} data-testid="refund">
                  <td className="whitespace-nowrap px-3 py-2">{timeAgo(refund.created_at)}</td>
                  <td className="px-3 py-2">
                    <div className="font-medium">{refund.order_number}</div>
                    <div className="text-xs text-muted-foreground">{refund.pharmacy ?? "—"}</div>
                  </td>
                  <td className="px-3 py-2">
                    {REFUND_REASON_LABELS[refund.reason] ?? refund.reason}
                  </td>
                  <td className="whitespace-nowrap px-3 py-2 text-right">
                    {formatGHS(refund.amount_ghs)}
                  </td>
                  <td className="px-3 py-2">
                    <Badge variant="secondary" className={`border ${statusClass(refund.status)}`}>
                      {REFUND_STATUS_LABELS[refund.status]}
                    </Badge>
                    {refund.failure_reason && (
                      <div className="mt-0.5 max-w-xs text-xs text-muted-foreground">
                        {refund.failure_reason}
                      </div>
                    )}
                    {refund.method === "manual" && refund.status === "succeeded" && (
                      <div className="mt-0.5 text-xs text-muted-foreground">
                        Confirmed by hand{refund.note ? `: ${refund.note}` : ""}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2">
                    <div className="flex flex-wrap gap-1.5">
                      {refundActionsFor(refund.status).map((a) => (
                        <Button
                          key={a.action}
                          size="sm"
                          variant={
                            a.action === "approve" || a.action === "retry" ? "default" : "outline"
                          }
                          disabled={busy === refund.id}
                          onClick={() =>
                            a.needsNote
                              ? (setAsking({ refund, action: a.action, label: a.label }),
                                setNote(""))
                              : void run(refund, a.action)
                          }
                        >
                          {busy === refund.id &&
                          (a.action === "approve" || a.action === "retry") ? (
                            <Loader2 className="mr-1 h-4 w-4 animate-spin" aria-hidden="true" />
                          ) : null}
                          {a.label}
                        </Button>
                      ))}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}

      <Dialog open={asking !== null} onOpenChange={(openState) => !openState && setAsking(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{asking?.label}</DialogTitle>
            <DialogDescription>
              {asking
                ? `${formatGHS(asking.refund.amount_ghs)} for order ${asking.refund.order_number}. ${NOTE_HELP[asking.action] ?? ""}`
                : ""}
            </DialogDescription>
          </DialogHeader>
          <Textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            maxLength={500}
            rows={4}
            aria-label="What you checked"
            placeholder="For example: refunded from the Paystack dashboard, reference RF-123."
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setAsking(null)}>
              Cancel
            </Button>
            <Button
              disabled={busy !== null || note.trim().length < 5}
              onClick={() => asking && void run(asking.refund, asking.action, note.trim())}
            >
              {busy ? "Saving…" : asking?.label}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  );
}
