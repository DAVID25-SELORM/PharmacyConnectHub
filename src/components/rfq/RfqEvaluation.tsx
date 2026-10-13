import { useCallback, useMemo, useState } from "react";
import { AlertTriangle, Wand2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  compareVersions,
  remainingRequirement,
  type Allocation,
  type AwardGroup,
  type QuoteVersion,
  type Requirement,
} from "@/lib/enterprise-rfq";
import { formatGHS } from "@/lib/format";
import {
  RFQ_MAX_ALLOCATIONS,
  allocationPayload,
  cheapestPlan,
  selectionIssues,
  selectionTotals,
  wholeQuote,
  type Accepted,
  type Selection,
} from "@/lib/rfq-evaluation";
import { RFQ_CATEGORY_OPTIONS, RFQ_PAYMENT_OPTIONS } from "@/lib/rfq-format";
import { RfqComparisonMatrix } from "./RfqComparisonMatrix";
import { RfqNegotiateDialog } from "./RfqNegotiateDialog";
import { RfqQuoteOverview, type CreditInfo } from "./RfqQuoteOverview";

const selectClass =
  "h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring";

/** The buyer's evaluation of quotations: compare suppliers, choose quantities line by line, review and award. */
export function RfqEvaluation({
  items,
  current,
  versions,
  names,
  credit,
  groups,
  allocations,
  canManage,
  busy,
  onAward,
  onNegotiate,
  onPdf,
}: {
  items: Requirement[];
  /** Each supplier's latest version. */
  current: QuoteVersion[];
  /** Every version, for revision history. */
  versions: QuoteVersion[];
  names: Record<string, string>;
  credit: CreditInfo[];
  groups: AwardGroup[];
  allocations: Allocation[];
  canManage: boolean;
  busy: boolean;
  onAward: (request: {
    allocations: ReturnType<typeof allocationPayload>;
    settlement: string;
  }) => Promise<boolean>;
  onNegotiate: (version: QuoteVersion, term: string, value: string) => Promise<boolean>;
  onPdf: (version: QuoteVersion) => void;
}) {
  const [sort, setSort] = useState("cost");
  const [selection, setSelection] = useState<Selection>({});
  const [accepted, setAccepted] = useState<Accepted>({});
  const [category, setCategory] = useState("cash_private");
  const [settlement, setSettlement] = useState("cod");
  const [reviewing, setReviewing] = useState(false);
  const [negotiating, setNegotiating] = useState<QuoteVersion | null>(null);

  const remaining = useCallback(
    (item: Requirement) => remainingRequirement(item, allocations, groups),
    [allocations, groups],
  );
  const ordered = useMemo(
    () =>
      sort === "credit"
        ? [...current].sort(
            (a, b) =>
              (credit.find((c) => c.wholesaler_id === b.wholesaler_id && c.status === "active")
                ?.payment_terms_days ?? 0) -
                (credit.find((c) => c.wholesaler_id === a.wholesaler_id && c.status === "active")
                  ?.payment_terms_days ?? 0) || a.id.localeCompare(b.id),
          )
        : compareVersions(current, sort),
    [current, credit, sort],
  );
  const issues = useMemo(
    () => selectionIssues(items, current, selection, accepted, remaining),
    [items, current, selection, accepted, remaining],
  );
  const totals = useMemo(() => selectionTotals(current, selection), [current, selection]);
  const chosenLines = totals.reduce((n, t) => n + t.lines, 0);
  const chosenValue = totals.reduce((n, t) => n + t.total, 0);
  const tooMany = chosenLines > RFQ_MAX_ALLOCATIONS;
  const problem =
    issues.size > 0
      ? `${issues.size} choice${issues.size === 1 ? " needs" : "s need"} attention.`
      : tooMany
        ? `Choose at most ${RFQ_MAX_ALLOCATIONS} lines per award.`
        : "";

  if (current.length === 0)
    return <p className="text-sm text-muted-foreground">No quotations have been submitted yet.</p>;

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between sm:space-y-0">
          <div className="space-y-1.5">
            <CardTitle className="text-lg">Compare quotations</CardTitle>
            <CardDescription>
              Each supplier's latest submitted version. Sorting uses stated terms and is not a
              recommendation of therapeutic suitability; review specification differences, minimum
              orders and quantity coverage.
            </CardDescription>
          </div>
          <select
            aria-label="Sort quotations"
            className={`${selectClass} sm:w-60`}
            value={sort}
            onChange={(e) => setSort(e.target.value)}
          >
            <option value="cost">Lowest landed total</option>
            <option value="delivery">Fastest stated delivery</option>
            <option value="quantity">Highest offered quantity</option>
            {canManage && <option value="credit">Longest approved credit term</option>}
          </select>
        </CardHeader>
        <CardContent>
          <RfqQuoteOverview
            versions={ordered}
            allVersions={versions}
            items={items}
            names={names}
            credit={credit}
            totals={totals}
            canManage={canManage}
            busy={busy}
            onWhole={(v) => setSelection(wholeQuote(v))}
            onNegotiate={setNegotiating}
            onPdf={onPdf}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Requirement by requirement</CardTitle>
          <CardDescription>
            {canManage
              ? "Choose how many units to award to each supplier on each line: one supplier, a split, or none. "
              : ""}
            Stock shown is a submission-time observation, not a reservation. Catalogue matching does
            not independently verify regulatory authorisation or registration.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <RfqComparisonMatrix
            items={items}
            versions={ordered}
            names={names}
            selection={selection}
            accepted={accepted}
            issues={issues}
            remaining={remaining}
            canAward={canManage}
            onSelect={(id, value) => setSelection((s) => ({ ...s, [id]: value }))}
            onAccept={(id, on) => setAccepted((a) => ({ ...a, [id]: on }))}
            tools={
              canManage && (
                <>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="gap-1.5"
                    disabled={busy}
                    onClick={() => setSelection(cheapestPlan(items, current, remaining))}
                  >
                    <Wand2 className="h-4 w-4" /> Start from lowest prices
                  </Button>
                  {chosenLines > 0 && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      onClick={() => setSelection({})}
                    >
                      Clear choices
                    </Button>
                  )}
                </>
              )
            }
          />
        </CardContent>
      </Card>

      {canManage && (
        <div className="sticky bottom-0 z-10 -mx-4 border-t bg-background/95 px-4 py-3 backdrop-blur sm:mx-0 sm:rounded-lg sm:border">
          <div className="flex flex-wrap items-center gap-3">
            <div className="text-sm">
              {chosenLines === 0 ? (
                <span className="text-muted-foreground">Nothing chosen yet.</span>
              ) : (
                <span className="tabular-nums">
                  <strong>{chosenLines}</strong> line{chosenLines === 1 ? "" : "s"} from{" "}
                  <strong>{totals.length}</strong> supplier{totals.length === 1 ? "" : "s"} ·{" "}
                  <strong>{formatGHS(chosenValue)}</strong> with delivery
                </span>
              )}
              {problem && (
                <span className="ml-3 inline-flex items-center gap-1 text-xs text-destructive">
                  <AlertTriangle className="h-3.5 w-3.5" /> {problem}
                </span>
              )}
            </div>
            <Button
              type="button"
              className="ml-auto"
              disabled={busy || chosenLines === 0 || Boolean(problem)}
              onClick={() => setReviewing(true)}
            >
              Review allocations
            </Button>
          </div>
        </div>
      )}

      {reviewing && (
        <Dialog open onOpenChange={(open) => !open && setReviewing(false)}>
          <DialogContent className="max-w-2xl">
            <DialogHeader>
              <DialogTitle>Review allocations</DialogTitle>
              <DialogDescription>
                Suppliers must confirm before orders are created. Requirements you have not chosen
                remain unresolved.
              </DialogDescription>
            </DialogHeader>
            <div className="overflow-hidden rounded-md border">
              <Table>
                <TableHeader>
                  <TableRow className="bg-muted/40 hover:bg-muted/40">
                    <TableHead>Supplier</TableHead>
                    <TableHead className="w-20 text-right">Lines</TableHead>
                    <TableHead className="w-28 text-right">Goods</TableHead>
                    <TableHead className="w-24 text-right">Delivery</TableHead>
                    <TableHead className="w-28 text-right">Total</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {totals.map((t) => {
                    const v = current.find((c) => c.id === t.versionId)!;
                    return (
                      <TableRow key={t.versionId}>
                        <TableCell className="font-medium">
                          {names[v.wholesaler_id] ?? "Supplier"}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">{t.lines}</TableCell>
                        <TableCell className="text-right tabular-nums">
                          {formatGHS(t.goods)}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {t.delivery > 0 ? formatGHS(t.delivery) : "Free"}
                        </TableCell>
                        <TableCell className="text-right font-semibold tabular-nums">
                          {formatGHS(t.total)}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                  <TableRow className="bg-muted/30 hover:bg-muted/30">
                    <TableCell colSpan={4} className="text-right font-medium">
                      Total
                    </TableCell>
                    <TableCell className="text-right font-semibold tabular-nums">
                      {formatGHS(chosenValue)}
                    </TableCell>
                  </TableRow>
                </TableBody>
              </Table>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <label className="block space-y-1.5">
                <span className="text-sm font-medium">Order classification</span>
                <select
                  className={selectClass}
                  value={category}
                  onChange={(e) => setCategory(e.target.value)}
                >
                  {RFQ_CATEGORY_OPTIONS.map(([value, text]) => (
                    <option key={value} value={value}>
                      {text}
                    </option>
                  ))}
                </select>
              </label>
              <label className="block space-y-1.5">
                <span className="text-sm font-medium">Settlement</span>
                <select
                  className={selectClass}
                  value={settlement}
                  onChange={(e) => setSettlement(e.target.value)}
                >
                  {RFQ_PAYMENT_OPTIONS.map(([value, text]) => (
                    <option key={value} value={value}>
                      {text}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setReviewing(false)}>
                Back to edit
              </Button>
              <Button
                type="button"
                disabled={busy}
                onClick={async () => {
                  const ok = await onAward({
                    allocations: allocationPayload(current, selection, accepted, category),
                    settlement,
                  });
                  if (ok) setReviewing(false);
                }}
              >
                {busy ? "Sending…" : "Confirm pending awards"}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}

      {negotiating && (
        <RfqNegotiateDialog
          supplier={names[negotiating.wholesaler_id] ?? "this supplier"}
          busy={busy}
          onClose={() => setNegotiating(null)}
          onSubmit={(term, value) => onNegotiate(negotiating, term, value)}
        />
      )}
    </div>
  );
}
