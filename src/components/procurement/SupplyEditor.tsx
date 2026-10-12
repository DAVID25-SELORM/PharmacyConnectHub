import { ProcurementTemplates } from "./ProcurementTemplates";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { externalRpc } from "@/lib/external-procurement";
import { supplyLine, type SupplyDraft, type SupplyLine } from "@/lib/external-supply-orders";
import {
  catalogueLine,
  medicineLabel,
  type CatalogueEntry,
  importProcurementRows,
  lineMinor,
  PROCUREMENT_UNITS,
} from "@/lib/procurement-catalogue";
import { ProcurementCatalogue } from "./ProcurementCatalogue";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
type Supplier = {
  id: string;
  name: string;
  phone: string;
  email: string;
  location: string;
  contact_person: string;
};
export function SupplyEditor({
  businessId,
  draft,
  onChange,
  busy,
  save,
  saveError,
  saved = false,
}: {
  businessId: string;
  draft: SupplyDraft;
  onChange: (draft: SupplyDraft) => void;
  busy: boolean;
  save: () => void;
  saveError: string;
  saved?: boolean;
}) {
  const [supplierQuery, setSupplierQuery] = useState(""),
    [suppliers, setSuppliers] = useState<Supplier[]>([]),
    [supplierError, setSupplierError] = useState("");
  const term = useDebouncedValue(supplierQuery, 250);
  const [newSupplier, setNewSupplier] = useState<Record<string, string> | null>(null),
    [supplierBusy, setSupplierBusy] = useState(false),
    [supplierRevision, setSupplierRevision] = useState(0);
  const [preview, setPreview] = useState(false),
    [imported, setImported] = useState<
      (ReturnType<typeof importProcurementRows>[number] & { match?: string })[]
    >([]),
    [importBusy, setImportBusy] = useState(false);
  const [saveImportedCatalogue, setSaveImportedCatalogue] = useState(false);
  const patch = (p: Partial<SupplyDraft>) => onChange({ ...draft, ...p });
  const line = (id: string, p: Partial<SupplyLine>) =>
    patch({ lines: draft.lines.map((l) => (l.id === id ? { ...l, ...p } : l)) });
  const add = (lines: SupplyLine[]) => {
    // Only replace the untouched starter row; never discard partially entered work.
    const existing =
      draft.lines.length === 1 &&
      !draft.lines[0].name &&
      !draft.lines[0].specification &&
      draft.lines[0].quantity === 1 &&
      draft.lines[0].unit_price === null &&
      (draft.lines[0].unit || "packs") === "packs" &&
      !draft.lines[0].catalogue_id
        ? []
        : draft.lines;
    if (existing.length + lines.length > 200) {
      toast.error("At most 200 items per document.");
      return false;
    }
    patch({ lines: [...existing, ...lines] });
    return true;
  };
  useEffect(() => {
    let live = true;
    externalRpc<Supplier[]>("procurement_suppliers", { p_business_id: businessId, p_query: term })
      .then((data) => {
        if (live) {
          setSuppliers(data);
          setSupplierError("");
        }
      })
      .catch((e) => {
        if (live) setSupplierError(e.message);
      });
    return () => {
      live = false;
    };
  }, [businessId, term, supplierRevision]);
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        save();
      }}
      className="space-y-5"
    >
      <fieldset disabled={busy || importBusy || supplierBusy} className="space-y-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <label className="font-medium">
            Document type
            <select
              aria-label="Document type"
              className="ml-2 rounded border bg-background p-2"
              value={draft.kind}
              onChange={(e) =>
                patch({ kind: e.target.value as SupplyDraft["kind"], source_request_id: undefined })
              }
            >
              <option value="request">Request availability / quotation</option>
              <option value="order">Purchase order</option>
            </select>
          </label>
          <span role="status" className="text-sm">
            {busy
              ? "Saving..."
              : saveError
                ? "Save failed - changes retained"
                : saved
                  ? "Saved"
                  : "Unsaved changes"}
          </span>
        </div>
        <section className="space-y-3 rounded-lg border p-3">
          <h3 className="font-semibold">1. Supplier and delivery</h3>
          <div className="flex flex-col gap-2 sm:flex-row">
            <Input
              aria-label="Search saved suppliers"
              placeholder="Search suppliers by name, phone or email"
              value={supplierQuery}
              onChange={(e) => setSupplierQuery(e.target.value)}
              className="min-w-0 flex-1"
            />
            <Button
              type="button"
              variant="outline"
              onClick={() =>
                setNewSupplier({
                  name: "",
                  phone: "",
                  email: "",
                  contact_person: "",
                  address: "",
                  notes: "",
                })
              }
            >
              Add new external supplier
            </Button>
          </div>
          {supplierError && <p role="alert">Supplier directory: {supplierError}</p>}
          <select
            aria-label="Saved supplier"
            className="w-full rounded border bg-background p-2"
            value={draft.supplier_id || ""}
            onChange={(e) => {
              const s = suppliers.find((x) => x.id === e.target.value);
              if (s)
                patch({
                  supplier_id: s.id,
                  supplier: s.name,
                  supplier_phone: s.phone || "",
                  supplier_email: s.email || "",
                  supplier_contact: [s.contact_person, s.phone, s.email]
                    .filter(Boolean)
                    .join(" / "),
                });
            }}
          >
            <option value="">Choose a saved supplier or enter details below</option>
            {suppliers.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} | external / unverified
              </option>
            ))}
          </select>
          {newSupplier && (
            <div className="space-y-2 rounded border bg-muted/30 p-3">
              <p>Save a private supplier; this does not create a verified wholesaler account.</p>
              <div className="grid gap-2 sm:grid-cols-2">
                {Object.entries(newSupplier).map(([key, value]) => (
                  <label key={key}>
                    {key.replaceAll("_", " ")}
                    <Input
                      value={value}
                      maxLength={key === "notes" ? 1000 : 200}
                      onChange={(e) => setNewSupplier({ ...newSupplier, [key]: e.target.value })}
                    />
                  </label>
                ))}
              </div>
              <Button
                type="button"
                disabled={supplierBusy}
                onClick={async () => {
                  setSupplierBusy(true);
                  try {
                    const id = await externalRpc<string>("save_procurement_supplier", {
                      p_business_id: businessId,
                      p_data: newSupplier,
                    });
                    patch({
                      supplier_id: id,
                      supplier: newSupplier.name,
                      supplier_phone: newSupplier.phone,
                      supplier_email: newSupplier.email,
                      supplier_contact: [
                        newSupplier.contact_person,
                        newSupplier.phone,
                        newSupplier.email,
                      ]
                        .filter(Boolean)
                        .join(" / "),
                    });
                    setSupplierRevision((x) => x + 1);
                    setNewSupplier(null);
                    toast.success("Supplier saved.");
                  } catch (e) {
                    toast.error(e instanceof Error ? e.message : "Save failed");
                  } finally {
                    setSupplierBusy(false);
                  }
                }}
              >
                {supplierBusy ? "Saving..." : "Save supplier"}
              </Button>
              <Button type="button" variant="ghost" onClick={() => setNewSupplier(null)}>
                Close supplier editor
              </Button>
            </div>
          )}
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {(
              [
                ["supplier", "Supplier / intended recipient"],
                ["supplier_contact", "Supplier phone / email"],
                ["required_date", "Required delivery date"],
                ["delivery_address", "Delivery address"],
                ["supplier_reference", "Supplier reference"],
              ] as const
            ).map(([key, label]) => (
              <label key={key} className="text-sm">
                {label}
                <Input
                  type={key === "required_date" ? "date" : "text"}
                  value={draft[key] || ""}
                  maxLength={key === "delivery_address" ? 1000 : 200}
                  onChange={(e) =>
                    patch({
                      [key]: e.target.value,
                      ...(key === "supplier" ? { supplier_id: undefined } : {}),
                    })
                  }
                />
              </label>
            ))}
          </div>
        </section>
        <ProcurementTemplates businessId={businessId} lines={draft.lines} onAdd={add} />
        <h3 className="font-semibold">2. Medicines and other items</h3>
        <ProcurementCatalogue
          businessId={businessId}
          onAdd={(entry) => add([catalogueLine(entry)])}
        />
        <div className="flex flex-wrap items-center gap-3">
          <Button type="button" variant="outline" onClick={() => add([supplyLine()])}>
            Add manual item
          </Button>
          <label className="text-sm">
            Import CSV / Excel
            <Input
              type="file"
              accept=".csv,.xlsx"
              disabled={importBusy}
              onChange={async (e) => {
                const file = e.target.files?.[0];
                e.target.value = "";
                if (!file) return;
                if (file.size > 2_000_000) {
                  toast.error("Use a file smaller than 2 MB.");
                  return;
                }
                setImportBusy(true);
                try {
                  const XLSX = await import("xlsx");
                  const book = XLSX.read(await file.arrayBuffer(), {
                    type: "array",
                    sheetRows: 202,
                  });
                  const parsed = importProcurementRows(
                    XLSX.utils.sheet_to_json(book.Sheets[book.SheetNames[0]], {
                      header: 1,
                      raw: true,
                    }),
                  );
                  const reviewed: ((typeof parsed)[number] & { match?: string })[] = [];
                  for (const row of parsed) {
                    if (row.issue) {
                      reviewed.push(row);
                      continue;
                    }
                    const candidates = await externalRpc<CatalogueEntry[]>(
                      "search_procurement_catalogue",
                      {
                        p_business_id: businessId,
                        p_query: row.line.name.split(" / ")[0],
                        p_scope: "all",
                        p_offset: 0,
                      },
                    );
                    const exact = candidates.filter(
                      (p) =>
                        medicineLabel(p.data).toLowerCase() === row.line.name.toLowerCase() &&
                        (p.data.unit || "packs") === row.line.unit,
                    );
                    if (exact.length === 1)
                      reviewed.push({
                        ...row,
                        line: {
                          ...row.line,
                          catalogue_id: exact[0].id,
                          catalogue_source: exact[0].source,
                          product_snapshot: { ...exact[0].data },
                        },
                        match: "Matched existing medicine",
                      });
                    else
                      reviewed.push({
                        ...row,
                        match: candidates.length
                          ? "Possible duplicate - review catalogue before reuse"
                          : "New medicine snapshot",
                      });
                  }
                  setImported(reviewed);
                  setSaveImportedCatalogue(false);
                } catch (e) {
                  toast.error(e instanceof Error ? e.message : "Import failed");
                } finally {
                  setImportBusy(false);
                }
              }}
            />
          </label>
        </div>
        {imported.length > 0 && (
          <section className="rounded border p-3">
            <h4 className="font-semibold">Import preview - {imported.length} rows</h4>
            <p>
              Review matches and remove invalid rows, or correct the spreadsheet and import again.
              Catalogue creation is optional and private to this business.
            </p>
            <ul className="max-h-40 overflow-y-auto">
              {imported.map((r, i) => (
                <li key={r.line.id} className="flex flex-wrap items-center gap-2 py-1">
                  {i + 1}. {r.line.name} | {r.line.quantity} {r.line.unit} |{" "}
                  {r.issue || r.match || "Unmatched snapshot - review before adding"}
                  <Button
                    type="button"
                    variant="ghost"
                    disabled={importBusy}
                    onClick={() =>
                      setImported((rows) => rows.filter((x) => x.line.id !== r.line.id))
                    }
                  >
                    Remove import row {i + 1}
                  </Button>
                </li>
              ))}
            </ul>
            <label className="my-3 flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                checked={saveImportedCatalogue}
                disabled={importBusy}
                onChange={(e) => setSaveImportedCatalogue(e.target.checked)}
              />
              Save unmatched items in my private catalogue. I have reviewed possible duplicates.
              Medicines require strength, dosage form and pack size.
            </label>
            <Button
              type="button"
              disabled={importBusy || imported.some((r) => !!r.issue)}
              onClick={async () => {
                setImportBusy(true);
                try {
                  const rows = imported.map((r) => ({ ...r, line: { ...r.line } }));
                  if (saveImportedCatalogue) {
                    // Persist one identity at a time; exact database dedup makes retries safe.
                    // Keep every successful ID in the review if a later row fails.
                    for (const row of rows) {
                      if (!row.line.catalogue_id) {
                        row.line.catalogue_id = await externalRpc<string>(
                          "save_procurement_medicine",
                          { p_business_id: businessId, p_data: row.line.product_snapshot },
                        );
                        row.line.catalogue_source = "business";
                        row.match = "Saved private medicine";
                        setImported(rows.map((r) => ({ ...r, line: { ...r.line } })));
                      }
                    }
                  }
                  if (add(rows.map((r) => r.line))) setImported([]);
                } catch (e) {
                  toast.error(
                    e instanceof Error
                      ? e.message
                      : "Import could not be saved. Review retained; retry safely.",
                  );
                } finally {
                  setImportBusy(false);
                }
              }}
            >
              {importBusy ? "Saving imported medicines..." : "Confirm and add imported items"}
            </Button>
            <Button
              type="button"
              variant="ghost"
              disabled={importBusy}
              onClick={() => setImported([])}
            >
              Discard import
            </Button>
          </section>
        )}
        <div
          className="hidden lg:grid grid-cols-[3fr_2fr_1fr_1fr_1fr_1fr_auto] gap-2 border-b p-2 text-sm font-semibold"
          aria-hidden="true"
        >
          <span>Medicine</span>
          <span>Specification</span>
          <span>Quantity</span>
          <span>Unit</span>
          <span>Price GHS</span>
          <span>Total GHS</span>
          <span>Action</span>
        </div>
        <div className="space-y-2">
          {draft.lines.map((l, i) => (
            <fieldset
              key={l.id}
              className="grid gap-2 rounded border p-3 sm:grid-cols-2 lg:grid-cols-[3fr_2fr_1fr_1fr_1fr_1fr_auto]"
            >
              <legend className="text-xs lg:sr-only">Item {i + 1}</legend>
              <label className="min-w-0">
                <span className="text-xs lg:sr-only">Medicine / strength / pack</span>
                <Input
                  aria-label={`Medicine / strength / pack ${i + 1}`}
                  value={l.name}
                  maxLength={300}
                  onChange={(e) => line(l.id, { name: e.target.value })}
                />
              </label>
              <label className="min-w-0">
                <span className="text-xs lg:sr-only">Specification</span>
                <Input
                  aria-label={`Specification ${i + 1}`}
                  value={l.specification}
                  maxLength={1000}
                  onChange={(e) => line(l.id, { specification: e.target.value })}
                />
              </label>
              <label>
                <span className="text-xs lg:sr-only">Quantity</span>
                <Input
                  aria-label={`Quantity ${i + 1}`}
                  type="number"
                  min="1"
                  max="1000000"
                  step="1"
                  value={l.quantity}
                  onChange={(e) => line(l.id, { quantity: Number(e.target.value) })}
                />
              </label>
              <label>
                <span className="text-xs lg:sr-only">Unit</span>
                <select
                  aria-label={`Unit ${i + 1}`}
                  className="h-10 w-full rounded border bg-background"
                  value={l.unit || "packs"}
                  onChange={(e) => line(l.id, { unit: e.target.value })}
                >
                  {PROCUREMENT_UNITS.map((v) => (
                    <option key={v}>{v}</option>
                  ))}
                </select>
              </label>
              <label>
                <span className="text-xs lg:sr-only">
                  {draft.kind === "request"
                    ? "Supplier-visible target GHS (optional)"
                    : "Agreed price GHS"}
                </span>
                <Input
                  aria-label={`Unit price GHS ${i + 1}`}
                  type="number"
                  min="0"
                  step="0.01"
                  value={l.unit_price ?? ""}
                  onChange={(e) =>
                    line(l.id, {
                      unit_price: e.target.value === "" ? null : Number(e.target.value),
                    })
                  }
                />
              </label>
              <output className="self-center text-sm">
                {l.unit_price === null ? "Quote pending" : (lineMinor(l) / 100).toFixed(2)}
              </output>
              <Button
                type="button"
                variant="ghost"
                aria-label={`Remove item ${i + 1}`}
                onClick={() => patch({ lines: draft.lines.filter((x) => x.id !== l.id) })}
              >
                Remove
              </Button>
            </fieldset>
          ))}
        </div>
        {!draft.lines.length && (
          <p>Add medicines now, or save an incomplete draft to continue later.</p>
        )}
        {draft.kind === "request" && (
          <p className="text-sm">
            Leave prices blank to request quotations. Any price entered is a supplier-visible
            target, not an accepted quotation.
          </p>
        )}
        <label className="block">
          3. Instructions / agreed terms
          <textarea
            className="block min-h-20 w-full rounded border bg-background p-2"
            maxLength={2000}
            value={draft.notes}
            onChange={(e) => patch({ notes: e.target.value })}
          />
        </label>
        {preview && (
          <section className="rounded border bg-muted/20 p-4" aria-label="Draft document preview">
            <h3 className="font-semibold">
              DRAFT - {draft.kind === "request" ? "Request for quotation" : "Purchase order"}
            </h3>
            <p>
              {draft.supplier || "Supplier not selected"} | {draft.supplier_contact}
            </p>
            <p>
              {draft.delivery_address} | {draft.required_date || "Delivery date to be agreed"}
            </p>
            {draft.lines.map((l) => (
              <p key={l.id}>
                {l.name || "Incomplete item"} | {l.quantity} {l.unit || "packs"} |{" "}
                {l.unit_price === null ? "Quote requested" : `${l.unit_price.toFixed(2)} GHS`}
              </p>
            ))}
            <p className="whitespace-pre-wrap">{draft.notes}</p>
            <p>Not issued. Save, review and issue from the document detail.</p>
          </section>
        )}
      </fieldset>
      <footer className="sticky bottom-0 z-10 flex flex-wrap items-center justify-between gap-3 border-t bg-background py-3">
        <div>
          <p className="font-semibold">
            {draft.lines.length} items |{" "}
            {draft.lines.some((l) => l.unit_price === null)
              ? "Prices pending"
              : `${(draft.lines.reduce((n, l) => n + lineMinor(l), 0) / 100).toFixed(2)} GHS`}
          </p>
          <p className="text-xs">
            Save before closing or refreshing. Issue after reviewing the saved document.
          </p>
          {saveError && (
            <p role="alert" className="text-destructive">
              {saveError}
            </p>
          )}
        </div>
        <div className="flex gap-2">
          <Button type="button" variant="outline" onClick={() => setPreview((v) => !v)}>
            Preview document
          </Button>
          <Button type="submit" disabled={busy || importBusy || supplierBusy}>
            {busy ? "Saving..." : "Save draft"}
          </Button>
        </div>
      </footer>
    </form>
  );
}
