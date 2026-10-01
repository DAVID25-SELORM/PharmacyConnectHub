import { useEffect, useState } from "react";
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
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import {
  MOVEMENT_REASON_LABELS,
  validateStockAdjustment,
  type PharmacyInventoryItem,
  type PharmacyInventoryMovementReason,
} from "@/lib/pharmacy-inventory";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

const KIND_OPTIONS: Array<{ value: "receive" | "adjust" | "write_off"; label: string; help: string }> = [
  { value: "receive", label: "Receive stock", help: "New stock coming in (e.g. a delivery from any supplier)." },
  { value: "adjust", label: "Correct a count", help: "Fix the stock number up or down after a physical count." },
  { value: "write_off", label: "Write off", help: "Remove units that are damaged, expired, or otherwise unsellable." },
];

export function AdjustStockDialog({
  item,
  open,
  onOpenChange,
  onAdjusted,
}: {
  item: PharmacyInventoryItem | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onAdjusted: () => void;
}) {
  const [kind, setKind] = useState<"receive" | "adjust" | "write_off">("receive");
  const [quantity, setQuantity] = useState("");
  const [reason, setReason] = useState<PharmacyInventoryMovementReason | "">("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) return;
    setKind("receive");
    setQuantity("");
    setReason("");
    setNote("");
    setError(null);
  }, [open]);

  const submit = async () => {
    if (!item) return;
    const { error: validationError, delta } = validateStockAdjustment({ quantity, kind });
    if (validationError || delta === undefined) {
      setError(validationError);
      return;
    }
    if (kind === "write_off" && -delta > item.stock) {
      setError(`Only ${item.stock} unit(s) are on hand.`);
      return;
    }
    setError(null);
    setSubmitting(true);
    const { error: rpcError } = await rpc("adjust_pharmacy_inventory_stock", {
      p_item_id: item.id,
      p_quantity_delta: delta,
      p_kind: kind,
      p_reason: kind === "write_off" ? reason || "other" : null,
      p_note: note.trim() || null,
    });
    setSubmitting(false);
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    toast.success("Stock updated");
    onOpenChange(false);
    onAdjusted();
  };

  if (!item) return null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Adjust stock: {item.name}</DialogTitle>
          <DialogDescription>Currently {item.stock} unit{item.stock === 1 ? "" : "s"} on hand.</DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label>What happened</Label>
            <select
              className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
              value={kind}
              onChange={(e) => setKind(e.target.value as typeof kind)}
            >
              {KIND_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
            <p className="text-xs text-muted-foreground">{KIND_OPTIONS.find((o) => o.value === kind)?.help}</p>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="adjust-qty">{kind === "write_off" ? "Units to remove" : "Quantity"}</Label>
            <Input
              id="adjust-qty"
              type="number"
              value={quantity}
              onChange={(e) => setQuantity(e.target.value)}
              placeholder={kind === "adjust" ? "Positive to add, negative to subtract" : undefined}
            />
          </div>

          {kind === "write_off" && (
            <div className="space-y-1.5">
              <Label>Reason</Label>
              <select
                className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                value={reason}
                onChange={(e) => setReason(e.target.value as PharmacyInventoryMovementReason)}
              >
                <option value="">Select a reason</option>
                {(Object.keys(MOVEMENT_REASON_LABELS) as PharmacyInventoryMovementReason[]).map((r) => (
                  <option key={r} value={r}>
                    {MOVEMENT_REASON_LABELS[r]}
                  </option>
                ))}
              </select>
            </div>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="adjust-note">Note (optional)</Label>
            <Textarea id="adjust-note" rows={2} value={note} onChange={(e) => setNote(e.target.value)} />
          </div>

          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={submitting}>
            Cancel
          </Button>
          <Button type="button" onClick={() => void submit()} disabled={submitting}>
            {submitting ? "Saving..." : "Save"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
