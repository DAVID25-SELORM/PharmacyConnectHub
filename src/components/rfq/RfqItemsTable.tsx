import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, Search, Snowflake, X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { Requirement } from "@/lib/enterprise-rfq";
import { RFQ_PAGE_SIZES, pageOf } from "@/lib/rfq-lines";

/** Read-only list of an RFQ's requested medicines, searchable and paged so a long request stays readable. */
export function RfqItemsTable({
  items,
  showRemaining,
  remaining,
}: {
  items: Requirement[];
  showRemaining: boolean;
  remaining: (item: Requirement) => number | string;
}) {
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [size, setSize] = useState<number>(RFQ_PAGE_SIZES[0]);

  const term = search.trim().toLowerCase();
  const shown = useMemo(
    () =>
      items
        .map((_, index) => index)
        .filter((index) => !term || items[index].product_name.toLowerCase().includes(term)),
    [items, term],
  );
  const paged = pageOf(shown, page, size);
  const coldChain = items.filter((i) => i.cold_chain_required).length;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="secondary" className="tabular-nums">
          {items.length} medicine{items.length === 1 ? "" : "s"}
        </Badge>
        {coldChain > 0 && (
          <Badge variant="outline" className="gap-1 tabular-nums">
            <Snowflake className="h-3 w-3" /> {coldChain} cold chain
          </Badge>
        )}
        {items.length > size && (
          <div className="relative ml-auto min-w-[200px] sm:max-w-xs sm:flex-1">
            <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
            <Input
              aria-label="Search medicines in this request"
              placeholder="Search medicines"
              className="pl-8 pr-8"
              value={search}
              onChange={(e) => {
                setSearch(e.target.value);
                setPage(0);
              }}
            />
            {search && (
              <button
                type="button"
                aria-label="Clear search"
                className="absolute right-2 top-2.5 text-muted-foreground hover:text-foreground"
                onClick={() => {
                  setSearch("");
                  setPage(0);
                }}
              >
                <X className="h-4 w-4" />
              </button>
            )}
          </div>
        )}
      </div>

      <div className="overflow-hidden rounded-lg border">
        <div className="overflow-x-auto">
          <Table className="min-w-[640px]">
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead className="w-12">#</TableHead>
                <TableHead>Medicine / specification</TableHead>
                <TableHead className="w-32">Requested</TableHead>
                {showRemaining && <TableHead className="w-28">Remaining</TableHead>}
                <TableHead className="w-28">Shelf life</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {paged.rows.length === 0 ? (
                <TableRow>
                  <TableCell
                    colSpan={showRemaining ? 5 : 4}
                    className="py-8 text-center text-sm text-muted-foreground"
                  >
                    {items.length ? "No medicines match your search." : "No medicines."}
                  </TableCell>
                </TableRow>
              ) : (
                paged.rows.map((index) => {
                  const i = items[index];
                  const spec = Object.entries(i.specification ?? {})
                    .filter(([, v]) => v)
                    .map(([k, v]) => `${k}: ${v}`)
                    .join(" · ");
                  return (
                    <TableRow key={i.id}>
                      <TableCell className="align-top text-xs tabular-nums text-muted-foreground">
                        {index + 1}
                      </TableCell>
                      <TableCell className="align-top">
                        <div className="font-medium">{i.product_name}</div>
                        {(spec || i.notes || i.special_handling || i.cold_chain_required) && (
                          <p className="mt-0.5 text-xs text-muted-foreground">
                            {[spec, i.notes].filter(Boolean).join(" ")}
                            {i.special_handling && <span> · Handling: {i.special_handling}</span>}
                          </p>
                        )}
                        {i.cold_chain_required && (
                          <span className="mt-1 inline-flex items-center gap-1 text-xs text-primary">
                            <Snowflake className="h-3 w-3" /> Cold chain required
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="align-top tabular-nums">
                        {i.quantity} {i.unit}
                      </TableCell>
                      {showRemaining && (
                        <TableCell className="align-top tabular-nums">{remaining(i)}</TableCell>
                      )}
                      <TableCell className="align-top tabular-nums">
                        {i.minimum_shelf_life_days} days
                      </TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </div>
        {shown.length > RFQ_PAGE_SIZES[0] || size !== RFQ_PAGE_SIZES[0] ? (
          <div className="flex flex-wrap items-center gap-3 border-t bg-muted/30 px-3 py-2 text-sm">
            <span className="tabular-nums text-muted-foreground">
              {paged.total
                ? `Showing ${paged.from}–${paged.to} of ${paged.total}`
                : "Nothing to show"}
            </span>
            <label className="ml-auto flex items-center gap-2 text-xs text-muted-foreground">
              Rows per page
              <select
                aria-label="Rows per page"
                className="h-8 w-20 rounded-md border border-input bg-background px-2 text-sm"
                value={size}
                onChange={(e) => {
                  setSize(Number(e.target.value));
                  setPage(0);
                }}
              >
                {RFQ_PAGE_SIZES.map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
            </label>
            <div className="flex items-center gap-1">
              <Button
                type="button"
                variant="outline"
                size="icon"
                className="h-8 w-8"
                aria-label="Previous page"
                disabled={paged.page === 0}
                onClick={() => setPage(paged.page - 1)}
              >
                <ChevronLeft className="h-4 w-4" />
              </Button>
              <span className="px-1 text-xs tabular-nums">
                Page {paged.page + 1} of {paged.pageCount}
              </span>
              <Button
                type="button"
                variant="outline"
                size="icon"
                className="h-8 w-8"
                aria-label="Next page"
                disabled={paged.page >= paged.pageCount - 1}
                onClick={() => setPage(paged.page + 1)}
              >
                <ChevronRight className="h-4 w-4" />
              </Button>
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}
