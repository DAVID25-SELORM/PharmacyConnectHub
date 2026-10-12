import { confirmAction } from "@/lib/confirm-action";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { db, externalRpc } from "@/lib/external-procurement";
import type { SupplyLine } from "@/lib/external-supply-orders";
type Template = { id: string; name: string; lines: SupplyLine[]; version: number };
export function ProcurementTemplates({
  businessId,
  lines,
  onAdd,
}: {
  businessId: string;
  lines: SupplyLine[];
  onAdd: (lines: SupplyLine[]) => void;
}) {
  const [rows, setRows] = useState<Template[]>([]),
    [name, setName] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [revision, setRevision] = useState(0);
  useEffect(() => {
    let live = true;
    db.from("procurement_templates")
      .select("id,name,lines,version")
      .eq("business_id", businessId)
      .eq("archived", false)
      .order("name")
      .limit(50)
      .then(({ data, error }) => {
        if (live) {
          if (error) setError(error.message);
          else {
            setRows(data as Template[]);
            setError("");
          }
        }
      });
    return () => {
      live = false;
    };
  }, [businessId, revision]);
  async function save(row?: Template, archive = false) {
    setBusy(true);
    try {
      await externalRpc("save_procurement_template", {
        p_business_id: businessId,
        p_name: row?.name ?? name,
        p_lines: archive ? row?.lines : lines,
        p_id: row?.id ?? null,
        p_version: row?.version ?? null,
        p_archived: archive,
      });
      setRevision((x) => x + 1);
      setName("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <details className="rounded border p-3">
      <summary className="cursor-pointer font-medium">Reusable procurement lists</summary>
      <p className="text-sm">
        Templates copy quantities and medicine snapshots. Prices, supplier terms and document
        identities are not reused.
      </p>
      {error && <p role="alert">{error}</p>}
      <div className="my-2 flex gap-2">
        <Input
          aria-label="Template name"
          value={name}
          maxLength={80}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Monthly essentials"
        />
        <Button
          type="button"
          disabled={busy || !name.trim() || !lines.length}
          onClick={() => void save()}
        >
          Save items as list
        </Button>
      </div>
      {rows.map((row) => (
        <div key={row.id} className="flex flex-wrap items-center gap-2 py-1">
          <span>{row.name}</span>
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() =>
              onAdd(row.lines.map((l) => ({ ...l, id: crypto.randomUUID(), unit_price: null })))
            }
          >
            Use list
          </Button>
          <Button
            type="button"
            variant="outline"
            disabled={busy || !lines.length}
            onClick={async () => {
              if (
                await confirmAction(
                  `Replace ${row.name} with the items currently in this draft? Prices will be removed.`,
                )
              )
                void save(row);
            }}
          >
            Update from current items
          </Button>
          <Button
            type="button"
            variant="ghost"
            disabled={busy}
            onClick={async () => {
              if (
                await confirmAction("Archive this reusable list? Saved documents remain unchanged.")
              )
                void save(row, true);
            }}
          >
            Archive list
          </Button>
        </div>
      ))}
    </details>
  );
}
