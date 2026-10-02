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
import { QuoteComparison } from "@/components/rfq/QuoteComparison";
import {
  RFQ_STATUS_LABELS,
  RFQ_STATUS_STYLES,
  summariseAward,
  validateAwardSelection,
  type AwardSelection,
  type Rfq,
  type RfqAward,
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
  const [selection, setSelection] = useState<AwardSelection>({});
  const [confirming, setConfirming] = useState(false);
  const [awardError, setAwardError] = useState<string | null>(null);
  const [awards, setAwards] = useState<RfqAward[]>([]);

  const load = useCallback(async () => {
    if (!rfqId) return;
    setLoading(true);
    const [{ data: rfqData }, { data: itemsData }, { data: inviteesData }, { data: quotesData }, { data: awardsData }] =
      await Promise.all([
        db.from("rfqs").select("*").eq("id", rfqId).maybeSingle(),
        db.from("rfq_items").select("*").eq("rfq_id", rfqId),
        db.from("rfq_invitees").select("*").eq("rfq_id", rfqId),
        db.from("rfq_quotes").select("*").eq("rfq_id", rfqId).order("total_ghs", { ascending: true }),
        db.from("rfq_awards").select("*").eq("rfq_id", rfqId),
      ]);
    setAwards((awardsData as RfqAward[] | null) ?? []);
    setSelection({});
    setConfirming(false);
    setAwardError(null);
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

  const allQuoteItems = Object.values(quoteItems).flat();
  const awardTotals = summariseAward(selection, quotes, allQuoteItems);

  const reviewAward = () => {
    const { error } = validateAwardSelection(selection, allQuoteItems, items);
    setAwardError(error);
    setConfirming(!error);
  };

  const confirmAward = async () => {
    if (!rfqId) return;
    const { error: validationError, payload } = validateAwardSelection(selection, allQuoteItems, items);
    if (validationError || !payload) {
      setAwardError(validationError);
      setConfirming(false);
      return;
    }
    setBusy(true);
    const { error } = await rpc("award_rfq_lines", { p_rfq_id: rfqId, p_awards: payload, p_use_credit: useCredit });
    setBusy(false);
    if (error) {
      setAwardError(error.message);
      setConfirming(false);
      return;
    }
    toast.success(awardTotals.length === 1 ? "Order created" : `${awardTotals.length} orders created`);
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
      <SheetContent className="w-full overflow-y-auto sm:max-w-5xl">
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
              <QuoteComparison
                items={items}
                quotes={quotes}
                quoteItems={allQuoteItems}
                suppliers={wholesalers}
                selection={selection}
                onSelectionChange={(next) => {
                  setSelection(next);
                  setConfirming(false);
                  setAwardError(null);
                }}
                canAward={canAward && rfq.status === "open"}
              />
              {quotes.some((q) => q.status !== "withdrawn" && q.delivery_notes) && (
                <ul className="mt-3 space-y-1 text-xs text-muted-foreground">
                  {quotes
                    .filter((q) => q.status !== "withdrawn" && q.delivery_notes)
                    .map((q) => (
                      <li key={q.id}>
                        <span className="font-medium text-foreground">{wholesalers[q.wholesaler_id]?.name ?? "Supplier"}:</span>{" "}
                        {q.delivery_notes}
                      </li>
                    ))}
                </ul>
              )}
              {awaitingInvitees.length > 0 && rfq.status === "open" && (
                <p className="mt-2 text-xs text-muted-foreground">
                  Still awaiting a response from {awaitingInvitees.length} supplier
                  {awaitingInvitees.length === 1 ? "" : "s"}.
                </p>
              )}
            </div>

            {canAward && rfq.status === "open" && quotes.some((q) => q.status === "submitted") && (
              <div className="mt-4 space-y-3 rounded-xl border border-border p-3">
                <label className="flex items-center gap-2 text-sm">
                  <Checkbox checked={useCredit} onCheckedChange={(c) => setUseCredit(c === true)} />
                  Pay on credit (each supplier must have approved credit for you)
                </label>
                {awardError && (
                  <p role="alert" className="text-sm text-destructive">
                    {awardError}
                  </p>
                )}
                {confirming && (
                  <div className="space-y-1 text-sm">
                    <p className="font-medium">
                      This will create {awardTotals.length} order{awardTotals.length === 1 ? "" : "s"}
                      {awardTotals.length > 1 ? " — one per supplier" : ""}:
                    </p>
                    <ul className="space-y-0.5 text-muted-foreground">
                      {awardTotals.map((t) => (
                        <li key={t.quoteId}>
                          {wholesalers[t.wholesalerId]?.name ?? "Supplier"}: {formatGHS(t.goods)} goods
                          {t.delivery > 0 ? ` + ${formatGHS(t.delivery)} delivery` : ""} = {formatGHS(t.total)}
                        </li>
                      ))}
                    </ul>
                    <p className="text-xs text-muted-foreground">
                      Suppliers with nothing awarded are told only that their quote wasn&apos;t selected. This can&apos;t be undone.
                    </p>
                  </div>
                )}
                <div className="flex flex-wrap gap-2">
                  {confirming ? (
                    <>
                      <Button type="button" disabled={busy} onClick={() => void confirmAward()}>
                        {busy ? "Placing orders..." : "Confirm award"}
                      </Button>
                      <Button type="button" variant="outline" disabled={busy} onClick={() => setConfirming(false)}>
                        Back
                      </Button>
                    </>
                  ) : (
                    <Button type="button" disabled={busy || awardTotals.length === 0} onClick={reviewAward}>
                      Review award
                    </Button>
                  )}
                  {Object.keys(selection).length > 0 && !confirming && (
                    <Button type="button" variant="ghost" onClick={() => setSelection({})}>
                      Clear selection
                    </Button>
                  )}
                </div>
                <p className="text-xs text-muted-foreground">
                  Nothing is awarded automatically. Enter the quantity to award to each supplier per item (you can split an
                  item between suppliers), or use &ldquo;Select whole quote&rdquo;.
                </p>
              </div>
            )}

            {rfq.status === "awarded" && awards.length > 0 && (
              <div className="mt-5">
                <h3 className="text-sm font-medium text-muted-foreground">Awarded</h3>
                <ul className="mt-2 divide-y divide-border rounded-xl border border-border text-sm">
                  {awards.map((a) => (
                    <li key={a.id} className="flex items-center justify-between gap-3 p-3">
                      <span>
                        {items.find((i) => i.id === a.rfq_item_id)?.product_name ?? "Item"} × {a.quantity}
                      </span>
                      <span className="text-muted-foreground">
                        {wholesalers[a.wholesaler_id]?.name ?? "Supplier"} · {formatGHS(a.unit_price_ghs)} each
                      </span>
                    </li>
                  ))}
                </ul>
                <p className="mt-2 text-xs text-muted-foreground">
                  An order was created for each supplier above. Track it under My orders.
                </p>
              </div>
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
