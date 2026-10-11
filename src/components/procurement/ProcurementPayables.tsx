import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useSession } from "@/hooks/use-session";
import { externalRpc, label } from "@/lib/external-procurement";
import { formatGHSCell, downloadXlsx } from "@/lib/reports";
import { Button } from "@/components/ui/button";
type Payables = {
  marketplace_total: number;
  external_total: number;
  supplier_credit: number;
  aging: { bucket: string; marketplace_ghs: number; external_ghs: number }[];
  suppliers: {
    supplier_id: string;
    supplier: string;
    invoices: number;
    purchased: number;
    paid: number;
    credited: number;
    outstanding: number;
  }[];
};
export function ProcurementPayables() {
  const { business } = useSession();
  const [data, setData] = useState<Payables | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    setData(null);
    setError("");
    if (business?.id)
      void externalRpc<Payables>("procurement_payables", { p_pharmacy_id: business.id })
        .then((v) => {
          if (live) setData(v);
        })
        .catch((e) => {
          if (live) setError(e.message);
        });
    return () => {
      live = false;
    };
  }, [business?.id]);
  if (error)
    return (
      <p className="px-6 py-3 text-sm" role="alert">
        Consolidated payables unavailable: {error}
      </p>
    );
  if (!data) return <p className="px-6 py-3 text-sm">Loading consolidated payables...</p>;
  return (
    <section
      className="m-6 space-y-4 rounded-xl border p-4"
      aria-label="Consolidated procurement payables"
    >
      <h2 className="text-lg font-semibold">All supplier payables</h2>
      <p className="text-2xl font-semibold">
        {formatGHSCell(Number(data.marketplace_total) + Number(data.external_total))}
      </p>
      <p>
        Marketplace {formatGHSCell(data.marketplace_total)} | External{" "}
        {formatGHSCell(data.external_total)} | Supplier refunds / credits owed{" "}
        {formatGHSCell(data.supplier_credit)}
      </p>
      <div className="grid gap-2 sm:grid-cols-5">
        {data.aging.map((a) => (
          <div key={a.bucket} className="rounded bg-muted p-3">
            <strong>{label(a.bucket)}</strong>
            <p>{formatGHSCell(Number(a.marketplace_ghs) + Number(a.external_ghs))}</p>
            <p className="text-xs">External {formatGHSCell(a.external_ghs)}</p>
          </div>
        ))}
      </div>
      <details>
        <summary className="cursor-pointer font-medium">External supplier balances</summary>
        <div className="space-y-2 pt-3">
          {data.suppliers.map((s) => (
            <div key={s.supplier_id} className="rounded border p-3">
              <strong>{s.supplier ?? "Unknown supplier"}</strong>
              <p>
                {s.invoices} receipts | Purchased {formatGHSCell(s.purchased)} | Paid{" "}
                {formatGHSCell(s.paid)} | Return credits {formatGHSCell(s.credited)} | Balance{" "}
                {formatGHSCell(s.outstanding)}
              </p>
            </div>
          ))}
        </div>
      </details>
      <Button
        variant="outline"
        onClick={() =>
          downloadXlsx("supplier-payables.xlsx", [
            {
              name: "External supplier balances",
              headers: [
                "Supplier",
                "Receipts",
                "Purchased GHS",
                "Paid GHS",
                "Return credits GHS",
                "Balance GHS",
              ],
              rows: data.suppliers.map((s) => [
                s.supplier ?? "Unknown",
                s.invoices,
                s.purchased,
                s.paid,
                s.credited,
                s.outstanding,
              ]),
            },
            {
              name: "Consolidated aging",
              headers: ["Bucket", "Marketplace GHS", "External GHS", "Combined GHS"],
              rows: data.aging.map((a) => [
                a.bucket,
                a.marketplace_ghs,
                a.external_ghs,
                Number(a.marketplace_ghs) + Number(a.external_ghs),
              ]),
            },
          ])
        }
      >
        Export payable balances
      </Button>
      <Link
        className="ml-4 text-primary underline"
        to="/pharmacy/procurement"
        search={{ payment: "outstanding" }}
      >
        Open external invoices and payments
      </Link>
      <p className="text-xs text-muted-foreground">
        Totals exclude external drafts and rejected receipts. Pending and quarantined receipts can
        still represent supplier obligations. Marketplace registers below retain their existing
        scope.
      </p>
    </section>
  );
}
