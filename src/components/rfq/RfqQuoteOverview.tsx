import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
import { ChevronDown, History } from "lucide-react";
import type { QuoteVersion, Requirement } from "@/lib/enterprise-rfq";
import { formatGHS } from "@/lib/format";
import { coverage, landedTotal, type SelectionTotal } from "@/lib/rfq-evaluation";
import { rfqDate, rfqDateTime } from "@/lib/rfq-format";

export type CreditInfo = {
  wholesaler_id: string;
  payment_terms_days: number | null;
  available_ghs: number;
  status: string;
};

/** One row per supplier's latest quotation: coverage, totals and terms, with that supplier's actions. */
export function RfqQuoteOverview({
  versions,
  allVersions,
  items,
  names,
  credit,
  totals,
  canManage,
  busy,
  onWhole,
  onNegotiate,
  onPdf,
}: {
  versions: QuoteVersion[];
  allVersions: QuoteVersion[];
  items: Requirement[];
  names: Record<string, string>;
  credit: CreditInfo[];
  totals: SelectionTotal[];
  canManage: boolean;
  busy: boolean;
  onWhole: (version: QuoteVersion) => void;
  onNegotiate: (version: QuoteVersion) => void;
  onPdf: (version: QuoteVersion) => void;
}) {
  const lowest = Math.min(...versions.map(landedTotal));
  return (
    <div className="overflow-hidden rounded-lg border">
      <div className="overflow-x-auto">
        <Table className="min-w-[860px]">
          <TableHeader>
            <TableRow className="bg-muted/40 hover:bg-muted/40">
              <TableHead>Supplier</TableHead>
              <TableHead className="w-44">Answers</TableHead>
              <TableHead className="w-32 text-right">Goods</TableHead>
              <TableHead className="w-28 text-right">Delivery</TableHead>
              <TableHead className="w-36 text-right">Landed total</TableHead>
              <TableHead className="w-44">Terms</TableHead>
              <TableHead className="w-28">
                <span className="sr-only">Actions</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {versions.map((v) => {
              const cover = coverage(v, items);
              const q = v.snapshot.quote;
              const chosen = totals.find((t) => t.versionId === v.id);
              const credits = credit.filter(
                (c) => c.wholesaler_id === v.wholesaler_id && c.status === "active",
              );
              const history = allVersions.filter((old) => old.quote_id === v.quote_id);
              return (
                <TableRow key={v.id} data-state={chosen ? "selected" : undefined}>
                  <TableCell className="align-top">
                    <div className="font-medium">{names[v.wholesaler_id] ?? "Supplier"}</div>
                    <div className="text-xs text-muted-foreground">Revision {v.version}</div>
                    {credits.map((c) => (
                      <div key={c.wholesaler_id} className="mt-1 text-xs text-muted-foreground">
                        Credit: {c.payment_terms_days ?? 0} days · {formatGHS(c.available_ghs)}{" "}
                        available
                      </div>
                    ))}
                    {chosen && (
                      <Badge variant="default" className="mt-1 tabular-nums">
                        {chosen.lines} chosen · {formatGHS(chosen.total)}
                      </Badge>
                    )}
                  </TableCell>
                  <TableCell className="align-top text-sm tabular-nums">
                    <div>
                      {cover.quoted} of {cover.total} lines
                    </div>
                    <div className="mt-1 h-1.5 w-32 overflow-hidden rounded-full bg-muted">
                      <div
                        className="h-full bg-primary"
                        style={{
                          width: `${cover.total ? (cover.quoted / cover.total) * 100 : 0}%`,
                        }}
                      />
                    </div>
                    <div className="mt-1 text-xs text-muted-foreground">
                      {cover.complete} in full quantity
                    </div>
                  </TableCell>
                  <TableCell className="align-top text-right tabular-nums">
                    {formatGHS(q.total_ghs)}
                  </TableCell>
                  <TableCell className="align-top text-right tabular-nums">
                    {Number(q.delivery_charge_ghs) > 0 ? formatGHS(q.delivery_charge_ghs) : "Free"}
                  </TableCell>
                  <TableCell className="align-top text-right">
                    <div className="font-semibold tabular-nums">{formatGHS(landedTotal(v))}</div>
                    {landedTotal(v) === lowest && versions.length > 1 && (
                      <Badge variant="outline" className="mt-1 border-success/40 text-success">
                        Lowest total
                      </Badge>
                    )}
                  </TableCell>
                  <TableCell className="align-top text-xs text-muted-foreground">
                    <div>
                      Lead time:{" "}
                      {q.lead_time_days != null
                        ? `${q.lead_time_days} day${q.lead_time_days === 1 ? "" : "s"}`
                        : "not stated"}
                    </div>
                    <div>Valid until {rfqDate(q.valid_until)}</div>
                    <div>{q.payment_terms || "Payment terms not stated"}</div>
                  </TableCell>
                  <TableCell className="align-top">
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          className="gap-1"
                          disabled={busy}
                        >
                          Actions <ChevronDown className="h-3.5 w-3.5" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end" className="w-56">
                        {canManage && (
                          <>
                            <DropdownMenuItem onSelect={() => onWhole(v)}>
                              Choose the whole quotation
                            </DropdownMenuItem>
                            <DropdownMenuItem onSelect={() => onNegotiate(v)}>
                              Ask for revised terms…
                            </DropdownMenuItem>
                            <DropdownMenuSeparator />
                          </>
                        )}
                        <DropdownMenuItem onSelect={() => onPdf(v)}>
                          Download quotation PDF
                        </DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenu>
                    {history.length > 1 && (
                      <Popover>
                        <PopoverTrigger asChild>
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            className="mt-1 gap-1 text-xs"
                          >
                            <History className="h-3.5 w-3.5" /> {history.length} revisions
                          </Button>
                        </PopoverTrigger>
                        <PopoverContent align="end" className="w-80 space-y-2">
                          <p className="text-sm font-medium">Revision history</p>
                          <p className="text-xs text-muted-foreground">
                            Every version is kept exactly as sent.
                          </p>
                          {history.map((old) => (
                            <div key={old.id} className="rounded-md border p-2 text-xs">
                              <div className="font-medium">
                                Revision {old.version} · {formatGHS(landedTotal(old))}
                              </div>
                              <div className="text-muted-foreground">
                                {old.reason} · {rfqDateTime(old.created_at)}
                              </div>
                            </div>
                          ))}
                        </PopoverContent>
                      </Popover>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
