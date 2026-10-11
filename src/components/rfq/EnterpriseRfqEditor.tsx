import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { MedicationPicker } from "./MedicationPicker";
import { rfqCall, rfqDb, type EnterpriseRfq, type Requirement } from "@/lib/enterprise-rfq";
import { rfqRows, rfqRowIssues } from "@/lib/rfq-bulk";
import { useDebouncedValue } from "@/hooks/use-debounced-value";

type Line = {
  productName: string;
  quantity: string;
  notes: string;
  masterProductId: string | null;
  unit: string;
  shelfLifeDays: number;
  alternativesAllowed: boolean;
  partialAllowed: boolean;
  coldChainRequired: boolean;
  specialHandling: string;
};
const blank = (): Line => ({
  productName: "",
  quantity: "1",
  notes: "",
  masterProductId: null,
  unit: "pack",
  shelfLifeDays: 90,
  alternativesAllowed: false,
  partialAllowed: true,
  coldChainRequired: false,
  specialHandling: "",
});
export function EnterpriseRfqEditor({
  businessId,
  initial,
  repeat,
  onSaved,
  onCancel,
}: {
  businessId: string;
  initial?: EnterpriseRfq;
  repeat?: boolean;
  onSaved: (id: string) => void;
  onCancel: () => void;
}) {
  const [title, setTitle] = useState(
    repeat ? `${initial?.title ?? ""} (repeat)` : (initial?.title ?? ""),
  );
  const [notes, setNotes] = useState(initial?.notes ?? "");
  const [deadline, setDeadline] = useState(
    repeat ? "" : (initial?.response_deadline?.slice(0, 16) ?? ""),
  );
  const [delivery, setDelivery] = useState(repeat ? "" : (initial?.expected_delivery_date ?? ""));
  const [location, setLocation] = useState(initial?.delivery_location ?? "");
  const [instructions, setInstructions] = useState(initial?.delivery_instructions ?? "");
  const [payment, setPayment] = useState(initial?.payment_preference ?? "cod");
  const [visibility, setVisibility] = useState<"private" | "open">(
    repeat ? "private" : (initial?.visibility ?? "private"),
  );
  const [lines, setLines] = useState<Line[]>([blank()]);
  const [selected, setSelected] = useState<string[]>([]);
  const [suppliers, setSuppliers] = useState<
    {
      id: string;
      name: string;
      favourite: boolean;
      matching_catalogue_products: number;
      previous_orders: number;
      delivered_orders: number;
      cancelled_orders: number;
    }[]
  >([]);
  const [supplierMode, setSupplierMode] = useState("all");
  const [history, setHistory] = useState<
    { master_product_id: string; product_name: string; quantity: number }[]
  >([]);
  const [historyPage, setHistoryPage] = useState(0);
  const productIds = lines
    .map((l) => l.masterProductId)
    .filter(Boolean)
    .sort()
    .join(",");
  const [query, setQuery] = useState("");
  const search = useDebouncedValue(query, 250);
  const [page, setPage] = useState(0);
  const [linePage, setLinePage] = useState(0);
  const [preview, setPreview] = useState<Line[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [review, setReview] = useState(false);
  useEffect(() => {
    let active = true;
    void rfqCall<typeof suppliers>("rfq_supplier_options", {
      p_pharmacy_id: businessId,
      p_query: search,
      p_mode: supplierMode,
      p_products: productIds ? productIds.split(",") : [],
      p_offset: page * 20,
    })
      .then((data) => {
        if (active) setSuppliers(data);
      })
      .catch((e) => {
        if (active) setError(e.message);
      });
    return () => {
      active = false;
    };
  }, [businessId, search, page, supplierMode, productIds]);
  useEffect(() => {
    if (!initial) return;
    let active = true;
    void Promise.all([
      rfqDb.from("rfq_items").select("*").eq("rfq_id", initial.id),
      rfqDb.from("rfq_invitees").select("wholesaler_id").eq("rfq_id", initial.id),
    ]).then(([items, invites]) => {
      if (!active) return;
      if (items.error || invites.error) {
        setError((items.error ?? invites.error).message);
        return;
      }
      setLines(
        (items.data as Requirement[]).map((i) => ({
          productName: i.product_name,
          quantity: String(i.quantity),
          notes: i.notes ?? "",
          masterProductId: i.master_product_id,
          unit: i.unit,
          shelfLifeDays: i.minimum_shelf_life_days,
          alternativesAllowed: i.alternatives_allowed,
          partialAllowed: i.partial_allowed,
          coldChainRequired: i.cold_chain_required,
          specialHandling: i.special_handling ?? "",
        })),
      );
      setSelected(invites.data.map((i: { wholesaler_id: string }) => i.wholesaler_id));
    });
    return () => {
      active = false;
    };
  }, [initial]);
  const update = (index: number, patch: Partial<Line>) => {
    setLines((ls) => ls.map((l, i) => (i === index ? { ...l, ...patch } : l)));
    setReview(false);
  };
  const importFile = async (file: File) => {
    setBusy(true);
    setError("");
    try {
      if (!/\.(xlsx|xls|csv|tsv)$/i.test(file.name) || file.size > 5 * 1024 * 1024)
        throw new Error("Use an Excel/CSV file up to 5 MB.");
      const XLSX = await import("xlsx");
      const book = XLSX.read(await file.arrayBuffer());
      const rows = rfqRows(
        XLSX.utils.sheet_to_json(book.Sheets[book.SheetNames[0]], { header: 1 }),
      );
      if (rows.length > 500) throw new Error("Maximum 500 rows per RFQ.");
      const mapped: Line[] = [];
      for (let start = 0; start < rows.length; start += 50) {
        const batch = rows.slice(start, start + 50);
        const { data, error } = await rfqDb
          .from("master_products")
          .select("id,name")
          .eq("active", true)
          .in("name", [...new Set(batch.map((row) => row.productName))]);
        if (error) throw new Error(error.message);
        for (const row of batch) {
          const matches = (data as { id: string; name: string }[]).filter(
            (p) => p.name === row.productName,
          );
          mapped.push({
            ...blank(),
            ...row,
            masterProductId: matches.length === 1 ? matches[0].id : null,
            notes: [
              row.notes,
              matches.length > 1
                ? "Ambiguous catalogue name: choose the exact strength/form/pack."
                : matches.length === 0
                  ? "Unmatched catalogue name: review identity."
                  : "",
            ]
              .filter(Boolean)
              .join(" "),
          });
        }
      }
      setPreview(mapped);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const save = async () => {
    setError("");
    if (!title.trim() || rfqRowIssues(lines).size) {
      setError("Enter a title and resolve empty, duplicate or invalid medicine rows.");
      return;
    }
    setBusy(true);
    try {
      const id = await rfqCall<string>("save_enterprise_rfq", {
        p_pharmacy_id: businessId,
        p_request_id: crypto.randomUUID(),
        p_rfq_id: repeat ? null : (initial?.id ?? null),
        p_revision: repeat ? null : (initial?.revision ?? null),
        p_payload: {
          title,
          notes,
          deadline: deadline ? new Date(deadline).toISOString() : null,
          expectedDelivery: delivery || null,
          deliveryLocation: location,
          deliveryInstructions: instructions,
          paymentPreference: payment,
          visibility,
          items: lines,
          suppliers: visibility === "private" ? selected : [],
        },
      });
      onSaved(id);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="space-y-4 rounded-xl border p-4">
      <h2 className="text-xl font-semibold">
        {repeat ? "Repeat RFQ" : initial ? "Edit draft" : "Create RFQ"}
      </h2>
      <p className="text-sm text-muted-foreground">
        Save a private draft, review it, then publish invitations. Repeat requests use new deadlines
        and carry no quotes or awards.
      </p>
      <fieldset disabled={busy || review} className="space-y-4">
        <label className="block">
          Title
          <Input value={title} onChange={(e) => setTitle(e.target.value)} />
        </label>
        <label className="block">
          Description
          <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} />
        </label>
        <div className="grid gap-3 sm:grid-cols-2">
          <label>
            Quotation deadline
            <Input
              type="datetime-local"
              value={deadline}
              onChange={(e) => setDeadline(e.target.value)}
            />
          </label>
          <label>
            Expected delivery
            <Input type="date" value={delivery} onChange={(e) => setDelivery(e.target.value)} />
          </label>
          <label>
            Delivery location within this pharmacy
            <Input value={location} onChange={(e) => setLocation(e.target.value)} />
          </label>
          <label>
            Payment preference
            <select
              className="block w-full rounded border p-2"
              value={payment}
              onChange={(e) => setPayment(e.target.value)}
            >
              {["cod", "credit", "bank_transfer", "momo", "cheque", "other"].map((p) => (
                <option key={p}>{p}</option>
              ))}
            </select>
          </label>
        </div>
        <label className="block">
          Delivery and special handling instructions
          <Textarea value={instructions} onChange={(e) => setInstructions(e.target.value)} />
        </label>
        <label className="block">
          Supplier access
          <select
            className="block w-full rounded border p-2"
            value={visibility}
            onChange={(e) => setVisibility(e.target.value as "private" | "open")}
          >
            <option value="private">Private invitations (recommended)</option>
            <option value="open">Open to approved wholesalers until deadline</option>
          </select>
          <span className="text-xs text-muted-foreground">
            Open RFQs are visible to approved wholesalers. Each supplier sees only its own response
            and quotations.
          </span>
        </label>
        <label className="block">
          Import medicine requirements
          <Input
            type="file"
            accept=".xlsx,.xls,.csv,.tsv"
            onChange={(e) => {
              if (e.target.files?.[0]) void importFile(e.target.files[0]);
              e.target.value = "";
            }}
          />
        </label>
        <details className="rounded border p-3">
          <summary>Choose previously purchased medicines</summary>
          <Button
            variant="outline"
            onClick={async () => {
              try {
                setHistory(
                  await rfqCall("rfq_purchase_history", {
                    p_pharmacy_id: businessId,
                    p_offset: historyPage * 25,
                  }),
                );
              } catch (e) {
                setError((e as Error).message);
              }
            }}
          >
            Load purchase history page {historyPage + 1}
          </Button>
          {history.map((h, i) => (
            <Button
              key={`${h.master_product_id}:${i}`}
              variant="ghost"
              onClick={() =>
                setLines((ls) => [
                  ...ls.filter((l) => l.productName.trim()),
                  {
                    ...blank(),
                    productName: h.product_name,
                    masterProductId: h.master_product_id,
                    quantity: "1",
                  },
                ])
              }
            >
              Add {h.product_name}
            </Button>
          ))}
          <Button
            variant="outline"
            disabled={!historyPage}
            onClick={() => setHistoryPage((p) => p - 1)}
          >
            Previous history page
          </Button>
          <Button variant="outline" onClick={() => setHistoryPage((p) => p + 1)}>
            Next history page
          </Button>
        </details>
        {preview && (
          <div className="rounded border p-3">
            <p>
              Import preview: {preview.length} rows. Catalogue identities need review; no
              substitutions are inferred.
            </p>
            <ul className="max-h-48 overflow-auto">
              {preview.map((l, i) => (
                <li key={i}>
                  {l.productName} × {l.quantity}
                </li>
              ))}
            </ul>
            <Button
              onClick={() => {
                setLines((ls) => [...ls.filter((l) => l.productName.trim()), ...preview]);
                setPreview(null);
              }}
            >
              Add preview to editable draft
            </Button>
            <Button variant="ghost" onClick={() => setPreview(null)}>
              Discard import
            </Button>
          </div>
        )}
        <h3 className="font-semibold">Medicines ({lines.length})</h3>
        {lines.slice(linePage * 20, linePage * 20 + 20).map((line, offset) => {
          const index = linePage * 20 + offset;
          return (
            <div key={index} className="space-y-2 rounded border p-3">
              <MedicationPicker
                value={line.productName}
                onChange={(productName) => update(index, { productName, masterProductId: null })}
                onSelect={(p) => update(index, { masterProductId: p.id })}
              />
              <p className="text-xs text-muted-foreground">
                {line.masterProductId
                  ? "Catalogue identity selected"
                  : "Unmatched medicine: select a catalogue identity or explicitly permit alternative proposals."}
              </p>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                <label>
                  Quantity
                  <Input
                    type="number"
                    min="1"
                    step="1"
                    value={line.quantity}
                    onChange={(e) => update(index, { quantity: e.target.value })}
                  />
                </label>
                <label>
                  Unit
                  <select
                    className="block w-full rounded border p-2"
                    value={line.unit}
                    onChange={(e) => update(index, { unit: e.target.value })}
                  >
                    {["pack", "box", "bottle", "unit", "carton"].map((u) => (
                      <option key={u}>{u}</option>
                    ))}
                  </select>
                </label>
                <label>
                  Minimum shelf life (days)
                  <Input
                    type="number"
                    min="0"
                    value={line.shelfLifeDays}
                    onChange={(e) => update(index, { shelfLifeDays: Number(e.target.value) })}
                  />
                </label>
                <Button
                  variant="ghost"
                  onClick={() => setLines((ls) => ls.filter((_, i) => i !== index))}
                >
                  Remove
                </Button>
              </div>
              <label className="mr-4 inline-flex gap-2">
                <input
                  type="checkbox"
                  checked={line.alternativesAllowed}
                  onChange={(e) => update(index, { alternativesAllowed: e.target.checked })}
                />
                Allow alternatives
              </label>
              <label className="inline-flex gap-2">
                <input
                  type="checkbox"
                  checked={line.partialAllowed}
                  onChange={(e) => update(index, { partialAllowed: e.target.checked })}
                />
                Allow partial supply
              </label>
              <label className="inline-flex gap-2">
                <input
                  type="checkbox"
                  checked={line.coldChainRequired}
                  onChange={(e) => update(index, { coldChainRequired: e.target.checked })}
                />
                Cold chain required
              </label>
              <Input
                aria-label="Special handling requirement"
                placeholder="Required storage or handling"
                value={line.specialHandling}
                onChange={(e) => update(index, { specialHandling: e.target.value })}
              />
              <Input
                aria-label="Medicine notes"
                placeholder="Brand, strength, pack or handling notes"
                value={line.notes}
                onChange={(e) => update(index, { notes: e.target.value })}
              />
            </div>
          );
        })}
        <div className="flex flex-wrap gap-2">
          <Button
            variant="outline"
            disabled={linePage === 0}
            onClick={() => setLinePage((p) => p - 1)}
          >
            Previous medicines
          </Button>
          <Button
            variant="outline"
            disabled={(linePage + 1) * 20 >= lines.length}
            onClick={() => setLinePage((p) => p + 1)}
          >
            Next medicines
          </Button>
          <Button
            variant="outline"
            disabled={lines.length >= 500}
            onClick={() => {
              setLinePage(Math.floor(lines.length / 20));
              setLines((ls) => [...ls, blank()]);
            }}
          >
            Add medicine
          </Button>
        </div>
        {visibility === "private" && (
          <h3 className="font-semibold">Private invitations ({selected.length} selected)</h3>
        )}
        {visibility === "private" && (
          <>
            <select
              aria-label="Supplier selection method"
              className="rounded border p-2"
              value={supplierMode}
              onChange={(e) => {
                setSupplierMode(e.target.value);
                setPage(0);
              }}
            >
              <option value="all">All approved suppliers</option>
              <option value="previous">Previously purchased from</option>
              <option value="favourites">Favourite suppliers</option>
              <option value="matching">Matching active catalogue medicines</option>
            </select>
            <p className="text-xs">
              Catalogue matches indicate listed products, not guaranteed stock or therapeutic
              suitability.
            </p>
            <Input
              placeholder="Search approved suppliers"
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setPage(0);
              }}
            />
            <div className="grid gap-2 sm:grid-cols-2">
              {suppliers.map((s) => (
                <label key={s.id} className="flex gap-2 rounded border p-2">
                  <input
                    type="checkbox"
                    checked={selected.includes(s.id)}
                    onChange={(e) =>
                      setSelected((ids) =>
                        e.target.checked ? [...ids, s.id] : ids.filter((id) => id !== s.id),
                      )
                    }
                  />
                  {s.name}
                  <span className="text-xs">{s.matching_catalogue_products} catalogue matches</span>
                  <span className="text-xs">
                    Past orders {s.previous_orders} · delivered {s.delivered_orders} · cancelled{" "}
                    {s.cancelled_orders}
                  </span>
                  <button
                    type="button"
                    className="text-xs underline"
                    onClick={async (e) => {
                      e.preventDefault();
                      try {
                        await rfqCall("set_rfq_favourite", {
                          p_pharmacy_id: businessId,
                          p_wholesaler_id: s.id,
                          p_favourite: !s.favourite,
                        });
                        setSuppliers((rows) =>
                          rows.map((row) =>
                            row.id === s.id ? { ...row, favourite: !s.favourite } : row,
                          ),
                        );
                      } catch (err) {
                        setError((err as Error).message);
                      }
                    }}
                  >
                    {s.favourite ? "Unfavourite" : "Favourite"}
                  </button>
                </label>
              ))}
            </div>
            <div className="flex gap-2">
              <Button variant="outline" disabled={!page} onClick={() => setPage((p) => p - 1)}>
                Previous suppliers
              </Button>
              <Button
                variant="outline"
                disabled={suppliers.length < 20}
                onClick={() => setPage((p) => p + 1)}
              >
                Next suppliers
              </Button>
            </div>
          </>
        )}
      </fieldset>
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
      {review && (
        <p className="rounded border p-3">
          Review: {title}, {lines.length} medicines, {selected.length} suppliers. This saves a
          draft; publication is a separate action.
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        <Button disabled={busy} onClick={() => (review ? void save() : setReview(true))}>
          {busy ? "Saving…" : review ? "Confirm and save draft" : "Review draft"}
        </Button>
        {review && (
          <Button variant="outline" onClick={() => setReview(false)}>
            Back to edit
          </Button>
        )}
        <Button variant="ghost" disabled={busy} onClick={onCancel}>
          Close
        </Button>
      </div>
    </section>
  );
}
