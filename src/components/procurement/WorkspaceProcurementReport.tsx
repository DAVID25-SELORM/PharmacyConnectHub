import { useEffect, useState } from "react";
import { externalRpc } from "@/lib/external-procurement";
import { formatGHSCell, downloadXlsx } from "@/lib/reports";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
type Workspace = { id: string; name: string; summary: Record<string, number> };
export function WorkspaceProcurementReport() {
  const [rows, setRows] = useState<Workspace[]>([]),
    [selected, setSelected] = useState("");
  const [from, setFrom] = useState(""),
    [to, setTo] = useState(""),
    [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    setRows([]);
    setError("");
    void externalRpc<Workspace[]>("external_workspace_summary", { p_filters: { from, to } })
      .then((d) => {
        if (live) setRows(d);
      })
      .catch((e) => {
        if (live) setError(e.message);
      });
    return () => {
      live = false;
    };
  }, [from, to]);
  const filtered = rows.filter((r) => !selected || r.id === selected);
  return (
    <section className="space-y-4 rounded-xl border p-4">
      <h2 className="text-lg font-semibold">Pharmacy workspace report</h2>
      <p>
        Each pharmacy business is a separate workspace. Only workspaces you are authorized to access
        appear here.
      </p>
      <div className="grid gap-3 sm:grid-cols-3">
        <label>
          From
          <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label>
          Through
          <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </label>
        <label>
          Pharmacy / branch
          <select
            className="block w-full rounded border p-2"
            value={selected}
            onChange={(e) => setSelected(e.target.value)}
          >
            <option value="">All authorized workspaces</option>
            {rows.map((r) => (
              <option key={r.id} value={r.id}>
                {r.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      {error && <p role="alert">{error}</p>}
      <p>
        Total recorded spend{" "}
        {formatGHSCell(filtered.reduce((n, r) => n + Number(r.summary.spend), 0))}
      </p>
      {filtered.map((r) => (
        <article key={r.id} className="rounded border p-3">
          <strong>{r.name}</strong>
          <p>
            {r.summary.count} receipts | Spend {formatGHSCell(r.summary.spend)} | Outstanding{" "}
            {formatGHSCell(r.summary.outstanding)} | {r.summary.quarantined} quarantined batches
          </p>
        </article>
      ))}
      <Button
        variant="outline"
        onClick={() =>
          downloadXlsx("workspace-procurement.xlsx", [
            {
              name: "Workspace procurement",
              headers: [
                "Workspace",
                "Receipts",
                "Spend GHS",
                "Outstanding GHS",
                "Quarantined batches",
              ],
              rows: filtered.map((r) => [
                r.name,
                r.summary.count,
                r.summary.spend,
                r.summary.outstanding,
                r.summary.quarantined,
              ]),
            },
          ])
        }
      >
        Export workspace report
      </Button>
    </section>
  );
}
