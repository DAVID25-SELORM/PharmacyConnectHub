import { useMemo, useState } from "react";
import { Search } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
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
import type { QuoteVersion, Requirement } from "@/lib/enterprise-rfq";
import { formatGHS } from "@/lib/format";
import { landedTotal } from "@/lib/rfq-evaluation";
import { RFQ_PAGE_SIZES, pageOf } from "@/lib/rfq-lines";
import { rfqDate, rfqDateTime } from "@/lib/rfq-format";
import { TablePager } from "./TablePager";

/** A supplier's own submitted quotation: terms, a paged list of the lines it offered, and its revision history. */
export function RfqSubmittedQuote({
  version,
  history,
  items,
  onPdf,
}: {
  version: QuoteVersion;
  history: QuoteVersion[];
  items: Requirement[];
  onPdf: () => void;
}) {
  const q = version.snapshot.quote;
  const itemName = useMemo(() => new Map(items.map((i) => [i.id, i.product_name])), [items]);
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [size, setSize] = useState<number>(RFQ_PAGE_SIZES[0]);
  const term = search.trim().toLowerCase();
  const shown = version.snapshot.items
    .map((_, i) => i)
    .filter((i) => {
      const line = version.snapshot.items[i];
      return (
        !term ||
        `${itemName.get(line.rfq_item_id) ?? ""} ${String(line.offered_specification.name ?? "")}`
          .toLowerCase()
          .includes(term)
      );
    });
  const paged = pageOf(shown, page, size);

  return (
    <Card>
      <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between sm:space-y-0">
        <div className="space-y-1.5">
          <CardTitle className="text-lg">Your quotation · revision {version.version}</CardTitle>
          <CardDescription>
            Submitted {rfqDateTime(version.created_at)} · {version.snapshot.taxTreatment}
          </CardDescription>
        </div>
        <Button type="button" variant="outline" size="sm" onClick={onPdf}>
          Quotation PDF
        </Button>
      </CardHeader>
      <CardContent className="space-y-4">
        <dl className="grid gap-x-8 gap-y-3 text-sm sm:grid-cols-2 lg:grid-cols-5">
          {(
            [
              ["Goods", formatGHS(q.total_ghs)],
              [
                "Delivery",
                Number(q.delivery_charge_ghs) > 0 ? formatGHS(q.delivery_charge_ghs) : "Free",
              ],
              ["Landed total", formatGHS(landedTotal(version))],
              ["Lead time", q.lead_time_days != null ? `${q.lead_time_days} days` : "Not stated"],
              ["Valid until", rfqDate(q.valid_until)],
            ] as const
          ).map(([label, value]) => (
            <div key={label}>
              <dt className="text-xs uppercase tracking-wide text-muted-foreground">{label}</dt>
              <dd className="font-medium tabular-nums">{value}</dd>
            </div>
          ))}
          <div className="sm:col-span-2 lg:col-span-5">
            <dt className="text-xs uppercase tracking-wide text-muted-foreground">Payment terms</dt>
            <dd className="font-medium">{q.payment_terms || "Not stated"}</dd>
          </div>
        </dl>

        <div className="overflow-hidden rounded-lg border">
          {version.snapshot.items.length > RFQ_PAGE_SIZES[0] && (
            <div className="border-b bg-muted/30 p-2">
              <div className="relative max-w-xs">
                <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
                <Input
                  aria-label="Search your quoted lines"
                  placeholder="Search your quoted lines"
                  className="pl-8"
                  value={search}
                  onChange={(e) => {
                    setSearch(e.target.value);
                    setPage(0);
                  }}
                />
              </div>
            </div>
          )}
          <div className="overflow-x-auto">
            <Table className="min-w-[760px]">
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead className="w-12">#</TableHead>
                  <TableHead>Requested → offered</TableHead>
                  <TableHead className="w-24 text-right">Units</TableHead>
                  <TableHead className="w-32 text-right">Final price</TableHead>
                  <TableHead className="w-32">Expiry</TableHead>
                  <TableHead className="w-28" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {paged.rows.length === 0 ? (
                  <TableRow>
                    <TableCell
                      colSpan={6}
                      className="py-8 text-center text-sm text-muted-foreground"
                    >
                      No lines match.
                    </TableCell>
                  </TableRow>
                ) : (
                  paged.rows.map((i) => {
                    const l = version.snapshot.items[i];
                    const spec = l.offered_specification;
                    return (
                      <TableRow key={l.id}>
                        <TableCell className="align-top text-xs tabular-nums text-muted-foreground">
                          {i + 1}
                        </TableCell>
                        <TableCell className="align-top">
                          <div className="text-xs text-muted-foreground">
                            Requested: {itemName.get(l.rfq_item_id) ?? "Medicine"}
                          </div>
                          <div className="font-medium">{String(spec.name ?? "Product")}</div>
                          {l.alternative && (
                            <Badge
                              variant="outline"
                              className="mt-0.5 border-warning/50 text-warning-foreground"
                            >
                              Alternative · 1 unit = {l.requested_units_per_offered_unit} requested
                            </Badge>
                          )}
                        </TableCell>
                        <TableCell className="align-top text-right tabular-nums">
                          {l.quantity}
                        </TableCell>
                        <TableCell className="align-top text-right tabular-nums">
                          {formatGHS(l.final_unit_price_ghs)}
                        </TableCell>
                        <TableCell className="align-top tabular-nums">
                          {rfqDate(l.expiry_date)}
                        </TableCell>
                        <TableCell className="align-top">
                          <Popover>
                            <PopoverTrigger asChild>
                              <Button type="button" variant="ghost" size="sm" className="text-xs">
                                Details
                              </Button>
                            </PopoverTrigger>
                            <PopoverContent align="end" className="w-80 space-y-1.5 text-xs">
                              <p>
                                {["brand", "strength", "form", "pack"]
                                  .map((k) => `${k}: ${spec[k] ?? "not stated"}`)
                                  .join(" · ")}
                              </p>
                              <p>
                                Lot {l.batch_number || "not stated"} · Available{" "}
                                {l.expected_available_on
                                  ? rfqDate(l.expected_available_on)
                                  : "not stated"}
                              </p>
                              <p>
                                Cold chain {l.cold_chain_supported ? "confirmed" : "not confirmed"}
                                {l.special_handling ? ` · Handling: ${l.special_handling}` : ""}
                              </p>
                              <p className="text-muted-foreground">
                                Stock observed at submission:{" "}
                                {String(spec.stockAtSubmission ?? "not recorded")} (not reserved).
                              </p>
                              {l.notes && <p>Note: {l.notes}</p>}
                            </PopoverContent>
                          </Popover>
                        </TableCell>
                      </TableRow>
                    );
                  })
                )}
              </TableBody>
            </Table>
          </div>
          {shown.length > RFQ_PAGE_SIZES[0] || size !== RFQ_PAGE_SIZES[0] ? (
            <TablePager paged={paged} size={size} onSize={setSize} onPage={setPage} />
          ) : null}
        </div>

        {history.length > 1 && (
          <details className="rounded-lg border px-4 py-3 text-sm">
            <summary className="cursor-pointer font-medium">
              Revision history ({history.length})
            </summary>
            <p className="mt-2 text-xs text-muted-foreground">
              Every version is kept exactly as it was sent.
            </p>
            <ul className="mt-2 space-y-1.5">
              {history.map((old) => (
                <li key={old.id} className="text-xs">
                  <span className="font-medium">Revision {old.version}</span> ·{" "}
                  {formatGHS(landedTotal(old))} · {old.reason} · {rfqDateTime(old.created_at)}
                </li>
              ))}
            </ul>
          </details>
        )}
      </CardContent>
    </Card>
  );
}
