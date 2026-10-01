import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { formatReportDate, formatReportDateTime } from "@/lib/reports";
import {
  RFQ_QUOTE_STATUS_LABELS,
  RFQ_QUOTE_STATUS_STYLES,
  RFQ_STATUS_LABELS,
  RFQ_STATUS_STYLES,
  type Rfq,
  type RfqInvitee,
  type RfqItem,
  type RfqQuote,
  type RfqQuoteItem,
} from "@/lib/rfq";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);
// The rfq_* tables aren't in the generated Supabase types yet (see credit-ledger.ts's own `rpc`
// helper above for the established precedent of not regenerating types.ts for every new table).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Business = { id: string; name: string };

export function PharmacyRfqDetail({
  rfqId,
  canAward,
  canCancel,
  open,
  onOpenChange,
  onChanged,
}: {
  rfqId: string | null;
  canAward: boolean;
  canCancel: boolean;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onChanged: () => void;
}) {
  const [rfq, setRfq] = useState<Rfq | null>(null);
  const [items, setItems] = useState<RfqItem[]>([]);
  const [invitees, setInvitees] = useState<RfqInvitee[]>([]);
  const [quotes, setQuotes] = useState<RfqQuote[]>([]);
  const [quoteItems, setQuoteItems] = useState<Record<string, RfqQuoteItem[]>>({});
  const [wholesalers, setWholesalers] = useState<Record<string, Business>>({});
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [useCredit, setUseCredit] = useState(false);

  const load = useCallback(async () => {
    if (!rfqId) return;
    setLoading(true);
    const [{ data: rfqData }, { data: itemsData }, { data: inviteesData }, { data: quotesData }] =
      await Promise.all([
        db.from("rfqs").select("*").eq("id", rfqId).maybeSingle(),
        db.from("rfq_items").select("*").eq("rfq_id", rfqId),
        db.from("rfq_invitees").select("*").eq("rfq_id", rfqId),
        db.from("rfq_quotes").select("*").eq("rfq_id", rfqId).order("total_ghs", { ascending: true }),
      ]);
    setRfq((rfqData as Rfq) ?? null);
    setItems((itemsData as RfqItem[]) ?? []);
    setInvitees((inviteesData as RfqInvitee[]) ?? []);
    const quoteRows = (quotesData as RfqQuote[]) ?? [];
    setQuotes(quoteRows);

    const wholesalerIds = [
      ...new Set([...(inviteesData ?? []).map((i: RfqInvitee) => i.wholesaler_id), ...quoteRows.map((q) => q.wholesaler_id)]),
    ];
    if (wholesalerIds.length > 0) {
      const { data: bizData } = await supabase.from("businesses").select("id, name").in("id", wholesalerIds);
      const map: Record<string, Business> = {};
      for (const b of (bizData as Business[] | null) ?? []) map[b.id] = b;
      setWholesalers(map);
    }

    if (quoteRows.length > 0) {
      const { data: itemRows } = await db
        .from("rfq_quote_items")
        .select("*")
        .in("rfq_quote_id", quoteRows.map((q) => q.id));
      const grouped: Record<string, RfqQuoteItem[]> = {};
      for (const row of (itemRows as RfqQuoteItem[] | null) ?? []) {
        (grouped[row.rfq_quote_id] ??= []).push(row);
      }
      setQuoteItems(grouped);
    } else {
      setQuoteItems({});
    }
    setLoading(false);
  }, [rfqId]);

  useEffect(() => {
    if (open && rfqId) void load();
  }, [open, rfqId, load]);

  const award = async (quoteId: string) => {
    if (!rfqId) return;
    setBusy(true);
    const { error } = await rpc("award_rfq_quote", { p_rfq_id: rfqId, p_quote_id: quoteId, p_use_credit: useCredit });
    setBusy(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("Quote accepted - order created");
    onChanged();
    void load();
  };

  const cancel = async () => {
    if (!rfqId) return;
    setBusy(true);
    const { error } = await rpc("cancel_rfq", { p_rfq_id: rfqId });
    setBusy(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("RFQ cancelled");
    onChanged();
    void load();
  };

  const respondedWholesalerIds = new Set(quotes.filter((q) => q.status !== "withdrawn").map((q) => q.wholesaler_id));
  const awaitingInvitees = invitees.filter((i) => !respondedWholesalerIds.has(i.wholesaler_id));

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
        {loading || !rfq ? (
          <div className="space-y-3 pt-6">
            <Skeleton className="h-6 w-2/3" />
            <Skeleton className="h-20 w-full" />
            <Skeleton className="h-32 w-full" />
          </div>
        ) : (
          <>
            <SheetHeader>
              <div className="flex flex-wrap items-center gap-2">
                <SheetTitle>{rfq.title}</SheetTitle>
                <Badge variant="secondary" className={`border ${RFQ_STATUS_STYLES[rfq.status]}`}>
                  {RFQ_STATUS_LABELS[rfq.status]}
                </Badge>
              </div>
              <SheetDescription>
                {rfq.reference} · Requested {formatReportDate(rfq.created_at)}
                {rfq.response_deadline ? ` · responses due ${formatReportDate(rfq.response_deadline)}` : ""}
              </SheetDescription>
            </SheetHeader>

            {rfq.notes && <p className="mt-4 text-sm text-muted-foreground">{rfq.notes}</p>}

            <div className="mt-5">
              <h3 className="text-sm font-medium text-muted-foreground">Items requested</h3>
              <ul className="mt-2 divide-y divide-border rounded-xl border border-border text-sm">
                {items.map((item) => (
                  <li key={item.id} className="flex items-center justify-between gap-3 p-3">
                    <span>{item.product_name}</span>
                    <span className="text-muted-foreground">
                      {item.quantity} unit{item.quantity === 1 ? "" : "s"}
                      {item.notes ? ` · ${item.notes}` : ""}
                    </span>
                  </li>
                ))}
              </ul>
            </div>

            <div className="mt-5">
              <h3 className="text-sm font-medium text-muted-foreground">
                Quotes received ({quotes.filter((q) => q.status !== "withdrawn").length})
              </h3>
              {quotes.length === 0 ? (
                <p className="mt-2 text-sm text-muted-foreground">No quotes yet.</p>
              ) : (
                <div className="mt-2 space-y-3">
                  {quotes.map((quote) => {
                    const lines = quoteItems[quote.id] ?? [];
                    return (
                      <div key={quote.id} className="rounded-xl border border-border p-3">
                        <div className="flex flex-wrap items-center justify-between gap-2">
                          <div className="font-medium">{wholesalers[quote.wholesaler_id]?.name ?? "Supplier"}</div>
                          <Badge variant="secondary" className={`border ${RFQ_QUOTE_STATUS_STYLES[quote.status]}`}>
                            {RFQ_QUOTE_STATUS_LABELS[quote.status]}
                          </Badge>
                        </div>
                        <div className="mt-1 text-lg font-display font-bold">{formatGHS(quote.total_ghs)}</div>
                        {quote.delivery_notes && (
                          <p className="mt-1 text-xs text-muted-foreground">{quote.delivery_notes}</p>
                        )}
                        {quote.valid_until && (
                          <p className="text-xs text-muted-foreground">
                            Valid until {formatReportDateTime(quote.valid_until)}
                          </p>
                        )}
                        <ul className="mt-2 space-y-1 text-xs text-muted-foreground">
                          {lines.map((line) => {
                            const item = items.find((i) => i.id === line.rfq_item_id);
                            return (
                              <li key={line.id} className="flex items-center justify-between gap-2">
                                <span>
                                  {item?.product_name ?? "Item"} × {line.quantity}
                                </span>
                                <span>
                                  {formatGHS(line.unit_price_ghs)} each · {formatGHS(line.line_total_ghs)}
                                </span>
                              </li>
                            );
                          })}
                        </ul>
                        {canAward && rfq.status === "open" && quote.status === "submitted" && (
                          <Button
                            type="button"
                            size="sm"
                            className="mt-3"
                            disabled={busy}
                            onClick={() => void award(quote.id)}
                          >
                            Accept this quote
                          </Button>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
              {awaitingInvitees.length > 0 && rfq.status === "open" && (
                <p className="mt-2 text-xs text-muted-foreground">
                  Still awaiting a response from {awaitingInvitees.length} supplier
                  {awaitingInvitees.length === 1 ? "" : "s"}.
                </p>
              )}
            </div>

            {canAward && rfq.status === "open" && quotes.some((q) => q.status === "submitted") && (
              <label className="mt-4 flex items-center gap-2 text-sm">
                <Checkbox checked={useCredit} onCheckedChange={(c) => setUseCredit(c === true)} />
                Pay on credit (if the supplier has approved credit for you)
              </label>
            )}

            {canCancel && rfq.status === "open" && (
              <Button
                type="button"
                variant="outline"
                className="mt-5"
                disabled={busy}
                onClick={() => void cancel()}
              >
                Cancel this RFQ
              </Button>
            )}
          </>
        )}
      </SheetContent>
    </Sheet>
  );
}
