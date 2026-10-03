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
  CHECKOUT_CATEGORIES,
  purchaseCategoryLabel,
  purchaseCategoryLabels,
  type ItemPurchaseCategory,
  type PurchaseCategory,
} from "@/lib/purchase-category";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type ClassificationTarget = {
  itemId: string;
  productName: string;
  current: PurchaseCategory | null | undefined;
  orderNumber: string;
};

/**
 * Changing the classification of a placed order changes NHIS vs Cash reporting, so it needs a
 * reason and is recorded in the audit log. The database repeats every check (role, reason, order
 * state); this dialog only collects the input and relays the database's message if it refuses.
 */
export function ClassificationChangeDialog({
  target,
  onClose,
  onChanged,
}: {
  target: ClassificationTarget | null;
  onClose: () => void;
  onChanged: () => void | Promise<void>;
}) {
  const [next, setNext] = useState<ItemPurchaseCategory | "">("");
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);

  const close = () => {
    setNext("");
    setReason("");
    onClose();
  };

  const reasonOk = reason.trim().length >= 5;
  const options = CHECKOUT_CATEGORIES.filter((key) => key !== target?.current);

  const submit = async () => {
    if (!target || !next || !reasonOk) return;
    setSaving(true);
    const { error } = await db.rpc("change_order_item_classification", {
      p_order_item_id: target.itemId,
      p_new_classification: next,
      p_reason: reason.trim(),
    });
    setSaving(false);
    if (error) {
      toast.error(error.message || "Could not change the classification.");
      return;
    }
    toast.success(`${target.productName} is now ${purchaseCategoryLabels[next]}.`);
    await onChanged();
    close();
  };

  return (
    <Dialog open={target !== null} onOpenChange={(open) => !open && close()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Change purchase classification</DialogTitle>
          <DialogDescription>
            {target
              ? `${target.productName} on ${target.orderNumber} is currently ${purchaseCategoryLabel(target.current)}. This changes your NHIS and Cash purchase reports, so the change is recorded with your reason.`
              : ""}
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="classification-next">New classification</Label>
            <Select value={next} onValueChange={(value) => setNext(value as ItemPurchaseCategory)}>
              <SelectTrigger id="classification-next">
                <SelectValue placeholder="Choose NHIS or Cash" />
              </SelectTrigger>
              <SelectContent>
                {options.map((key) => (
                  <SelectItem key={key} value={key}>
                    {purchaseCategoryLabels[key]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="classification-reason">Reason (required)</Label>
            <Textarea
              id="classification-reason"
              value={reason}
              maxLength={500}
              rows={3}
              placeholder="Why is the classification changing?"
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
            {saving ? "Saving…" : "Change classification"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
