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
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import {
  CHANGEABLE_SETTLEMENT_METHODS,
  SETTLEMENT_LABELS,
  type SettlementMethod,
} from "@/lib/settlement";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type SettlementTarget = {
  orderId: string;
  orderNumber: string;
  current: SettlementMethod;
};

/**
 * Changes how an unpaid, non-credit order will be paid. The method is only an intention: this never
 * records a payment. The database repeats every rule (role, unpaid, not credit, not delivered or
 * cancelled, reason) and audits the change; this dialog relays its message if it refuses.
 */
export function SettlementChangeDialog({
  target,
  onClose,
  onChanged,
}: {
  target: SettlementTarget | null;
  onClose: () => void;
  onChanged: () => void | Promise<void>;
}) {
  const [next, setNext] = useState<SettlementMethod | "">("");
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);

  const close = () => {
    setNext("");
    setReason("");
    onClose();
  };

  const reasonOk = reason.trim().length >= 5;
  const options = CHANGEABLE_SETTLEMENT_METHODS.filter((method) => method !== target?.current);

  const submit = async () => {
    if (!target || !next || !reasonOk) return;
    setSaving(true);
    const { error } = await db.rpc("change_order_settlement_method", {
      p_order_id: target.orderId,
      p_new_method: next,
      p_reason: reason.trim(),
    });
    setSaving(false);
    if (error) {
      toast.error(error.message || "Could not change the payment method.");
      return;
    }
    toast.success(
      `${target.orderNumber} will be paid by ${SETTLEMENT_LABELS[next].toLowerCase()}.`,
    );
    await onChanged();
    close();
  };

  return (
    <Dialog open={target !== null} onOpenChange={(open) => !open && close()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Change payment method</DialogTitle>
          <DialogDescription>
            {target
              ? `${target.orderNumber} is currently set to ${SETTLEMENT_LABELS[target.current].toLowerCase()}. This only changes how you intend to pay; the order stays unpaid until a payment is recorded.`
              : ""}
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="settlement-next">New payment method</Label>
            <Select value={next} onValueChange={(value) => setNext(value as SettlementMethod)}>
              <SelectTrigger id="settlement-next">
                <SelectValue placeholder="Choose a payment method" />
              </SelectTrigger>
              <SelectContent>
                {options.map((method) => (
                  <SelectItem key={method} value={method}>
                    {SETTLEMENT_LABELS[method]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="settlement-reason">Reason (required)</Label>
            <Textarea
              id="settlement-reason"
              value={reason}
              maxLength={500}
              rows={3}
              placeholder="Why is the payment method changing?"
              onChange={(event) => setReason(event.target.value)}
            />
            {reason.length > 0 && !reasonOk && (
              <p className="text-xs text-destructive">Enter at least 5 characters.</p>
            )}
          </div>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={close} disabled={saving}>
            Cancel
          </Button>
          <Button
            type="button"
            onClick={() => void submit()}
            disabled={!next || !reasonOk || saving}
          >
            {saving ? "Saving…" : "Change payment method"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
