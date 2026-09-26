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
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { RETURN_REASONS, validateReturnSelection } from "@/lib/returns";

type Returnable = {
  order_item_id: string;
  product_name: string;
  quantity_ordered: number;
  quantity_claimed: number;
  quantity_available: number;
  unit_price_ghs: number;
};

/** Pharmacy: pick lines and quantities from a delivered order, give a reason, send the request. */
export function RequestReturnDialog({
  order,
  onClose,
  onDone,
}: {
  order: { id: string; order_number: string } | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [lines, setLines] = useState<Returnable[]>([]);
  const [quantities, setQuantities] = useState<Record<string, string>>({});
  const [reason, setReason] = useState("");
  const [note, setNote] = useState("");
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!order) return;
    let cancelled = false;
    setLines([]);
    setQuantities({});
    setReason("");
    setNote("");
    setLoadError(null);
    setLoading(true);
    void (supabase as any)
      .rpc("get_returnable_items", { p_order_id: order.id })
      .then(
        ({ data, error }: { data: Returnable[] | null; error: { message?: string } | null }) => {
          if (cancelled) return;
          if (error) setLoadError(error.message ?? "We couldn't load this order.");
          else setLines(Array.isArray(data) ? data : []);
          setLoading(false);
        },
      );
    return () => {
      cancelled = true;
    };
  }, [order]);

  const submit = async () => {
    if (!order) return;
    const selected = lines.map((line) => ({
      quantity: Number(quantities[line.order_item_id] || 0),
      available: line.quantity_available,
      name: line.product_name,
    }));
    const problem = validateReturnSelection(selected) ?? (reason ? null : "Choose a reason.");
    if (problem) return toast.error(problem);

    setSaving(true);
    const { error } = await (supabase as any).rpc("request_order_return", {
      p_order_id: order.id,
      p_reason: reason,
      p_note: note.trim() || null,
      p_items: lines
        .filter((line) => Number(quantities[line.order_item_id] || 0) > 0)
        .map((line) => ({
          order_item_id: line.order_item_id,
          quantity: Number(quantities[line.order_item_id]),
        })),
    });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't send the return request.");
    toast.success("Return requested. The supplier will review it.");
    onDone();
    onClose();
  };

  return (
    <Dialog open={Boolean(order)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Request a return{order ? ` · ${order.order_number}` : ""}</DialogTitle>
          <DialogDescription>
            Choose what you want to send back. Returns can be requested within 30 days of delivery.
          </DialogDescription>
        </DialogHeader>

        {loading ? (
          <p className="text-sm text-muted-foreground" role="status">
            Loading items...
          </p>
        ) : loadError ? (
          <p role="alert" className="text-sm">
            {loadError}
          </p>
        ) : (
          <>
            <ul className="divide-y divide-border rounded-xl border border-border">
              {lines.map((line) => (
                <li
                  key={line.order_item_id}
                  className="flex items-center justify-between gap-3 p-3 text-sm"
                >
                  <div>
                    <div className="font-medium">{line.product_name}</div>
                    <div className="text-xs text-muted-foreground">
                      Ordered {line.quantity_ordered} at {formatGHS(line.unit_price_ghs)}
                      {line.quantity_claimed > 0 &&
                        ` · ${line.quantity_claimed} already in returns`}
                    </div>
                  </div>
                  <label className="flex items-center gap-2">
                    <span className="sr-only">Quantity to return for {line.product_name}</span>
                    <Input
                      type="number"
                      min={0}
                      max={line.quantity_available}
                      className="w-24"
                      disabled={line.quantity_available === 0}
                      placeholder={
                        line.quantity_available === 0 ? "None left" : `0-${line.quantity_available}`
                      }
                      value={quantities[line.order_item_id] ?? ""}
                      onChange={(event) =>
                        setQuantities((current) => ({
                          ...current,
                          [line.order_item_id]: event.target.value,
                        }))
                      }
                    />
                  </label>
                </li>
              ))}
            </ul>

            <label className="block text-sm">
              <span className="mb-1 block text-muted-foreground">Reason</span>
              <select
                className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
                value={reason}
                onChange={(event) => setReason(event.target.value)}
              >
                <option value="">Choose a reason</option>
                {RETURN_REASONS.map((item) => (
                  <option key={item.value} value={item.value}>
                    {item.label}
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-sm">
              <span className="mb-1 block text-muted-foreground">
                Details for the supplier (optional)
              </span>
              <Textarea
                value={note}
                maxLength={1000}
                onChange={(event) => setNote(event.target.value)}
              />
            </label>
          </>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            variant="hero"
            onClick={() => void submit()}
            disabled={saving || loading || Boolean(loadError)}
          >
            {saving ? "Sending..." : "Request return"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
