import { useEffect, useState } from "react";
import { externalRpc, type Contact } from "@/lib/external-procurement";
import { formatGHSCell, downloadXlsx } from "@/lib/reports";
import { Button } from "@/components/ui/button";
type Profile = {
  sources: { source: string; source_type: string; purchases: number; latest: string }[];
  products: { product: string; quantity: number; cost: number }[];
  documents: { reference: string; purchase_id: string; filename: string; document_type: string }[];
  balance: number | null;
};
export function SupplierProfile({
  pharmacy,
  contact,
  open,
}: {
  pharmacy: string;
  contact: Contact;
  open: (id: string) => void;
}) {
  const [data, setData] = useState<Profile | null>(null),
    [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    setData(null);
    setError("");
    void externalRpc<Profile>("external_supplier_profile", {
      p_pharmacy_id: pharmacy,
      p_supplier_id: contact.id,
    })
      .then((d) => {
        if (live) setData(d);
      })
      .catch((e) => {
        if (live) setError(e.message);
      });
    return () => {
      live = false;
    };
  }, [pharmacy, contact.id]);
  async function exportStatement() {
    try {
      const entries = await externalRpc<
        {
          date: string;
          reference: string;
          kind: string;
          debit: number;
          credit: number;
          balance: number;
        }[]
      >("external_supplier_statement", { p_pharmacy_id: pharmacy, p_supplier_id: contact.id });
      await downloadXlsx("supplier-statement.xlsx", [
        {
          name: "Supplier statement",
          headers: ["Date", "Reference", "Entry", "Debit GHS", "Credit GHS", "Running balance GHS"],
          rows: entries.map((e) => [e.date, e.reference, e.kind, e.debit, e.credit, e.balance]),
        },
      ]);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Statement export failed");
    }
  }

  return (
    <section className="space-y-3 rounded-xl border bg-card p-4">
      <h2 className="text-lg font-semibold">Supplier profile: {contact.name}</h2>
      <p>
        {[
          contact.phone,
          contact.alternate_phone,
          contact.email,
          contact.location,
          contact.license_reference,
        ]
          .filter(Boolean)
          .join(" | ")}
      </p>
      {error && <p role="alert">{error}</p>}
      {data && (
        <>
          <p>
            {data.balance !== null
              ? `Supplier balance ${formatGHSCell(data.balance)}`
              : "Select a receipt below to view its traceability."}
          </p>
          {data.balance !== null && (
            <Button variant="outline" onClick={() => void exportStatement()}>
              Export supplier statement
            </Button>
          )}
          <details>
            <summary>Original source history</summary>
            {data.sources.map((s, n) => (
              <p key={n}>
                {s.source ?? "Unknown"} | {s.source_type} | {s.purchases} receipts | Latest{" "}
                {s.latest}
              </p>
            ))}
          </details>
          <details>
            <summary>Products supplied (all recorded receipts)</summary>
            {data.products.map((p, n) => (
              <p key={n}>
                {p.product} | {p.quantity} packs | {formatGHSCell(p.cost)}
              </p>
            ))}
          </details>
          <details>
            <summary>Recent evidence (up to 100 documents)</summary>
            {data.documents.map((d, n) => (
              <p key={n}>
                <Button variant="link" onClick={() => open(d.purchase_id)}>
                  {d.reference}: {d.filename}
                </Button>
              </p>
            ))}
          </details>
          <p className="text-sm text-muted-foreground">
            Filtered receipts below provide batch history, review events, returns and payment
            details. Export the filtered list for the complete transaction history.
          </p>
        </>
      )}
    </section>
  );
}
