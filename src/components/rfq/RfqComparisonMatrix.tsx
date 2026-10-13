import { useMemo, useState } from "react";
import { Info, Search, Snowflake, X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import type { QuoteVersion, Requirement, VersionLine } from "@/lib/enterprise-rfq";
import { formatGHS } from "@/lib/format";
import {
  buildLineIndex,
  lowestPriceLineIds,
  visibleRequirements,
  type Accepted,
  type MatrixFilter,
  type Selection,
} from "@/lib/rfq-evaluation";
import { RFQ_PAGE_SIZES, pageOf } from "@/lib/rfq-lines";
import { rfqDate } from "@/lib/rfq-format";
import { TablePager } from "./TablePager";

const selectBase =
  "h-9 rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring";

function Cell({
  line,
  item,
  lowest,
  award,
  value,
  accepted,
  issue,
  onValue,
  onAccepted,
}: {
  line: VersionLine;
  item: Requirement;
  lowest: boolean;
  award: boolean;
  value: string;
  accepted: boolean;
  issue?: string;
  onValue: (value: string) => void;
  onAccepted: (on: boolean) => void;
}) {
  const spec = line.offered_specification ?? {};
  const full =
    Number(line.quantity) * Number(line.requested_units_per_offered_unit || 1) >= item.quantity;
  return (
    <div className="space-y-1.5">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="truncate text-sm font-medium" title={String(spec.name ?? "Product")}>
            {String(spec.name ?? "Product")}
          </div>
          {line.alternative && (
            <Badge
              variant="outline"
              className="mt-0.5 border-warning/50 px-1.5 py-0 text-[10px] text-warning-foreground"
            >
              Alternative · 1 unit = {line.requested_units_per_offered_unit} requested
            </Badge>
          )}
        </div>
        <Popover>
          <PopoverTrigger asChild>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="h-6 w-6 shrink-0"
              aria-label="Offer details"
            >
              <Info className="h-3.5 w-3.5 text-muted-foreground" />
            </Button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-80 space-y-1.5 text-xs">
            <p className="text-sm font-medium">{String(spec.name ?? "Product")}</p>
            <p>
              {["brand", "strength", "form", "pack"]
                .map((k) => `${k}: ${spec[k] ?? "not stated"}`)
                .join(" · ")}
            </p>
            <p>
              Lot {line.batch_number || "not stated"} · Expiry {line.expiry_date || "not stated"}
            </p>
            <p>
              Available{" "}
              {line.expected_available_on ? rfqDate(line.expected_available_on) : "not stated"}
            </p>
            <p>
              Cold chain {line.cold_chain_supported ? "supplier confirmed" : "not confirmed"}
              {line.special_handling ? ` · Handling: ${line.special_handling}` : ""}
            </p>
            <p className="text-muted-foreground">
              Stock observed at quote submission: {String(spec.stockAtSubmission ?? "not recorded")}{" "}
              (not reserved).
            </p>
            {line.notes && <p>Supplier note: {line.notes}</p>}
          </PopoverContent>
        </Popover>
      </div>
      <div className="flex flex-wrap items-baseline gap-x-2 text-sm tabular-nums">
        <span className="font-semibold">{formatGHS(line.final_unit_price_ghs)}</span>
        {Number(line.discount_percent) > 0 && (
          <span className="text-xs text-muted-foreground line-through">
            {formatGHS(line.unit_price_ghs)}
          </span>
        )}
        <span className="text-xs text-muted-foreground">
          × {line.quantity}
          {full ? "" : " (partial)"}
        </span>
      </div>
      <div className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
        <span>Exp {line.expiry_date ? rfqDate(line.expiry_date) : "n/a"}</span>
        {line.cold_chain_supported && (
          <Snowflake className="h-3 w-3" aria-label="Cold chain confirmed" />
        )}
        {lowest && (
          <Badge
            variant="outline"
            className="border-success/40 px-1.5 py-0 text-[10px] text-success"
          >
            Lowest price
          </Badge>
        )}
      </div>
      {award && (
        <div className="space-y-1">
          <label className="flex items-center gap-1.5 text-xs">
            <span className="text-muted-foreground">Award</span>
            <Input
              type="number"
              min={0}
              max={Number(line.quantity)}
              step={1}
              inputMode="numeric"
              className={`h-8 w-20 tabular-nums ${issue ? "border-destructive" : ""}`}
              value={value}
              onChange={(e) => onValue(e.target.value)}
              aria-label={`Units to award to ${String(spec.name ?? "supplier")} for ${item.product_name}`}
              aria-invalid={Boolean(issue)}
            />
            <span className="text-muted-foreground">of {line.quantity}</span>
          </label>
          {line.alternative && (
            <label className="flex items-start gap-1.5 text-xs">
              <Checkbox
                className="mt-0.5"
                checked={accepted}
                onCheckedChange={(v) => onAccepted(v === true)}
              />
              <span>Accept specification and conversion</span>
            </label>
          )}
          {issue && <p className="text-xs text-destructive">{issue}</p>}
        </div>
      )}
    </div>
  );
}

/** Requirement-by-requirement comparison: a paged matrix, one row per requested medicine, one column per supplier. */
export function RfqComparisonMatrix({
  items,
  versions,
  names,
  selection,
  accepted,
  issues,
  remaining,
  canAward,
  onSelect,
  onAccept,
  tools,
}: {
  items: Requirement[];
  versions: QuoteVersion[];
  names: Record<string, string>;
  selection: Selection;
  accepted: Accepted;
  issues: Map<string, string>;
  remaining: (item: Requirement) => number;
  canAward: boolean;
  onSelect: (lineId: string, value: string) => void;
  onAccept: (lineId: string, on: boolean) => void;
  tools?: React.ReactNode;
}) {
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<MatrixFilter>("all");
  const [page, setPage] = useState(0);
  const [size, setSize] = useState<number>(RFQ_PAGE_SIZES[0]);
  const index = useMemo(() => buildLineIndex(versions), [versions]);
  const lowest = useMemo(() => lowestPriceLineIds(index), [index]);
  const view = useMemo(
    () => visibleRequirements(items, index, selection, remaining, { search, filter }),
    [items, index, selection, remaining, search, filter],
  );
  const paged = pageOf(view, page, size);
  const clear = () => {
    setSearch("");
    setFilter("all");
    setPage(0);
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
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
          aria-label="Show requirements"
          className={`${selectBase} w-52`}
          value={filter}
          onChange={(e) => {
            setFilter(e.target.value as MatrixFilter);
            setPage(0);
          }}
        >
          <option value="all">All requirements</option>
          <option value="open">Still to decide</option>
          <option value="chosen">With a choice</option>
          <option value="alternatives">With alternatives offered</option>
          <option value="unquoted">Nobody quoted</option>
        </select>
        {(search || filter !== "all") && (
          <Button type="button" variant="ghost" size="sm" className="gap-1" onClick={clear}>
            <X className="h-3.5 w-3.5" /> Clear
          </Button>
        )}
        <span className="text-xs tabular-nums text-muted-foreground">
          {view.length === items.length
            ? `${items.length} requirements`
            : `${view.length} of ${items.length} requirements`}
        </span>
        {tools && <div className="flex flex-wrap items-center gap-2 sm:ml-auto">{tools}</div>}
      </div>

      <div className="overflow-hidden rounded-lg border">
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-left text-sm">
            <thead>
              <tr className="bg-muted/40">
                <th
                  scope="col"
                  className="sticky left-0 z-10 w-[260px] min-w-[260px] bg-muted px-3 py-2 text-xs font-medium"
                >
                  Requested medicine
                </th>
                {versions.map((v) => (
                  <th
                    key={v.id}
                    scope="col"
                    className="min-w-[230px] px-3 py-2 align-top text-xs font-medium"
                  >
                    <div className="truncate text-sm">{names[v.wholesaler_id] ?? "Supplier"}</div>
                    <div className="font-normal text-muted-foreground">Revision {v.version}</div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y">
              {paged.rows.length === 0 ? (
                <tr>
                  <td
                    colSpan={versions.length + 1}
                    className="py-10 text-center text-sm text-muted-foreground"
                  >
                    No requirements match.{" "}
                    <button type="button" className="text-primary underline" onClick={clear}>
                      Show all
                    </button>
                  </td>
                </tr>
              ) : (
                paged.rows.map((i) => {
                  const item = items[i];
                  const left = remaining(item);
                  const row = index.get(item.id);
                  return (
                    <tr key={item.id} className="align-top">
                      <th
                        scope="row"
                        className="sticky left-0 z-10 bg-background px-3 py-3 font-normal"
                      >
                        <div className="flex items-start gap-2">
                          <span className="pt-0.5 text-xs tabular-nums text-muted-foreground">
                            {i + 1}
                          </span>
                          <div className="min-w-0">
                            <div className="font-medium leading-snug">{item.product_name}</div>
                            <div className="text-xs text-muted-foreground">
                              {item.quantity} {item.unit}
                              {left !== item.quantity ? ` · ${left} still needed` : ""}
                            </div>
                            <div className="mt-1 flex flex-wrap gap-1">
                              {item.cold_chain_required && (
                                <Badge
                                  variant="outline"
                                  className="gap-1 px-1.5 py-0 text-[10px] font-medium"
                                >
                                  <Snowflake className="h-3 w-3" /> Cold chain
                                </Badge>
                              )}
                              {!item.partial_allowed && (
                                <Badge
                                  variant="outline"
                                  className="px-1.5 py-0 text-[10px] font-medium"
                                >
                                  Full quantity only
                                </Badge>
                              )}
                              {left === 0 && (
                                <Badge
                                  variant="secondary"
                                  className="px-1.5 py-0 text-[10px] font-medium"
                                >
                                  Fully allocated
                                </Badge>
                              )}
                            </div>
                          </div>
                        </div>
                      </th>
                      {versions.map((v) => {
                        const line = row?.get(v.id);
                        return (
                          <td key={v.id} className="px-3 py-3">
                            {line ? (
                              <Cell
                                line={line}
                                item={item}
                                lowest={lowest.has(line.id)}
                                award={canAward}
                                value={selection[line.id] ?? ""}
                                accepted={accepted[line.id] ?? false}
                                issue={issues.get(line.id)}
                                onValue={(value) => onSelect(line.id, value)}
                                onAccepted={(on) => onAccept(line.id, on)}
                              />
                            ) : (
                              <span className="text-xs text-muted-foreground">Not quoted</span>
                            )}
                          </td>
                        );
                      })}
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
        <TablePager paged={paged} size={size} onSize={setSize} onPage={setPage} />
      </div>
    </div>
  );
}
