import { useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Search, Star } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { rfqCall } from "@/lib/enterprise-rfq";
import { RFQ_MAX_SUPPLIERS } from "@/lib/rfq-lines";

export type SupplierOption = {
  id: string;
  name: string;
  favourite: boolean;
  matching_catalogue_products: number;
  previous_orders: number;
  delivered_orders: number;
  cancelled_orders: number;
};

const MODES = [
  ["all", "All approved"],
  ["previous", "Bought from before"],
  ["favourites", "Favourites"],
  ["matching", "Match my medicines"],
] as const;
const PAGE = 20;

/** Invitation list for a private RFQ: a searchable table of approved suppliers with selection. */
export function RfqSupplierPicker({
  businessId,
  productIds,
  selected,
  onSelect,
  onError,
  disabled = false,
}: {
  businessId: string;
  /** Comma-joined catalogue ids of the medicines requested, used to find matching suppliers. */
  productIds: string;
  selected: string[];
  onSelect: (ids: string[]) => void;
  onError: (message: string) => void;
  disabled?: boolean;
}) {
  const [rows, setRows] = useState<SupplierOption[]>([]);
  const [mode, setMode] = useState<string>("all");
  const [query, setQuery] = useState("");
  const search = useDebouncedValue(query, 250);
  const [page, setPage] = useState(0);
  const [loading, setLoading] = useState(true);
  const names = useRef(new Map<string, string>());

  useEffect(() => {
    let active = true;
    setLoading(true);
    void rfqCall<SupplierOption[]>("rfq_supplier_options", {
      p_pharmacy_id: businessId,
      p_query: search,
      p_mode: mode,
      p_products: productIds ? productIds.split(",") : [],
      p_offset: page * PAGE,
    })
      .then((data) => {
        if (!active) return;
        data.forEach((s) => names.current.set(s.id, s.name));
        setRows(data);
      })
      .catch((e) => {
        if (active) onError(e.message);
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
    // onError is a stable setter in the parent; refetching on its identity would loop.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [businessId, search, page, mode, productIds]);

  const chosen = new Set(selected);
  const full = selected.length >= RFQ_MAX_SUPPLIERS;
  const pageIds = rows.map((r) => r.id);
  const allOnPage = pageIds.length > 0 && pageIds.every((id) => chosen.has(id));
  const someOnPage = pageIds.some((id) => chosen.has(id));
  const setOne = (id: string, on: boolean) =>
    onSelect(
      on ? (chosen.has(id) ? selected : [...selected, id]) : selected.filter((s) => s !== id),
    );
  const known = selected.filter((id) => names.current.has(id));

  const toggleFavourite = async (s: SupplierOption) => {
    try {
      await rfqCall("set_rfq_favourite", {
        p_pharmacy_id: businessId,
        p_wholesaler_id: s.id,
        p_favourite: !s.favourite,
      });
      setRows((current) =>
        current.map((r) => (r.id === s.id ? { ...r, favourite: !s.favourite } : r)),
      );
    } catch (e) {
      onError((e as Error).message);
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <div
          className="inline-flex rounded-md border bg-muted/40 p-0.5"
          role="tablist"
          aria-label="Which suppliers to list"
        >
          {MODES.map(([value, text]) => (
            <button
              key={value}
              type="button"
              role="tab"
              aria-selected={mode === value}
              onClick={() => {
                setMode(value);
                setPage(0);
              }}
              className={`rounded px-3 py-1.5 text-xs font-medium transition-colors ${
                mode === value
                  ? "bg-background shadow-sm"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              {text}
            </button>
          ))}
        </div>
        <div className="relative min-w-[200px] flex-1 sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            aria-label="Search approved suppliers"
            placeholder="Search approved suppliers"
            className="pl-8"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setPage(0);
            }}
          />
        </div>
        <div className="ml-auto flex items-center gap-2">
          <Badge variant={selected.length ? "default" : "secondary"} className="tabular-nums">
            {selected.length} of {RFQ_MAX_SUPPLIERS} selected
          </Badge>
          {selected.length > 0 && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={disabled}
              onClick={() => onSelect([])}
            >
              Clear
            </Button>
          )}
        </div>
      </div>
      {known.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {known.slice(0, 8).map((id) => (
            <Badge key={id} variant="outline" className="font-normal">
              {names.current.get(id)}
            </Badge>
          ))}
          {selected.length > Math.min(known.length, 8) && (
            <Badge variant="outline" className="font-normal">
              +{selected.length - Math.min(known.length, 8)} more
            </Badge>
          )}
        </div>
      )}

      <div className="overflow-hidden rounded-lg border">
        <div className="overflow-x-auto">
          <Table className="min-w-[640px]">
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead className="w-10">
                  <Checkbox
                    aria-label="Select all suppliers on this page"
                    checked={allOnPage ? true : someOnPage ? "indeterminate" : false}
                    disabled={disabled || !pageIds.length}
                    onCheckedChange={(v) => {
                      if (v === true) {
                        const merged = [...selected];
                        for (const id of pageIds) {
                          if (!chosen.has(id) && merged.length < RFQ_MAX_SUPPLIERS) merged.push(id);
                        }
                        onSelect(merged);
                      } else onSelect(selected.filter((id) => !pageIds.includes(id)));
                    }}
                  />
                </TableHead>
                <TableHead>Supplier</TableHead>
                <TableHead className="w-40">Catalogue matches</TableHead>
                <TableHead className="w-56">Your history with them</TableHead>
                <TableHead className="w-12">
                  <span className="sr-only">Favourite</span>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} className="py-8 text-center text-sm text-muted-foreground">
                    {loading ? "Loading suppliers…" : "No suppliers match this view."}
                  </TableCell>
                </TableRow>
              ) : (
                rows.map((s) => {
                  const on = chosen.has(s.id);
                  return (
                    <TableRow key={s.id} data-state={on ? "selected" : undefined}>
                      <TableCell>
                        <Checkbox
                          aria-label={`Invite ${s.name}`}
                          checked={on}
                          disabled={disabled || (!on && full)}
                          onCheckedChange={(v) => setOne(s.id, v === true)}
                        />
                      </TableCell>
                      <TableCell className="font-medium">{s.name}</TableCell>
                      <TableCell className="tabular-nums text-sm">
                        {s.matching_catalogue_products > 0 ? (
                          s.matching_catalogue_products
                        ) : (
                          <span className="text-muted-foreground">None listed</span>
                        )}
                      </TableCell>
                      <TableCell className="text-sm tabular-nums text-muted-foreground">
                        {s.previous_orders
                          ? `${s.previous_orders} order${s.previous_orders === 1 ? "" : "s"} · ${s.delivered_orders} delivered · ${s.cancelled_orders} cancelled`
                          : "No orders yet"}
                      </TableCell>
                      <TableCell>
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8"
                          aria-label={
                            s.favourite
                              ? `Remove ${s.name} from favourites`
                              : `Add ${s.name} to favourites`
                          }
                          aria-pressed={s.favourite}
                          disabled={disabled}
                          onClick={() => void toggleFavourite(s)}
                        >
                          <Star
                            className={`h-4 w-4 ${s.favourite ? "fill-warning text-warning" : "text-muted-foreground"}`}
                          />
                        </Button>
                      </TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </div>
        <div className="flex items-center gap-2 border-t bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
          <span>
            Catalogue matches show listed products, not guaranteed stock or therapeutic suitability.
          </span>
          <div className="ml-auto flex items-center gap-1">
            <Button
              type="button"
              variant="outline"
              size="icon"
              className="h-8 w-8"
              aria-label="Previous suppliers"
              disabled={!page}
              onClick={() => setPage((p) => p - 1)}
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <span className="px-1 tabular-nums">Page {page + 1}</span>
            <Button
              type="button"
              variant="outline"
              size="icon"
              className="h-8 w-8"
              aria-label="Next suppliers"
              disabled={rows.length < PAGE}
              onClick={() => setPage((p) => p + 1)}
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
      </div>
      {full && (
        <p className="text-xs text-muted-foreground">
          The limit of {RFQ_MAX_SUPPLIERS} suppliers is reached. Clear some to invite others.
        </p>
      )}
    </div>
  );
}
