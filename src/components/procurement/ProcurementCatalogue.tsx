import { useEffect, useId, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { db, externalRpc } from "@/lib/external-procurement";
import {
  emptyMedicine,
  medicineLabel,
  PROCUREMENT_UNITS,
  type CatalogueData,
  type CatalogueEntry,
} from "@/lib/procurement-catalogue";
export function ProcurementCatalogue({
  businessId,
  onAdd,
}: {
  businessId: string;
  onAdd: (entry: CatalogueEntry) => void;
}) {
  const [query, setQuery] = useState("");
  const term = useDebouncedValue(query, 250);
  const [scope, setScope] = useState("all"),
    [offset, setOffset] = useState(0),
    [entries, setEntries] = useState<CatalogueEntry[]>([]),
    [loading, setLoading] = useState(false),
    [error, setError] = useState(""),
    [revision, setRevision] = useState(0);
  const [active, setActive] = useState(0),
    [open, setOpen] = useState(true);
  const listId = useId();
  const [edit, setEdit] = useState<CatalogueData | null>(null),
    [original, setOriginal] = useState<CatalogueEntry | null>(null),
    [busy, setBusy] = useState(false),
    [duplicates, setDuplicates] = useState<CatalogueEntry[]>([]),
    [reviewed, setReviewed] = useState(false);
  const highlight = (value: string) => {
    const index = value.toLowerCase().indexOf(term.trim().toLowerCase());
    return !term.trim() || index < 0 ? (
      value
    ) : (
      <>
        {value.slice(0, index)}
        <mark>{value.slice(index, index + term.trim().length)}</mark>
        {value.slice(index + term.trim().length)}
      </>
    );
  };
  useEffect(() => {
    let live = true;
    setLoading(true);
    setError("");
    if (term.trim().length === 1) {
      setEntries([]);
      setLoading(false);
      return;
    }
    externalRpc<CatalogueEntry[]>("search_procurement_catalogue", {
      p_business_id: businessId,
      p_query: term,
      p_scope: scope,
      p_offset: offset,
    })
      .then((data) => {
        if (live) {
          setEntries(data);
          setActive(0);
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
  }, [businessId, term, scope, offset, revision]);
  const choose = (entry: CatalogueEntry) => {
    if (entry.archived || loading || query !== term) return;
    onAdd(entry);
    toast.success("Medicine added to this draft.");
  };
  const begin = (entry?: CatalogueEntry) => {
    setOriginal(entry ?? null);
    setEdit(entry ? { ...emptyMedicine(), ...entry.data } : emptyMedicine());
    setDuplicates([]);
    setReviewed(false);
  };
  async function save(archive = false) {
    if (!edit) return;
    setBusy(true);
    try {
      if (!original && !reviewed) {
        const matches = await externalRpc<CatalogueEntry[]>("search_procurement_catalogue", {
          p_business_id: businessId,
          p_query: edit.name,
          p_scope: "all",
          p_offset: 0,
        });
        if (matches.length) {
          setDuplicates(matches);
          setReviewed(true);
          return;
        }
      }
      const id = await externalRpc<string>("save_procurement_medicine", {
        p_business_id: businessId,
        p_data: edit,
        p_id: original?.id ?? null,
        p_version: original?.version ?? null,
        p_archived: archive,
      });
      const { data: saved, error: readError } = await db
        .from("business_procurement_catalogue")
        .select("id,data,version,archived")
        .eq("business_id", businessId)
        .eq("id", id)
        .single();
      if (readError)
        throw new Error(
          `Medicine saved, but could not reload it: ${readError.message}. Find it in the business catalogue.`,
        );
      if (!archive && !original && saved) onAdd({ ...saved, source: "business" } as CatalogueEntry);
      setEdit(null);
      setRevision((x) => x + 1);
      toast.success(
        archive
          ? "Catalogue entry archived; issued documents are unchanged."
          : "Catalogue entry saved for this business.",
      );
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="space-y-3 rounded-lg border p-3" aria-label="Medicine catalogue">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-semibold">Find medicines</h3>
        <Button type="button" variant="outline" onClick={() => begin()}>
          Add new medicine
        </Button>
      </div>
      <div className="grid gap-2 sm:grid-cols-[1fr_auto]">
        <Input
          role="combobox"
          aria-label="Search medicines"
          aria-expanded={open}
          aria-controls={listId}
          aria-activedescendant={open && entries[active] ? `${listId}-${active}` : undefined}
          placeholder="Name, generic, strength, ingredient, alias or code"
          value={query}
          onFocus={() => setOpen(true)}
          onChange={(e) => {
            setQuery(e.target.value);
            setOffset(0);
            setOpen(true);
          }}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              setOpen(false);
              e.preventDefault();
            }
            if (e.key === "ArrowDown" || e.key === "ArrowUp") {
              e.preventDefault();
              setActive((i) =>
                Math.max(0, Math.min(19, entries.length - 1, i + (e.key === "ArrowDown" ? 1 : -1))),
              );
            }
            if (e.key === "Enter") {
              e.preventDefault();
              if (open && entries[active]) choose(entries[active]);
            }
          }}
        />
        <select
          aria-label="Catalogue source"
          className="rounded border bg-background p-2"
          value={scope}
          onChange={(e) => {
            setScope(e.target.value);
            setOffset(0);
            setOpen(true);
          }}
        >
          {[
            ["all", "All accessible"],
            ["business", "Business catalogue"],
            ["recent", "Recent medicines"],
            ["frequent", "Frequently used"],
            ["archived", "Archived entries"],
          ].map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </select>
      </div>
      {error && (
        <p role="alert">
          {error}{" "}
          <Button type="button" variant="outline" onClick={() => setRevision((x) => x + 1)}>
            Retry
          </Button>
        </p>
      )}
      {loading && <p role="status">Searching catalogue...</p>}
      {open && !loading && (
        <>
          <ul
            id={listId}
            role="listbox"
            aria-label="Medicine search results"
            className="max-h-52 overflow-y-auto divide-y"
          >
            {entries.slice(0, 20).map((entry, index) => (
              <li
                key={`${entry.source}-${entry.id}`}
                id={`${listId}-${index}`}
                role="option"
                aria-selected={index === active}
                className={`flex flex-wrap items-center justify-between gap-2 p-2 ${index === active ? "bg-muted" : ""}`}
              >
                <div className="min-w-0 flex-1">
                  <p className="font-medium break-words">{highlight(medicineLabel(entry.data))}</p>
                  <p className="text-xs text-muted-foreground">
                    {highlight(
                      [entry.data.generic_name, entry.data.brand_name].filter(Boolean).join(" / "),
                    )}{" "}
                    |{" "}
                    {entry.source === "business"
                      ? "Private business catalogue - unverified"
                      : "Master catalogue"}
                  </p>
                </div>
                <Button
                  type="button"
                  size="sm"
                  disabled={entry.archived || loading || query !== term}
                  onClick={() => choose(entry)}
                >
                  Add
                </Button>
                {entry.source === "business" && (
                  <Button type="button" size="sm" variant="ghost" onClick={() => begin(entry)}>
                    Edit
                  </Button>
                )}
              </li>
            ))}
          </ul>
          {!entries.length && !error && (
            <p>
              {term.trim().length === 1
                ? "Type at least two characters, or clear to browse."
                : "No matches. Add a private medicine or change your search."}
            </p>
          )}
          <div className="flex gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={!offset}
              onClick={() => setOffset((x) => Math.max(0, x - 20))}
            >
              Previous results
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={entries.length < 21}
              onClick={() => setOffset((x) => x + 20)}
            >
              More results
            </Button>
          </div>
        </>
      )}
      <Dialog
        open={!!edit}
        onOpenChange={(v) => {
          if (!v && !busy) setEdit(null);
        }}
      >
        <DialogContent className="max-h-[85dvh] overflow-y-auto sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle>
              {original ? "Maintain saved medicine" : "Add private medicine"}
            </DialogTitle>
            <DialogDescription>
              This saves a catalogue identity for your business, not stock or a verified global
              listing.
            </DialogDescription>
          </DialogHeader>
          {edit && (
            <div className="space-y-3">
              <div className="grid gap-3 sm:grid-cols-2">
                <label>
                  Category
                  <select
                    className="block w-full rounded border p-2"
                    value={edit.category}
                    onChange={(e) => setEdit({ ...edit, category: e.target.value })}
                  >
                    {["medicine", "consumable", "equipment", "other"].map((v) => (
                      <option key={v}>{v}</option>
                    ))}
                  </select>
                </label>
                <label>
                  Quantity unit
                  <select
                    className="block w-full rounded border p-2"
                    value={edit.unit}
                    onChange={(e) => setEdit({ ...edit, unit: e.target.value })}
                  >
                    {PROCUREMENT_UNITS.map((v) => (
                      <option key={v}>{v}</option>
                    ))}
                  </select>
                </label>
                {(
                  [
                    "name",
                    "strength",
                    "dosage_form",
                    "pack_size",
                    "brand_name",
                    "generic_name",
                    "manufacturer",
                    "ingredients",
                    "product_code",
                    "aliases",
                    "notes",
                  ] as const
                ).map((key) => (
                  <label key={key} className="text-sm">
                    {key.replaceAll("_", " ")}
                    <Input
                      maxLength={key === "notes" ? 1000 : 300}
                      value={edit[key]}
                      onChange={(e) => {
                        setEdit({ ...edit, [key]: e.target.value });
                        setReviewed(false);
                        setDuplicates([]);
                      }}
                    />
                  </label>
                ))}
              </div>
              {duplicates.length > 0 && (
                <div className="rounded border p-3">
                  <h4 className="font-semibold">
                    Possible existing medicine - compare strength and presentation
                  </h4>
                  {duplicates.slice(0, 5).map((p) => (
                    <div key={p.id} className="py-2">
                      {medicineLabel(p.data)}{" "}
                      <Button
                        type="button"
                        variant="outline"
                        onClick={() => {
                          choose(p);
                          setEdit(null);
                        }}
                      >
                        Use existing medicine
                      </Button>
                    </div>
                  ))}
                  <p>
                    Save again only if this is a distinct product. Exact private identities reuse
                    the existing entry.
                  </p>
                </div>
              )}
              <div className="flex flex-wrap gap-2">
                <Button type="button" disabled={busy} onClick={() => void save(false)}>
                  {busy
                    ? "Saving..."
                    : original
                      ? "Save catalogue changes"
                      : reviewed
                        ? "Save distinct item"
                        : "Save medicine and add"}
                </Button>
                {original && (
                  <Button
                    type="button"
                    variant="outline"
                    disabled={busy || original.archived}
                    onClick={() => void save(true)}
                  >
                    Archive entry
                  </Button>
                )}
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>
    </section>
  );
}
