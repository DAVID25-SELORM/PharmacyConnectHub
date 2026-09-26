import { useCallback, useEffect, useState } from "react";
import { Truck } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { describeTerms, validateTermsForm, type OrderTerms } from "@/lib/order-terms";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

/** A wholesaler's minimum order and delivery fee. Enforced by the database when pharmacies check out. */
export function OrderTermsCard({ wholesalerId }: { wholesalerId: string }) {
  const [terms, setTerms] = useState<OrderTerms | undefined>();
  const [min, setMin] = useState("");
  const [fee, setFee] = useState("");
  const [freeFrom, setFreeFrom] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await rpc("list_order_terms", {
      p_wholesaler_ids: [wholesalerId],
    });
    if (rpcError) {
      setError(true);
      setLoading(false);
      return;
    }
    const row = (Array.isArray(data) ? data[0] : undefined) as OrderTerms | undefined;
    setTerms(row);
    setMin(row && Number(row.min_order_value_ghs) > 0 ? String(row.min_order_value_ghs) : "");
    setFee(row && Number(row.delivery_fee_ghs) > 0 ? String(row.delivery_fee_ghs) : "");
    setFreeFrom(
      row?.free_delivery_threshold_ghs != null ? String(row.free_delivery_threshold_ghs) : "",
    );
    setLoading(false);
  }, [wholesalerId]);

  useEffect(() => {
    void load();
  }, [load]);

  const save = async () => {
    const parsed = validateTermsForm({ min, fee, freeFrom });
    if (parsed.error) return toast.error(parsed.error);
    setSaving(true);
    const { error: rpcError } = await rpc("set_order_terms", {
      p_wholesaler_id: wholesalerId,
      p_min_order_value: parsed.min,
      p_delivery_fee: parsed.fee,
      p_free_delivery_threshold: parsed.freeFrom,
    });
    setSaving(false);
    if (rpcError) return toast.error(rpcError.message || "We couldn't save your order terms.");
    toast.success("Order terms saved.");
    void load();
  };

  return (
    <Card className="p-5">
      <div className="flex items-center gap-2">
        <Truck className="h-5 w-5 text-primary" aria-hidden="true" />
        <h2 className="font-display text-xl font-bold">Minimum order &amp; delivery fee</h2>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Pharmacies see these in their cart and cannot check out below your minimum. The minimum and
        the free-delivery amount are measured on the goods total after any customer discount. Leave
        a field empty for no rule.
      </p>
      {loading ? (
        <p className="mt-4 text-sm text-muted-foreground" role="status">
          Loading...
        </p>
      ) : error ? (
        <p role="alert" className="mt-4 text-sm">
          We couldn&apos;t load your order terms.{" "}
          <button type="button" className="text-primary underline" onClick={() => void load()}>
            Try again
          </button>
        </p>
      ) : (
        <>
          <div className="mt-4 grid gap-3 sm:grid-cols-3">
            <label className="block text-sm">
              <span className="mb-1 block text-muted-foreground">Minimum order (GHS)</span>
              <Input
                type="number"
                min={0}
                step="0.01"
                value={min}
                onChange={(event) => setMin(event.target.value)}
                placeholder="No minimum"
              />
            </label>
            <label className="block text-sm">
              <span className="mb-1 block text-muted-foreground">Delivery fee (GHS)</span>
              <Input
                type="number"
                min={0}
                step="0.01"
                value={fee}
                onChange={(event) => setFee(event.target.value)}
                placeholder="Free delivery"
              />
            </label>
            <label className="block text-sm">
              <span className="mb-1 block text-muted-foreground">Free delivery from (GHS)</span>
              <Input
                type="number"
                min={0}
                step="0.01"
                value={freeFrom}
                onChange={(event) => setFreeFrom(event.target.value)}
                placeholder="Always charge the fee"
              />
            </label>
          </div>
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <Button size="sm" variant="hero" disabled={saving} onClick={() => void save()}>
              {saving ? "Saving..." : "Save terms"}
            </Button>
            <span className="text-sm text-muted-foreground">
              Currently: {describeTerms(terms) ?? "no minimum order and no delivery fee"}
            </span>
          </div>
        </>
      )}
    </Card>
  );
}
