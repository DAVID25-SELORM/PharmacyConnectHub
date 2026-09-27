import { useCallback, useEffect, useState } from "react";
import { CreditCard } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { validateCreditForm } from "@/lib/credit-terms";
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

type CreditLine = {
  pharmacy_id: string;
  pharmacy_name: string;
  credit_limit_ghs: number;
  payment_terms_days: number;
  outstanding_ghs: number;
  available_ghs: number;
  internal_note: string | null;
  updated_at: string;
};

/** Approved credit limits per pharmacy. Settling a credit order still goes through "Confirm payment" once delivered. */
export function CreditTermsCard({ wholesalerId }: { wholesalerId: string }) {
  const [pharmacies, setPharmacies] = useState<Array<{ id: string; name: string }>>([]);
  const [lines, setLines] = useState<CreditLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [pharmacyId, setPharmacyId] = useState("");
  const [limit, setLimit] = useState("");
  const [days, setDays] = useState("30");
  const [note, setNote] = useState("");
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
      rpc("list_wholesaler_credit_terms", { p_wholesaler_id: wholesalerId }),
    ]);
    setPharmacies((pharmacyData as Array<{ id: string; name: string }>) ?? []);
    if (rpcError) setError(true);
    else setLines(Array.isArray(data) ? (data as CreditLine[]) : []);
    setLoading(false);
  }, [wholesalerId]);

  useEffect(() => {
    void load();
  }, [load]);

  const save = async () => {
    if (!pharmacyId) return toast.error("Choose a pharmacy.");
    const parsed = validateCreditForm({ limit, days });
    if (parsed.error) return toast.error(parsed.error);
    setSaving(true);
    const { error: rpcError } = await rpc("set_credit_terms", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: pharmacyId,
      p_credit_limit: parsed.limit,
      p_payment_terms_days: parsed.days,
      p_note: note.trim() || null,
    });
    setSaving(false);
    if (rpcError) return toast.error(rpcError.message || "We couldn't save this credit line.");
    toast.success("Credit terms saved.");
    setLimit("");
    setNote("");
    void load();
  };

  const revoke = async (line: CreditLine) => {
    if (
      !window.confirm(
        `Revoke credit for ${line.pharmacy_name}? They will pay on delivery from now on.`,
      )
    )
      return;
    const { error: rpcError } = await rpc("revoke_credit_terms", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: line.pharmacy_id,
    });
    if (rpcError) return toast.error(rpcError.message || "We couldn't revoke this credit line.");
    toast.success("Credit revoked.");
    void load();
  };

  return (
    <Card className="p-5">
      <div className="flex items-center gap-2">
        <CreditCard className="h-5 w-5 text-primary" aria-hidden="true" />
        <h2 className="font-display text-xl font-bold">Customer credit</h2>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Approve a credit limit for a pharmacy so they can order now and pay within your terms.
        Checkout blocks any credit order that would push their balance over the limit. Settle a
        credit order the same way as a cash order, by confirming payment once it is delivered.
      </p>

      <div className="mt-4 grid gap-3 md:grid-cols-4">
        <label className="block text-sm md:col-span-2">
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
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Credit limit (GHS)</span>
          <Input
            type="number"
            min={0.01}
            step="0.01"
            value={limit}
            onChange={(event) => setLimit(event.target.value)}
          />
        </label>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Payment terms (days)</span>
          <Input
            type="number"
            min={1}
            max={365}
            value={days}
            onChange={(event) => setDays(event.target.value)}
          />
        </label>
      </div>
      <label className="mt-3 block text-sm">
        <span className="mb-1 block text-muted-foreground">Note (optional, internal)</span>
        <Input value={note} maxLength={500} onChange={(event) => setNote(event.target.value)} />
      </label>
      <Button
        className="mt-4"
        size="sm"
        variant="hero"
        disabled={saving}
        onClick={() => void save()}
      >
        {saving ? "Saving..." : "Save credit terms"}
      </Button>

      <div className="mt-6">
        {loading ? (
          <p className="text-sm text-muted-foreground" role="status">
            Loading...
          </p>
        ) : error ? (
          <p role="alert" className="text-sm">
            We couldn&apos;t load your credit lines.{" "}
            <button type="button" className="text-primary underline" onClick={() => void load()}>
              Try again
            </button>
          </p>
        ) : lines.length === 0 ? (
          <p className="text-sm text-muted-foreground">No pharmacy has approved credit yet.</p>
        ) : (
          <ul className="divide-y divide-border rounded-xl border border-border text-sm">
            {lines.map((line) => (
              <li
                key={line.pharmacy_id}
                className="flex flex-wrap items-center justify-between gap-3 p-3"
              >
                <div>
                  <div className="font-medium">{line.pharmacy_name}</div>
                  <div className="text-muted-foreground">
                    {formatGHS(line.outstanding_ghs)} owed of {formatGHS(line.credit_limit_ghs)} ·{" "}
                    {line.payment_terms_days}-day terms · updated{" "}
                    {formatReportDate(line.updated_at)}
                    {line.internal_note ? ` · ${line.internal_note}` : ""}
                  </div>
                </div>
                <Button size="sm" variant="outline" onClick={() => void revoke(line)}>
                  Revoke
                </Button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  );
}
