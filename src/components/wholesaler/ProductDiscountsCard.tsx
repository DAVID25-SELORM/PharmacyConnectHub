import { useCallback, useEffect, useState } from "react";
import { Tag } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

type Rule = {
  id: string;
  pharmacy_id: string;
  pharmacy_name: string;
  product_id: string;
  product_name: string;
  list_price_ghs: number;
  discount_percent: number;
  min_quantity: number;
  starts_at: string;
  ends_at: string | null;
  active: boolean;
  total_count: number;
};

const PAGE_SIZE = 25;

/** Percentage off one product for one pharmacy, optionally from a minimum quantity. Overrides that pharmacy's general discount on that product. */
export function ProductDiscountsCard({
  wholesalerId,
  products,
}: {
  wholesalerId: string;
  products: Array<{ id: string; name: string }>;
}) {
  const [pharmacies, setPharmacies] = useState<Array<{ id: string; name: string }>>([]);
  const [rules, setRules] = useState<Rule[]>([]);
  const [page, setPage] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [pharmacyId, setPharmacyId] = useState("");
  const [productId, setProductId] = useState("");
  const [percent, setPercent] = useState("");
  const [minQuantity, setMinQuantity] = useState("1");
  const [startsAt, setStartsAt] = useState("");
  const [endsAt, setEndsAt] = useState("");
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const [{ data: pharmacyData }, { data, error: rpcError }] = await Promise.all([
      supabase
        .from("businesses")
        .select("id,name")
        .eq("type", "pharmacy")
        .eq("verification_status", "approved")
        .order("name"),
      rpc("list_wholesaler_product_discounts", {
        p_wholesaler_id: wholesalerId,
        p_include_inactive: false,
        p_limit: PAGE_SIZE,
        p_offset: page * PAGE_SIZE,
      }),
    ]);
    setPharmacies((pharmacyData as Array<{ id: string; name: string }>) ?? []);
    if (rpcError) setError(true);
    else setRules(Array.isArray(data) ? (data as Rule[]) : []);
    setLoading(false);
  }, [wholesalerId, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const save = async () => {
    const pct = Number(percent);
    const qty = Number(minQuantity);
    if (!pharmacyId) return toast.error("Choose a pharmacy.");
    if (!productId) return toast.error("Choose a product.");
    if (!Number.isFinite(pct) || pct <= 0 || pct > 90)
      return toast.error("Enter a discount above 0% and at most 90%.");
    if (!Number.isInteger(qty) || qty < 1)
      return toast.error("The minimum quantity must be a whole number of at least 1.");
    setSaving(true);
    const { error: rpcError } = await rpc("upsert_product_discount", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: pharmacyId,
      p_product_id: productId,
      p_percent: pct,
      p_min_quantity: qty,
      p_starts_at: startsAt
        ? new Date(`${startsAt}T00:00:00`).toISOString()
        : new Date().toISOString(),
      p_ends_at: endsAt ? new Date(`${endsAt}T23:59:59`).toISOString() : null,
    });
    setSaving(false);
    if (rpcError) return toast.error(rpcError.message || "We couldn't save this discount.");
    toast.success("Product discount saved.");
    setPercent("");
    void load();
  };

  const remove = async (rule: Rule) => {
    const { error: rpcError } = await rpc("deactivate_product_discount", {
      p_discount_id: rule.id,
    });
    if (rpcError) return toast.error(rpcError.message || "We couldn't remove this discount.");
    toast.success("Discount removed.");
    void load();
  };

  const total = rules[0]?.total_count ?? 0;

  return (
    <Card className="p-5">
      <div className="flex items-center gap-2">
        <Tag className="h-5 w-5 text-primary" aria-hidden="true" />
        <h2 className="font-display text-xl font-bold">Product discounts</h2>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Give one pharmacy a percentage off one product, optionally from a minimum quantity (for
        example 15% from 10 units). A product discount replaces that pharmacy&apos;s general
        discount on that product. Applied securely at checkout.
      </p>

      <div className="mt-4 grid gap-3 md:grid-cols-3">
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Pharmacy</span>
          <select
            className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
            value={pharmacyId}
            onChange={(event) => setPharmacyId(event.target.value)}
          >
            <option value="">Choose a pharmacy</option>
            {pharmacies.map((pharmacy) => (
              <option key={pharmacy.id} value={pharmacy.id}>
                {pharmacy.name}
              </option>
            ))}
          </select>
        </label>
        <label className="block text-sm md:col-span-2">
          <span className="mb-1 block text-muted-foreground">Product</span>
          <select
            className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
            value={productId}
            onChange={(event) => setProductId(event.target.value)}
          >
            <option value="">Choose a product</option>
            {products.map((product) => (
              <option key={product.id} value={product.id}>
                {product.name}
              </option>
            ))}
          </select>
        </label>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Discount (%)</span>
          <Input
            type="number"
            min={0.01}
            max={90}
            step="0.01"
            value={percent}
            onChange={(event) => setPercent(event.target.value)}
          />
        </label>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">From quantity</span>
          <Input
            type="number"
            min={1}
            value={minQuantity}
            onChange={(event) => setMinQuantity(event.target.value)}
          />
        </label>
        <div className="grid grid-cols-2 gap-2">
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Starts</span>
            <Input
              type="date"
              value={startsAt}
              onChange={(event) => setStartsAt(event.target.value)}
            />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Ends</span>
            <Input type="date" value={endsAt} onChange={(event) => setEndsAt(event.target.value)} />
          </label>
        </div>
      </div>
      <Button
        className="mt-4"
        size="sm"
        variant="hero"
        disabled={saving}
        onClick={() => void save()}
      >
        {saving ? "Saving..." : "Save product discount"}
      </Button>

      <div className="mt-6">
        {loading ? (
          <p className="text-sm text-muted-foreground" role="status">
            Loading...
          </p>
        ) : error ? (
          <p role="alert" className="text-sm">
            We couldn&apos;t load your product discounts.{" "}
            <button type="button" className="text-primary underline" onClick={() => void load()}>
              Try again
            </button>
          </p>
        ) : rules.length === 0 ? (
          <p className="text-sm text-muted-foreground">No product discounts yet.</p>
        ) : (
          <ul className="divide-y divide-border rounded-xl border border-border text-sm">
            {rules.map((rule) => (
              <li key={rule.id} className="flex flex-wrap items-center justify-between gap-3 p-3">
                <div>
                  <div className="font-medium">
                    {rule.product_name} · {rule.pharmacy_name}
                  </div>
                  <div className="text-muted-foreground">
                    {Number(rule.discount_percent)}% off {formatGHS(rule.list_price_ghs)}
                    {rule.min_quantity > 1 ? ` from ${rule.min_quantity} units` : ""} ·{" "}
                    {formatReportDate(rule.starts_at)} –{" "}
                    {rule.ends_at ? formatReportDate(rule.ends_at) : "no end date"}
                  </div>
                </div>
                <Button size="sm" variant="outline" onClick={() => void remove(rule)}>
                  Remove
                </Button>
              </li>
            ))}
          </ul>
        )}
        {total > PAGE_SIZE && (
          <div className="mt-3 flex items-center justify-between text-sm text-muted-foreground">
            <span>
              Page {page + 1} of {Math.ceil(total / PAGE_SIZE)}
            </span>
            <div className="flex gap-2">
              <Button
                size="sm"
                variant="outline"
                disabled={page === 0}
                onClick={() => setPage((value) => value - 1)}
              >
                Previous
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={(page + 1) * PAGE_SIZE >= total}
                onClick={() => setPage((value) => value + 1)}
              >
                Next
              </Button>
            </div>
          </div>
        )}
      </div>
    </Card>
  );
}
