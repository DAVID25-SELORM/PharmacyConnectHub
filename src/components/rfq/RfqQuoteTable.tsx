import { memo, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  Minus,
  Search,
  SlidersHorizontal,
  Snowflake,
  X,
} from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
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
import {
  applyToDraft,
  fillPrices,
  isQuoted,
  offerFullQuantity,
  stopQuoting,
  summarizeQuote,
  visibleQuoteIndices,
  type DraftLine,
  type QuoteFilter,
} from "@/lib/rfq-quote-lines";
import { QuoteProductCombobox, type OfferedProduct } from "./QuoteProductCombobox";
import { TablePager } from "./TablePager";

type RowProps = {
  line: DraftLine;
  item: Requirement;
  position: number;
  issue?: string;
  product?: OfferedProduct;
  checked: boolean;
  disabled: boolean;
  businessId: string;
  onUpdate: (id: string, patch: Partial<DraftLine>) => void;
  onPick: (id: string, product: OfferedProduct | null) => void;
  onToggle: (id: string, on: boolean) => void;
};

const Row = memo(function Row({
  line,
  item,
  position,
  issue,
  product,
  checked,
  disabled,
  businessId,
  onUpdate,
  onPick,
  onToggle,
}: RowProps) {
  const quoted = isQuoted(line);
  const spec = Object.entries(item.specification ?? {})
    .filter(([, v]) => v)
    .map(([k, v]) => `${k}: ${v}`)
    .join(" · ");
  const extras = [
    line.alternative && "Alternative",
    line.coldChainSupported && "Cold chain",
    line.batchNumber.trim() && "Batch",
    (line.notes.trim() || line.specialHandling.trim() || line.expectedAvailableOn) && "Notes",
  ].filter(Boolean) as string[];
  const patch = (p: Partial<DraftLine>) => onUpdate(line.rfqItemId, p);
  return (
    <TableRow
      data-state={checked ? "selected" : undefined}
      className={issue ? "bg-destructive/5" : undefined}
    >
      <TableCell className="w-10 align-top">
        <Checkbox
          aria-label={`Select line ${position}`}
          checked={checked}
          disabled={disabled}
          onCheckedChange={(v) => onToggle(line.rfqItemId, v === true)}
        />
      </TableCell>
      <TableCell className="w-10 align-top pt-4 text-xs tabular-nums text-muted-foreground">
        {position}
      </TableCell>
      <TableCell className="align-top">
        <div className="flex items-start gap-2">
          <span className="pt-0.5">
            {issue ? (
              <AlertTriangle className="h-4 w-4 text-destructive" aria-label="Needs attention" />
            ) : quoted ? (
              <CheckCircle2 className="h-4 w-4 text-success" aria-label="Ready to quote" />
            ) : (
              <Minus className="h-4 w-4 text-muted-foreground" aria-label="Not quoting" />
            )}
          </span>
          <div className="min-w-0">
            <div className="font-medium leading-snug">{item.product_name}</div>
            <p className="text-xs text-muted-foreground">
              Requested {item.quantity} {item.unit} · {item.minimum_shelf_life_days} days shelf life
              {spec ? ` · ${spec}` : ""}
            </p>
            <div className="mt-1 flex flex-wrap gap-1">
              {item.cold_chain_required && (
                <Badge variant="outline" className="gap-1 px-1.5 py-0 text-[10px] font-medium">
                  <Snowflake className="h-3 w-3" /> Cold chain
                </Badge>
              )}
              {!item.partial_allowed && (
                <Badge variant="outline" className="px-1.5 py-0 text-[10px] font-medium">
                  Full quantity only
                </Badge>
              )}
              {item.alternatives_allowed && (
                <Badge variant="outline" className="px-1.5 py-0 text-[10px] font-medium">
                  Alternatives allowed
                </Badge>
              )}
            </div>
            {item.special_handling && (
              <p className="mt-1 text-xs text-muted-foreground">
                Handling: {item.special_handling}
              </p>
            )}
            {issue && <p className="mt-1 text-xs text-destructive">{issue}</p>}
          </div>
        </div>
      </TableCell>
      <TableCell className="align-top">
        <QuoteProductCombobox
          businessId={businessId}
          hasValue={quoted}
          selected={product}
          disabled={disabled}
          label={`Your product for line ${position}`}
          onPick={(p) => onPick(line.rfqItemId, p)}
        />
      </TableCell>
      {quoted ? (
        <>
          <TableCell className="w-20 align-top">
            <Input
              aria-label={`Offered units for line ${position}`}
              type="number"
              min="1"
              step="1"
              inputMode="numeric"
              className="tabular-nums"
              value={line.quantity}
              disabled={disabled}
              onChange={(e) => patch({ quantity: e.target.value })}
            />
          </TableCell>
          <TableCell className="w-28 align-top">
            <Input
              aria-label={`Unit price in GHS for line ${position}`}
              type="number"
              min="0.01"
              step="0.01"
              inputMode="decimal"
              className="tabular-nums"
              value={line.unitPriceGhs}
              disabled={disabled}
              onChange={(e) => patch({ unitPriceGhs: e.target.value })}
            />
          </TableCell>
          <TableCell className="w-20 align-top">
            <Input
              aria-label={`Discount percent for line ${position}`}
              type="number"
              min="0"
              max="99.99"
              step="0.01"
              inputMode="decimal"
              className="tabular-nums"
              value={line.discountPercent}
              disabled={disabled}
              onChange={(e) => patch({ discountPercent: e.target.value })}
            />
          </TableCell>
          <TableCell className="w-36 align-top">
            <Input
              aria-label={`Expiry date for line ${position}`}
              type="date"
              value={line.expiryDate}
              disabled={disabled}
              onChange={(e) => patch({ expiryDate: e.target.value })}
            />
          </TableCell>
          <TableCell className="w-32 align-top">
            <Popover>
              <PopoverTrigger asChild>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-9 w-full justify-start gap-2 font-normal"
                  disabled={disabled}
                  aria-label={`Details for line ${position}`}
                >
                  <SlidersHorizontal className="h-3.5 w-3.5 shrink-0" />
                  <span className="truncate text-xs">
                    {extras.length ? extras.join(" · ") : "Details"}
                  </span>
                </Button>
              </PopoverTrigger>
              <PopoverContent align="end" className="w-96 space-y-3">
                <p className="text-sm font-medium">Line {position} details</p>
                <label className="flex items-start gap-2 text-sm">
                  <Checkbox
                    className="mt-0.5"
                    disabled={!item.alternatives_allowed}
                    checked={line.alternative}
                    onCheckedChange={(v) => patch({ alternative: v === true })}
                  />
                  <span>
                    Explicit alternative proposal
                    <span className="block text-xs text-muted-foreground">
                      {item.alternatives_allowed
                        ? "Needs the buyer's acceptance. No therapeutic equivalence is inferred."
                        : "The buyer does not allow alternatives on this line."}
                    </span>
                  </span>
                </label>
                {line.alternative && (
                  <label className="block space-y-1 text-sm">
                    <span className="text-muted-foreground">
                      Requested units supplied by one offered unit
                    </span>
                    <Input
                      type="number"
                      min="0.001"
                      step="0.001"
                      value={line.conversion}
                      onChange={(e) => patch({ conversion: e.target.value })}
                    />
                  </label>
                )}
                <div className="grid grid-cols-2 gap-3">
                  <label className="block space-y-1 text-sm">
                    <span className="text-muted-foreground">Batch / lot number</span>
                    <Input
                      value={line.batchNumber}
                      onChange={(e) => patch({ batchNumber: e.target.value })}
                    />
                  </label>
                  <label className="block space-y-1 text-sm">
                    <span className="text-muted-foreground">Expected available on</span>
                    <Input
                      type="date"
                      value={line.expectedAvailableOn}
                      onChange={(e) => patch({ expectedAvailableOn: e.target.value })}
                    />
                  </label>
                </div>
                <label className="flex items-center gap-2 text-sm">
                  <Checkbox
                    checked={line.coldChainSupported}
                    onCheckedChange={(v) => patch({ coldChainSupported: v === true })}
                  />
                  Cold chain confirmed{item.cold_chain_required ? " (required)" : ""}
                </label>
                <label className="block space-y-1 text-sm">
                  <span className="text-muted-foreground">Special handling offered</span>
                  <Input
                    value={line.specialHandling}
                    onChange={(e) => patch({ specialHandling: e.target.value })}
                  />
                </label>
                <label className="block space-y-1 text-sm">
                  <span className="text-muted-foreground">Notes for the buyer</span>
                  <Input
                    placeholder="Availability, batch or handling notes"
                    value={line.notes}
                    onChange={(e) => patch({ notes: e.target.value })}
                  />
                </label>
                {product && (
                  <p className="text-xs text-muted-foreground">
                    {product.stock} in stock now. Stock is a snapshot at submission, not a
                    reservation.
                  </p>
                )}
              </PopoverContent>
            </Popover>
          </TableCell>
        </>
      ) : (
        <TableCell colSpan={5} className="align-top pt-4 text-xs text-muted-foreground">
          Not quoting this line. Choose your product to quote it.
        </TableCell>
      )}
    </TableRow>
  );
});

const selectBase =
  "h-9 rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-50";

/** The supplier's quotation lines: one row per requested medicine, with search, filters, paging and bulk actions. */
export function RfqQuoteTable({
  businessId,
  items,
  lines,
  onChange,
  issues,
  products,
  onProducts,
  orderDiscountPercent,
  disabled = false,
  tools,
}: {
  businessId: string;
  items: Requirement[];
  lines: DraftLine[];
  /** Accepts a new list or an update of the latest one, like a React state setter. */
  onChange: (next: DraftLine[] | ((current: DraftLine[]) => DraftLine[])) => void;
  issues: Map<string, string>;
  /** Names of chosen products, looked up by the parent. */
  products: Map<string, OfferedProduct>;
  onProducts: (found: OfferedProduct[]) => void;
  orderDiscountPercent: number;
  disabled?: boolean;
  tools?: ReactNode;
}) {
  const itemMap = useMemo(() => new Map(items.map((i) => [i.id, i])), [items]);
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<QuoteFilter>("all");
  const [page, setPage] = useState(0);
  const [size, setSize] = useState<number>(RFQ_PAGE_SIZES[0]);
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set());
  const [confirmStop, setConfirmStop] = useState(false);
  const [bulkDiscount, setBulkDiscount] = useState("0");
  const [bulkExpiry, setBulkExpiry] = useState("");

  const linesRef = useRef(lines);
  linesRef.current = lines;
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const onProductsRef = useRef(onProducts);
  onProductsRef.current = onProducts;

  const view = useMemo(
    () => visibleQuoteIndices(lines, itemMap, issues, { search, filter }),
    [lines, itemMap, issues, search, filter],
  );
  const paged = pageOf(view, page, size);
  const stats = summarizeQuote(lines, issues, orderDiscountPercent);

  useEffect(() => {
    setSelected((current) => {
      if (!current.size) return current;
      const live = new Set(lines.map((l) => l.rfqItemId));
      const next = new Set([...current].filter((id) => live.has(id)));
      return next.size === current.size ? current : next;
    });
  }, [lines]);

  const update = useCallback((id: string, patch: Partial<DraftLine>) => {
    onChangeRef.current(linesRef.current.map((l) => (l.rfqItemId === id ? { ...l, ...patch } : l)));
  }, []);
  const pick = useCallback((id: string, product: OfferedProduct | null) => {
    if (product) onProductsRef.current([product]);
    onChangeRef.current(
      linesRef.current.map((l) =>
        l.rfqItemId === id ? { ...l, productId: product?.id ?? "" } : l,
      ),
    );
  }, []);
  const toggle = useCallback((id: string, on: boolean) => {
    setSelected((current) => {
      const next = new Set(current);
      if (on) next.add(id);
      else next.delete(id);
      return next;
    });
  }, []);

  const pageIds = paged.rows.map((i) => lines[i].rfqItemId);
  const allOnPage = pageIds.length > 0 && pageIds.every((id) => selected.has(id));
  const someOnPage = pageIds.some((id) => selected.has(id));
  const allMatching = view.length > 0 && view.every((i) => selected.has(lines[i].rfqItemId));
  // Bulk actions always start from the latest list, never from what an earlier render captured.
  const quotedSelection = (current: DraftLine[]) =>
    new Set(
      [...selected].filter((id) => {
        const line = current.find((l) => l.rfqItemId === id);
        return line !== undefined && isQuoted(line);
      }),
    );
  const bulk = (change: (current: DraftLine[]) => DraftLine[], message: string) => {
    onChange(change);
    toast.success(message);
  };
  const clearFilters = () => {
    setSearch("");
    setFilter("all");
    setPage(0);
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="secondary" className="tabular-nums">
          {stats.quoted} of {stats.total} lines quoted
        </Badge>
        {stats.unquoted > 0 && (
          <Badge variant="outline" className="gap-1 tabular-nums">
            <Minus className="h-3 w-3" /> {stats.unquoted} not quoting
          </Badge>
        )}
        {stats.withIssues > 0 && (
          <button
            type="button"
            onClick={() => {
              setSearch("");
              setFilter("attention");
              setPage(0);
            }}
            className="inline-flex items-center gap-1 rounded-md border border-destructive/40 bg-destructive/10 px-2.5 py-0.5 text-xs font-semibold text-destructive hover:bg-destructive/15"
          >
            <AlertTriangle className="h-3 w-3" /> {stats.withIssues} need attention · show
          </button>
        )}
        {tools && <div className="flex flex-wrap items-center gap-2 sm:ml-auto">{tools}</div>}
      </div>

      <div className="overflow-hidden rounded-lg border">
        <div className="flex flex-wrap items-center gap-2 border-b bg-muted/30 p-2">
          <div className="relative min-w-[200px] flex-1 sm:max-w-xs">
            <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
            <Input
              aria-label="Search requested medicines"
              placeholder="Search requested medicines"
              className="pl-8"
              value={search}
              onChange={(e) => {
                setSearch(e.target.value);
                setPage(0);
              }}
            />
          </div>
          <select
            aria-label="Show"
            className={`${selectBase} w-44`}
            value={filter}
            onChange={(e) => {
              setFilter(e.target.value as QuoteFilter);
              setPage(0);
            }}
          >
            <option value="all">All lines</option>
            <option value="quoted">Quoted</option>
            <option value="unquoted">Not quoting</option>
            <option value="attention">Needs attention</option>
          </select>
          {(search || filter !== "all") && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="gap-1"
              onClick={clearFilters}
            >
              <X className="h-3.5 w-3.5" /> Clear
            </Button>
          )}
          <span className="ml-auto text-xs tabular-nums text-muted-foreground">
            {view.length === lines.length
              ? `${lines.length} lines`
              : `${view.length} of ${lines.length} lines`}
          </span>
        </div>

        {selected.size > 0 && (
          <div className="flex flex-wrap items-center gap-2 border-b bg-primary/5 px-3 py-2 text-sm">
            <span className="font-medium tabular-nums">{selected.size} selected</span>
            {!allMatching && view.length > selected.size && (
              <button
                type="button"
                className="text-xs text-primary underline"
                onClick={() => setSelected(new Set(view.map((i) => lines[i].rfqItemId)))}
              >
                Select all {view.length} in this view
              </button>
            )}
            <div className="flex items-center gap-1">
              <Input
                aria-label="Discount percent for the selected lines"
                type="number"
                min="0"
                max="99.99"
                step="0.01"
                className="h-8 w-20 tabular-nums"
                value={bulkDiscount}
                onChange={(e) => setBulkDiscount(e.target.value)}
              />
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={disabled || bulkDiscount === ""}
                onClick={() =>
                  bulk(
                    (current) =>
                      applyToDraft(current, quotedSelection(current), {
                        discountPercent: bulkDiscount,
                      }),
                    `Set ${bulkDiscount}% discount on the quoted lines selected.`,
                  )
                }
              >
                Set discount %
              </Button>
            </div>
            <div className="flex items-center gap-1">
              <Input
                aria-label="Expiry date for the selected lines"
                type="date"
                className="h-8 w-40"
                value={bulkExpiry}
                onChange={(e) => setBulkExpiry(e.target.value)}
              />
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={disabled || !bulkExpiry}
                onClick={() =>
                  bulk(
                    (current) =>
                      applyToDraft(current, quotedSelection(current), { expiryDate: bulkExpiry }),
                    "Set the expiry date on the quoted lines selected.",
                  )
                }
              >
                Set expiry
              </Button>
            </div>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button type="button" variant="outline" size="sm" disabled={disabled}>
                  More…
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="w-64">
                <DropdownMenuItem
                  onSelect={() =>
                    bulk(
                      (current) => offerFullQuantity(current, selected, itemMap),
                      "Offered the full requested quantity.",
                    )
                  }
                >
                  Offer the full requested quantity
                </DropdownMenuItem>
                <DropdownMenuItem
                  onSelect={() =>
                    bulk(
                      (current) =>
                        applyToDraft(current, quotedSelection(current), {
                          coldChainSupported: true,
                        }),
                      "Confirmed cold chain on the quoted lines selected.",
                    )
                  }
                >
                  Confirm cold chain
                </DropdownMenuItem>
                <DropdownMenuItem
                  onSelect={() => {
                    const out = fillPrices(
                      linesRef.current,
                      selected,
                      (id) => products.get(id)?.price_ghs,
                    );
                    onChange(out.lines);
                    toast[out.filled ? "success" : "info"](
                      out.filled
                        ? `Filled ${out.filled} empty price${out.filled === 1 ? "" : "s"} from your catalogue list prices. Check them before submitting.`
                        : "No empty prices to fill, or your catalogue has no list price for those products.",
                    );
                  }}
                >
                  Fill empty prices from my catalogue
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem onSelect={() => setConfirmStop(true)}>
                  Stop quoting these lines…
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
            {confirmStop && (
              <>
                <Button
                  type="button"
                  variant="destructive"
                  size="sm"
                  onClick={() => {
                    onChange((current) => stopQuoting(current, selected, itemMap));
                    setConfirmStop(false);
                    toast.success(
                      `Stopped quoting ${selected.size} line${selected.size === 1 ? "" : "s"}.`,
                    );
                  }}
                >
                  Clear {selected.size} for good
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => setConfirmStop(false)}
                >
                  Keep them
                </Button>
              </>
            )}
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="ml-auto"
              onClick={() => {
                setSelected(new Set());
                setConfirmStop(false);
              }}
            >
              Clear selection
            </Button>
          </div>
        )}

        <div className="overflow-x-auto">
          <Table className="min-w-[1100px] table-fixed">
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead className="w-10">
                  <Checkbox
                    aria-label="Select all lines on this page"
                    checked={allOnPage ? true : someOnPage ? "indeterminate" : false}
                    disabled={disabled || !pageIds.length}
                    onCheckedChange={(v) =>
                      setSelected((current) => {
                        const next = new Set(current);
                        for (const id of pageIds) {
                          if (v === true) next.add(id);
                          else next.delete(id);
                        }
                        return next;
                      })
                    }
                  />
                </TableHead>
                <TableHead className="w-10">#</TableHead>
                <TableHead>Requested</TableHead>
                <TableHead className="w-[230px]">Your product</TableHead>
                <TableHead className="w-[84px]">Units</TableHead>
                <TableHead className="w-[112px]">Price (GHS)</TableHead>
                <TableHead className="w-[84px]">Disc. %</TableHead>
                <TableHead className="w-[150px]">Expiry</TableHead>
                <TableHead className="w-[130px]">Details</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {paged.rows.length === 0 ? (
                <TableRow>
                  <TableCell
                    colSpan={9}
                    className="py-10 text-center text-sm text-muted-foreground"
                  >
                    No lines match.{" "}
                    <button type="button" className="text-primary underline" onClick={clearFilters}>
                      Show all
                    </button>
                  </TableCell>
                </TableRow>
              ) : (
                paged.rows.map((i) => {
                  const line = lines[i];
                  const item = itemMap.get(line.rfqItemId)!;
                  return (
                    <Row
                      key={line.rfqItemId}
                      line={line}
                      item={item}
                      position={i + 1}
                      issue={issues.get(line.rfqItemId)}
                      product={products.get(line.productId)}
                      checked={selected.has(line.rfqItemId)}
                      disabled={disabled}
                      businessId={businessId}
                      onUpdate={update}
                      onPick={pick}
                      onToggle={toggle}
                    />
                  );
                })
              )}
            </TableBody>
          </Table>
        </div>
        <TablePager paged={paged} size={size} onSize={setSize} onPage={setPage} />
      </div>
    </div>
  );
}
