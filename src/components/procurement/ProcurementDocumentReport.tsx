import { useEffect, useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { externalRpc } from "@/lib/external-procurement";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
type Row = {
  id: string;
  reference: string;
  kind: string;
  status: string;
  supplier: string;
  medicine: string;
  unit: string;
  ordered_quantity: number;
  received_quantity: number;
  unit_price: number | null;
};
export function ProcurementDocumentReport({ businessId }: { businessId: string }) {
  const [from, setFrom] = useState(""),
    [to, setTo] = useState(""),
    [query, setQuery] = useState(""),
    [offset, setOffset] = useState(0),
    [rows, setRows] = useState<Row[]>([]),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(false);
  const term = useDebouncedValue(query, 250);
  useEffect(() => {
    let live = true;
    setLoading(true);
    externalRpc<Row[]>("procurement_document_report", {
      p_business_id: businessId,
      p_from: from || null,
      p_to: to || null,
      p_query: term,
      p_offset: offset,
    })
      .then((data) => {
        if (live) {
          setRows(data);
          setError("");
        }
      })
      .catch((e) => {
        if (live) setError(e.message);
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [businessId, from, to, term, offset]);
  return (
    <section className="space-y-3 rounded border p-3">
      <h3 className="font-semibold">Requested, ordered and recorded deliveries</h3>
      <p className="text-sm">
        Only linked receipts count as received; zero means no linked receipt recorded. Drafts and
        requests are not purchases. Amounts exclude unagreed charges.
      </p>
      <div className="grid gap-2 sm:grid-cols-3">
        <label>
          From
          <Input
            type="date"
            value={from}
            onChange={(e) => {
              setFrom(e.target.value);
              setOffset(0);
            }}
          />
        </label>
        <label>
          To
          <Input
            type="date"
            value={to}
            onChange={(e) => {
              setTo(e.target.value);
              setOffset(0);
            }}
          />
        </label>
        <label>
          Supplier, medicine or reference
          <Input
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setOffset(0);
            }}
          />
        </label>
      </div>
      {error && <p role="alert">{error}</p>}
      {loading && <p role="status">Loading document history...</p>}
      <div className="max-h-96 overflow-auto">
        <table className="w-full text-left text-sm">
          <caption className="sr-only">Procurement document line history</caption>
          <thead>
            <tr>
              {[
                "Reference / status",
                "Supplier",
                "Medicine",
                "Ordered",
                "Received",
                "Outstanding",
                "Goods GHS",
              ].map((t) => (
                <th className="p-2" key={t}>
                  {t}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.slice(0, 100).map((r, i) => (
              <tr key={`${r.id}-${i}`}>
                <td className="p-2">
                  {r.reference}
                  <br />
                  {r.kind} | {r.status}
                </td>
                <td className="p-2">{r.supplier}</td>
                <td className="p-2">{r.medicine}</td>
                <td className="p-2">
                  {r.ordered_quantity} {r.unit}
                </td>
                <td className="p-2">
                  {r.received_quantity} {r.unit}
                </td>
                <td className="p-2">
                  {r.kind === "request" || r.status === "draft"
                    ? "Not issued order"
                    : r.status === "cancelled"
                      ? "Cancelled"
                      : Math.max(0, r.ordered_quantity - r.received_quantity)}{" "}
                  {r.kind === "order" && r.status !== "draft" && r.status !== "cancelled"
                    ? r.unit
                    : ""}
                </td>
                <td className="p-2">
                  {r.unit_price === null
                    ? "Not priced"
                    : ((Math.round(r.unit_price * 100) * r.ordered_quantity) / 100).toFixed(2)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="flex gap-2">
        <Button
          type="button"
          variant="outline"
          disabled={loading || !offset}
          onClick={() => setOffset((v) => Math.max(0, v - 100))}
        >
          Previous report page
        </Button>
        <Button
          type="button"
          variant="outline"
          disabled={loading || rows.length < 101}
          onClick={() => setOffset((v) => v + 100)}
        >
          Next report page
        </Button>
      </div>
    </section>
  );
}
