import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { formatGHS } from "@/lib/format";
import { formatReportDate } from "@/lib/reports";
import {
  RFQ_QUOTE_STATUS_LABELS,
  RFQ_QUOTE_STATUS_STYLES,
  cheapestLineIds,
  selectEntireQuote,
  summariseAward,
  type AwardSelection,
  type RfqItem,
  type RfqQuote,
  type RfqQuoteItem,
} from "@/lib/rfq";

/** Side-by-side comparison of every supplier's quote, one row per requested item. Nothing here is
 * chosen for the pharmacy: the cheapest line is only marked, and the pharmacy decides the award
 * quantity for each supplier on each line (so a line can be won by one supplier, split between
 * several, or left unawarded). */
export function QuoteComparison({
  items,
  quotes,
  quoteItems,
  suppliers,
  selection,
  onSelectionChange,
  canAward,
}: {
  items: RfqItem[];
  quotes: RfqQuote[];
  quoteItems: RfqQuoteItem[];
  suppliers: Record<string, { id: string; name: string }>;
  selection: AwardSelection;
  onSelectionChange: (selection: AwardSelection) => void;
  canAward: boolean;
}) {
  const visibleQuotes = quotes.filter((q) => q.status !== "withdrawn");
  const lines = quoteItems.filter((l) => visibleQuotes.some((q) => q.id === l.rfq_quote_id));
  const cheapest = cheapestLineIds(lines);
  const totals = summariseAward(selection, visibleQuotes, lines);
  const awardable = (quote: RfqQuote) => canAward && quote.status === "submitted";

  const setQuantity = (lineId: string, value: string) => {
    const next = { ...selection };
    if (value.trim() === "") delete next[lineId];
    else next[lineId] = value;
    onSelectionChange(next);
  };

  if (visibleQuotes.length === 0)
    return <p className="mt-2 text-sm text-muted-foreground">No quotes yet.</p>;

  return (
    <div className="mt-2 overflow-x-auto rounded-xl border border-border">
      <table className="min-w-full border-collapse text-left text-sm">
        <thead className="bg-muted/40 text-xs">
          <tr>
            <th
              scope="col"
              className="sticky left-0 z-10 min-w-[9rem] bg-muted px-3 py-2 font-medium"
            >
              Requested item
            </th>
            {visibleQuotes.map((quote) => (
              <th
                key={quote.id}
                scope="col"
                className="min-w-[11rem] px-3 py-2 align-top font-medium"
              >
                <div>{suppliers[quote.wholesaler_id]?.name ?? "Supplier"}</div>
                <Badge
                  variant="secondary"
                  className={`mt-1 border ${RFQ_QUOTE_STATUS_STYLES[quote.status]}`}
                >
                  {RFQ_QUOTE_STATUS_LABELS[quote.status]}
                </Badge>
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {items.map((item) => (
            <tr key={item.id} className="align-top">
              <th scope="row" className="sticky left-0 z-10 bg-background px-3 py-2 font-medium">
                {item.product_name}
                <div className="text-xs font-normal text-muted-foreground">
                  {item.quantity} requested
                </div>
              </th>
              {visibleQuotes.map((quote) => {
                const line = lines.find(
                  (l) => l.rfq_quote_id === quote.id && l.rfq_item_id === item.id,
                );
                if (!line) {
                  return (
                    <td key={quote.id} className="px-3 py-2 text-xs text-muted-foreground">
                      Not quoted
                    </td>
                  );
                }
                const partial = line.quantity < item.quantity;
                return (
                  <td key={quote.id} className="px-3 py-2">
                    <div className="font-medium">
                      {formatGHS(line.final_unit_price_ghs)}
                      {Number(line.discount_percent) > 0 && (
                        <span className="ml-1 text-xs font-normal text-muted-foreground line-through">
                          {formatGHS(line.unit_price_ghs)}
                        </span>
                      )}
                    </div>
                    <div className="text-xs text-muted-foreground">
                      {line.quantity} available{partial ? " (partial)" : ""}
                      {Number(line.discount_percent) > 0 ? ` · ${line.discount_percent}% off` : ""}
                    </div>
                    {cheapest.has(line.id) &&
                      lines.filter((l) => l.rfq_item_id === item.id).length > 1 && (
                        <Badge variant="outline" className="mt-1 border-success/40 text-success">
                          Lowest price
                        </Badge>
                      )}
                    {line.notes && (
                      <div className="mt-1 text-xs text-muted-foreground">{line.notes}</div>
                    )}
                    {awardable(quote) && (
                      <label className="mt-2 flex items-center gap-1.5 text-xs">
                        Award
                        <Input
                          type="number"
                          min={0}
                          max={line.quantity}
                          value={selection[line.id] ?? ""}
                          onChange={(e) => setQuantity(line.id, e.target.value)}
                          className="h-8 w-20"
                          aria-label={`Quantity to award to ${suppliers[quote.wholesaler_id]?.name ?? "supplier"} for ${item.product_name}`}
                        />
                      </label>
                    )}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
        <tfoot className="border-t-2 border-border bg-muted/20 text-xs">
          <tr>
            <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2 font-medium">
              Goods total
            </th>
            {visibleQuotes.map((q) => (
              <td key={q.id} className="px-3 py-2">
                {formatGHS(q.total_ghs)}
              </td>
            ))}
          </tr>
          <tr>
            <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2 font-medium">
              Delivery charge
            </th>
            {visibleQuotes.map((q) => (
              <td key={q.id} className="px-3 py-2">
                {Number(q.delivery_charge_ghs) > 0
                  ? formatGHS(q.delivery_charge_ghs)
                  : "None quoted"}
              </td>
            ))}
          </tr>
          <tr>
            <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2 font-medium">
              Lead time
            </th>
            {visibleQuotes.map((q) => (
              <td key={q.id} className="px-3 py-2">
                {q.lead_time_days != null
                  ? `${q.lead_time_days} day${q.lead_time_days === 1 ? "" : "s"}`
                  : "Not stated"}
              </td>
            ))}
          </tr>
          <tr>
            <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2 font-medium">
              Payment terms
            </th>
            {visibleQuotes.map((q) => (
              <td key={q.id} className="px-3 py-2">
                {q.payment_terms ?? "Not stated"}
              </td>
            ))}
          </tr>
          <tr>
            <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2 font-medium">
              Valid until
            </th>
            {visibleQuotes.map((q) => (
              <td key={q.id} className="px-3 py-2">
                {q.valid_until ? formatReportDate(q.valid_until) : "Not stated"}
              </td>
            ))}
          </tr>
          <tr className="text-sm font-semibold">
            <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2">
              Total quote value
            </th>
            {visibleQuotes.map((q) => (
              <td key={q.id} className="px-3 py-2">
                {formatGHS(Number(q.total_ghs) + Number(q.delivery_charge_ghs || 0))}
              </td>
            ))}
          </tr>
          {canAward && (
            <>
              <tr>
                <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2 font-medium">
                  Your selection
                </th>
                {visibleQuotes.map((q) => {
                  const total = totals.find((t) => t.quoteId === q.id);
                  return (
                    <td key={q.id} className="px-3 py-2">
                      {total
                        ? `${formatGHS(total.total)} (${total.lines} line${total.lines === 1 ? "" : "s"})`
                        : "—"}
                    </td>
                  );
                })}
              </tr>
              <tr>
                <th scope="row" className="sticky left-0 z-10 bg-muted px-3 py-2" />
                {visibleQuotes.map((q) => (
                  <td key={q.id} className="px-3 py-2">
                    {q.status === "submitted" && (
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        onClick={() => onSelectionChange(selectEntireQuote(q.id, lines))}
                      >
                        Select whole quote
                      </Button>
                    )}
                  </td>
                ))}
              </tr>
            </>
          )}
        </tfoot>
      </table>
    </div>
  );
}
