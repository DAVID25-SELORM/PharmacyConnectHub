import { memo, useCallback, useMemo, useRef, useState } from "react";
import { AlertTriangle, CheckCircle2, Minus, Search, X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatGHS } from "@/lib/format";
import { finalUnitPrice, type QuoteLineDraft, type RfqItem } from "@/lib/rfq";
import {
  legacySummary,
  setIncluded,
  visibleLegacyIndices,
  type LegacyFilter,
} from "@/lib/rfq-legacy";
import { RFQ_PAGE_SIZES, pageOf } from "@/lib/rfq-lines";
import { QuoteProductCombobox, type OfferedProduct } from "./QuoteProductCombobox";
import { TablePager } from "./TablePager";

const selectBase =
  "h-9 rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring";

type RowProps = {
  line: QuoteLineDraft;
  item: RfqItem;
  position: number;
  issue?: string;
  product?: OfferedProduct;
  editable: boolean;
  disabled: boolean;
  businessId: string;
  onUpdate: (id: string, patch: Partial<QuoteLineDraft>) => void;
  onPick: (id: string, product: OfferedProduct | null) => void;
};

const Row = memo(function Row({
  line,
  item,
  position,
  issue,
  product,
  editable,
  disabled,
  businessId,
  onUpdate,
  onPick,
}: RowProps) {
  const patch = (p: Partial<QuoteLineDraft>) => onUpdate(line.rfqItemId, p);
  const qty = line.quantity.trim() ? Number(line.quantity) : item.quantity;
  const price = Number(line.unitPriceGhs);
  const lineTotal =
    line.include && price > 0 && !issue
      ? finalUnitPrice(price, Number(line.discountPercent) || 0) * qty
      : null;
  return (
    <TableRow className={issue ? "bg-destructive/5" : undefined}>
      <TableCell className="w-10 align-top">
        {editable && (
          <Checkbox
            aria-label={`Quote line ${position}`}
            checked={line.include}
            disabled={disabled}
            onCheckedChange={(v) => patch({ include: v === true })}
          />
        )}
      </TableCell>
      <TableCell className="w-10 align-top pt-4 text-xs tabular-nums text-muted-foreground">
        {position}
      </TableCell>
      <TableCell className="align-top">
        <div className="flex items-start gap-2">
          <span className="pt-0.5">
            {issue ? (
              <AlertTriangle className="h-4 w-4 text-destructive" aria-label="Needs attention" />
            ) : line.include ? (
              <CheckCircle2 className="h-4 w-4 text-success" aria-label="Ready to quote" />
            ) : (
              <Minus className="h-4 w-4 text-muted-foreground" aria-label="Not quoting" />
            )}
          </span>
          <div className="min-w-0">
            <div className="font-medium leading-snug">{item.product_name}</div>
            <p className="text-xs text-muted-foreground">
              Requested {item.quantity} unit{item.quantity === 1 ? "" : "s"}
              {item.notes ? ` · ${item.notes}` : ""}
            </p>
            {issue && <p className="mt-1 text-xs text-destructive">{issue}</p>}
          </div>
        </div>
      </TableCell>
      {line.include ? (
        <>
          <TableCell className="w-[220px] align-top">
            {editable ? (
              <QuoteProductCombobox
                businessId={businessId}
                hasValue={Boolean(line.productId)}
                selected={product}
                disabled={disabled}
                label={`Your product for line ${position}`}
                onPick={(p) => onPick(line.rfqItemId, p)}
              />
            ) : (
              <span className="text-sm">{product?.name ?? "Product"}</span>
            )}
          </TableCell>
          <TableCell className="w-[100px] align-top">
            {editable ? (
              <Input
                aria-label={`Available quantity for line ${position}`}
                type="number"
                min={1}
                max={item.quantity}
                step={1}
                inputMode="numeric"
                placeholder={String(item.quantity)}
                className="tabular-nums"
                value={line.quantity}
                disabled={disabled}
                onChange={(e) => patch({ quantity: e.target.value })}
              />
            ) : (
              <span className="text-sm tabular-nums">{qty}</span>
            )}
          </TableCell>
          <TableCell className="w-[110px] align-top">
            {editable ? (
              <Input
                aria-label={`Unit price in GHS for line ${position}`}
                type="number"
                min={0}
                step="0.01"
                inputMode="decimal"
                className="tabular-nums"
                value={line.unitPriceGhs}
                disabled={disabled}
                onChange={(e) => patch({ unitPriceGhs: e.target.value })}
              />
            ) : (
              <span className="text-sm tabular-nums">{formatGHS(price || 0)}</span>
            )}
          </TableCell>
          <TableCell className="w-[84px] align-top">
            {editable ? (
              <Input
                aria-label={`Discount percent for line ${position}`}
                type="number"
                min={0}
                max={99.99}
                step="0.01"
                inputMode="decimal"
                className="tabular-nums"
                value={line.discountPercent}
                disabled={disabled}
                onChange={(e) => patch({ discountPercent: e.target.value })}
              />
            ) : (
              <span className="text-sm tabular-nums">
                {Number(line.discountPercent) > 0 ? `${line.discountPercent}%` : "–"}
              </span>
            )}
          </TableCell>
          <TableCell className="w-[120px] whitespace-nowrap pt-4 text-right align-top text-sm tabular-nums">
            {lineTotal === null ? "–" : formatGHS(lineTotal)}
          </TableCell>
          <TableCell className="w-[90px] align-top">
            {editable ? (
              <Popover>
                <PopoverTrigger asChild>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="h-9 w-full font-normal"
                    disabled={disabled}
                    aria-label={`Notes for line ${position}`}
                  >
                    {line.notes.trim() ? "Note ✓" : "Note"}
                  </Button>
                </PopoverTrigger>
                <PopoverContent align="end" className="w-80 space-y-2">
                  <p className="text-sm font-medium">Note for line {position}</p>
                  <Input
                    placeholder="e.g. substitute brand"
                    value={line.notes}
                    onChange={(e) => patch({ notes: e.target.value })}
                  />
                </PopoverContent>
              </Popover>
            ) : (
              line.notes.trim() && (
                <span className="text-xs text-muted-foreground">{line.notes}</span>
              )
            )}
          </TableCell>
        </>
      ) : (
        <TableCell colSpan={6} className="pt-4 align-top text-xs text-muted-foreground">
          {editable ? "Not quoting this line. Tick it to quote." : "Not quoted."}
        </TableCell>
      )}
    </TableRow>
  );
});

/** The older RFQ's quotation lines: one row per requested item, searchable and paged, with include/exclude in bulk. */
export function LegacyQuoteTable({
  businessId,
  items,
  lines,
  onChange,
  issues,
  products,
  onProducts,
  editable,
  disabled = false,
}: {
  businessId: string;
  items: RfqItem[];
  lines: QuoteLineDraft[];
  onChange: (next: QuoteLineDraft[] | ((current: QuoteLineDraft[]) => QuoteLineDraft[])) => void;
  issues: Map<string, string>;
  products: Map<string, OfferedProduct>;
  onProducts: (found: OfferedProduct[]) => void;
  editable: boolean;
  disabled?: boolean;
}) {
  const itemMap = useMemo(() => new Map(items.map((i) => [i.id, i])), [items]);
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<LegacyFilter>("all");
  const [page, setPage] = useState(0);
  const [size, setSize] = useState<number>(RFQ_PAGE_SIZES[0]);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const onProductsRef = useRef(onProducts);
  onProductsRef.current = onProducts;

  const effectiveFilter: LegacyFilter = editable ? filter : "included";
  const view = useMemo(
    () => visibleLegacyIndices(lines, itemMap, issues, { search, filter: effectiveFilter }),
    [lines, itemMap, issues, search, effectiveFilter],
  );
  const paged = pageOf(view, page, size);
  const stats = legacySummary(lines, itemMap, issues);
  const shownIds = new Set(view.map((i) => lines[i].rfqItemId));

  const update = useCallback((id: string, patch: Partial<QuoteLineDraft>) => {
    onChangeRef.current((current) =>
      current.map((l) => (l.rfqItemId === id ? { ...l, ...patch } : l)),
    );
  }, []);
  const pick = useCallback((id: string, product: OfferedProduct | null) => {
    if (product) onProductsRef.current([product]);
    onChangeRef.current((current) =>
      current.map((l) => (l.rfqItemId === id ? { ...l, productId: product?.id ?? "" } : l)),
    );
  }, []);
  const clear = () => {
    setSearch("");
    setFilter("all");
    setPage(0);
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="secondary" className="tabular-nums">
          {editable
            ? `${stats.included} of ${stats.total} items quoted`
            : `${stats.included} items quoted`}
        </Badge>
        {editable && stats.withIssues > 0 && (
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
      </div>
      <div className="overflow-hidden rounded-lg border">
        <div className="flex flex-wrap items-center gap-2 border-b bg-muted/30 p-2">
          <div className="relative min-w-[200px] flex-1 sm:max-w-xs">
            <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
            <Input
              aria-label="Search requested items"
              placeholder="Search requested items"
              className="pl-8"
              value={search}
              onChange={(e) => {
                setSearch(e.target.value);
                setPage(0);
              }}
            />
          </div>
          {editable && (
            <>
              <select
                aria-label="Show"
                className={`${selectBase} w-44`}
                value={filter}
                onChange={(e) => {
                  setFilter(e.target.value as LegacyFilter);
                  setPage(0);
                }}
              >
                <option value="all">All items</option>
                <option value="included">Being quoted</option>
                <option value="excluded">Not quoting</option>
                <option value="attention">Needs attention</option>
              </select>
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={disabled || !view.length}
                onClick={() => onChange((current) => setIncluded(current, shownIds, true))}
              >
                Quote all shown
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                disabled={disabled || !view.length}
                onClick={() => onChange((current) => setIncluded(current, shownIds, false))}
              >
                Clear all shown
              </Button>
            </>
          )}
          {(search || filter !== "all") && (
            <Button type="button" variant="ghost" size="sm" className="gap-1" onClick={clear}>
              <X className="h-3.5 w-3.5" /> Clear
            </Button>
          )}
          <span className="ml-auto text-xs tabular-nums text-muted-foreground">
            {view.length} of {lines.length} items
          </span>
        </div>
        <div className="overflow-x-auto">
          <Table className="min-w-[1000px] table-fixed">
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead className="w-10" />
                <TableHead className="w-10">#</TableHead>
                <TableHead>Requested</TableHead>
                <TableHead className="w-[220px]">Your product</TableHead>
                <TableHead className="w-[100px]">Available</TableHead>
                <TableHead className="w-[110px]">Price (GHS)</TableHead>
                <TableHead className="w-[84px]">Disc. %</TableHead>
                <TableHead className="w-[120px] text-right">Line total</TableHead>
                <TableHead className="w-[90px]" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {paged.rows.length === 0 ? (
                <TableRow>
                  <TableCell
                    colSpan={9}
                    className="py-10 text-center text-sm text-muted-foreground"
                  >
                    {editable ? "No items match." : "Nothing quoted."}{" "}
                    {editable && (
                      <button type="button" className="text-primary underline" onClick={clear}>
                        Show all
                      </button>
                    )}
                  </TableCell>
                </TableRow>
              ) : (
                paged.rows.map((i) => {
                  const line = lines[i];
                  return (
                    <Row
                      key={line.rfqItemId}
                      line={line}
                      item={itemMap.get(line.rfqItemId)!}
                      position={i + 1}
                      issue={editable ? issues.get(line.rfqItemId) : undefined}
                      product={products.get(line.productId)}
                      editable={editable}
                      disabled={disabled}
                      businessId={businessId}
                      onUpdate={update}
                      onPick={pick}
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
