import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import { pickSummary, type OrderPickLine } from "@/lib/batches";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

/** FEFO pick suggestions (earliest expiry first) and recorded batches for one order. Hidden when no batches exist. */
export function PickPanel({
  orderId,
  status,
  canEdit,
}: {
  orderId: string;
  status: string;
  canEdit: boolean;
}) {
  const [lines, setLines] = useState<OrderPickLine[] | null>(null);
  const [confirming, setConfirming] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await rpc("suggest_order_picks", { p_order_id: orderId });
    setLines(error || !Array.isArray(data) ? [] : (data as OrderPickLine[]));
  }, [orderId]);

  useEffect(() => {
    void load();
  }, [load]);

  const confirm = async () => {
    setConfirming(true);
    const { data, error } = await rpc("confirm_order_picks", { p_order_id: orderId });
    setConfirming(false);
    if (error) return toast.error(error.message || "We couldn't confirm the batches.");
    const notBatched = Number(data?.units_not_batched ?? 0);
    toast.success(
      notBatched > 0
        ? `Batches recorded. ${notBatched} unit(s) come from stock that isn't batched.`
        : "Batches recorded for this order.",
    );
    void load();
  };

  if (!lines) return null;
  const hasAnyBatch = lines.some((line) => line.picks.length > 0 || line.allocated);
  if (!hasAnyBatch) return null;

  const allAllocated = lines.every((line) => line.allocated || line.quantity_needed === 0);
  const editable = canEdit && (status === "accepted" || status === "packed");

  return (
    <section className="mt-4 rounded-xl border border-border p-3 text-sm" aria-label="Batches">
      <h4 className="font-semibold">Batches (earliest expiry first)</h4>
      <ul className="mt-2 space-y-1">
        {lines.map((line) => (
          <li key={line.order_item_id}>
            <span className="font-medium">{line.product_name}</span>
            <span className="text-muted-foreground"> · need {line.quantity_needed}: </span>
            {pickSummary(line)}
            {line.shortfall > 0 && (
              <span className="text-warning"> · {line.shortfall} unit(s) not batched</span>
            )}
            {line.allocated && <span className="text-muted-foreground"> · recorded</span>}
          </li>
        ))}
      </ul>
      {editable && (
        <Button
          className="mt-3"
          size="sm"
          variant="outline"
          disabled={confirming}
          onClick={() => void confirm()}
        >
          {confirming ? "Recording..." : allAllocated ? "Re-allocate batches" : "Confirm batches"}
        </Button>
      )}
    </section>
  );
}
