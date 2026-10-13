import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { formatReportDate, formatReportDateTime } from "@/lib/reports";
import {
  RFQ_QUOTE_STATUS_LABELS,
  RFQ_QUOTE_STATUS_STYLES,
  RFQ_STATUS_LABELS,
  RFQ_STATUS_STYLES,
  validateQuoteDraft,
  validateQuoteTerms,
  type QuoteLineDraft,
  type Rfq,
  type RfqItem,
  type RfqQuote,
  type RfqQuoteItem,
} from "@/lib/rfq";
import { legacyIssues, legacySummary } from "@/lib/rfq-legacy";
import { LegacyQuoteTable } from "./LegacyQuoteTable";
import type { OfferedProduct } from "./QuoteProductCombobox";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export function WholesalerRfqDetail({
  rfqId,
  wholesalerId,
  canQuote,
  open,
  onOpenChange,
  onChanged,
}: {
  rfqId: string | null;
  wholesalerId: string;
  canQuote: boolean;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onChanged: () => void;
}) {
  const [rfq, setRfq] = useState<Rfq | null>(null);
  const [items, setItems] = useState<RfqItem[]>([]);
  const [products, setProducts] = useState<Map<string, OfferedProduct>>(new Map());
  const [myQuote, setMyQuote] = useState<RfqQuote | null>(null);
  const [lines, setLines] = useState<QuoteLineDraft[]>([]);
  const [deliveryNotes, setDeliveryNotes] = useState("");
  const [validUntil, setValidUntil] = useState("");
  const [deliveryCharge, setDeliveryCharge] = useState("");
  const [leadTimeDays, setLeadTimeDays] = useState("");
  const [paymentTerms, setPaymentTerms] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmWithdraw, setConfirmWithdraw] = useState(false);

  const load = useCallback(async () => {
    if (!rfqId) return;
    setLoading(true);
    const [{ data: rfqData }, { data: itemsData }, { data: quoteData }] = await Promise.all([
      db.from("rfqs").select("*").eq("id", rfqId).maybeSingle(),
      db.from("rfq_items").select("*").eq("rfq_id", rfqId),
      db
        .from("rfq_quotes")
        .select("*")
        .eq("rfq_id", rfqId)
        .eq("wholesaler_id", wholesalerId)
        .maybeSingle(),
    ]);
    const rfqRow = (rfqData as Rfq) ?? null;
    const itemRows = (itemsData as RfqItem[]) ?? [];
    setRfq(rfqRow);
    setItems(itemRows);
    const quote = (quoteData as RfqQuote) ?? null;
    setMyQuote(quote);
    setDeliveryNotes(quote?.delivery_notes ?? "");
    setValidUntil(quote?.valid_until ? quote.valid_until.slice(0, 10) : "");
    setDeliveryCharge(
      quote && Number(quote.delivery_charge_ghs) > 0 ? String(quote.delivery_charge_ghs) : "",
    );
    setLeadTimeDays(quote?.lead_time_days != null ? String(quote.lead_time_days) : "");
    setPaymentTerms(quote?.payment_terms ?? "");

    let existingLines: RfqQuoteItem[] = [];
    if (quote) {
      const { data: lineData } = await db
        .from("rfq_quote_items")
        .select("*")
        .eq("rfq_quote_id", quote.id);
      existingLines = (lineData as RfqQuoteItem[] | null) ?? [];
    }
    setLines(
      itemRows.map((item) => {
        const existing = existingLines.find((l) => l.rfq_item_id === item.id);
        return {
          rfqItemId: item.id,
          productId: existing?.product_id ?? "",
          unitPriceGhs: existing ? String(existing.unit_price_ghs) : "",
          quantity:
            existing && existing.quantity !== item.quantity ? String(existing.quantity) : "",
          discountPercent:
            existing && Number(existing.discount_percent) > 0
              ? String(existing.discount_percent)
              : "",
          notes: existing?.notes ?? "",
          include: !!existing,
        };
      }),
    );
    setLoading(false);
  }, [rfqId, wholesalerId]);

  useEffect(() => {
    if (open && rfqId) void load();
  }, [open, rfqId, load]);

  // The lines only hold product ids: look up the names of the ones in use.
  const chosenKey = [...new Set(lines.map((l) => l.productId).filter(Boolean))].sort().join(",");
  useEffect(() => {
    const ids = chosenKey ? chosenKey.split(",") : [];
    const missing = ids.filter((id) => !products.has(id));
    if (!missing.length) return;
    let active = true;
    void supabase
      .from("products")
      .select("id, name, stock, price_ghs")
      .eq("wholesaler_id", wholesalerId)
      .in("id", missing)
      .then(({ data }) => {
        if (!active || !data) return;
        setProducts(
          (cur) => new Map([...cur, ...(data as OfferedProduct[]).map((p) => [p.id, p] as const)]),
        );
      });
    return () => {
      active = false;
    };
    // `products` is read only to find what is still missing; chosenKey drives the lookup.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chosenKey, wholesalerId]);

  const itemMap = useMemo(() => new Map(items.map((i) => [i.id, i])), [items]);
  const issues = useMemo(() => legacyIssues(lines, itemMap), [lines, itemMap]);
  const summary = legacySummary(lines, itemMap, issues);

  const submitQuote = async () => {
    const requested = Object.fromEntries(items.map((i) => [i.id, i.quantity]));
    const { error: validationError, included } = validateQuoteDraft(lines, requested);
    if (validationError || !included) {
      setError(validationError);
      return;
    }
    const { error: termsError } = validateQuoteTerms({
      deliveryCharge,
      leadTimeDays,
      paymentTerms,
    });
    if (termsError) {
      setError(termsError);
      return;
    }
    setError(null);
    setBusy(true);
    const { error: rpcError } = await rpc("submit_rfq_quote", {
      p_rfq_id: rfqId,
      p_wholesaler_id: wholesalerId,
      p_items: included.map((l) => ({
        rfqItemId: l.rfqItemId,
        productId: l.productId,
        unitPriceGhs: Number(l.unitPriceGhs),
        quantity: l.quantity.trim() ? Number(l.quantity) : null,
        discountPercent: l.discountPercent.trim() ? Number(l.discountPercent) : 0,
        notes: l.notes.trim() || null,
      })),
      p_delivery_notes: deliveryNotes.trim() || null,
      p_valid_until: validUntil ? new Date(validUntil).toISOString() : null,
      p_delivery_charge: deliveryCharge.trim() ? Number(deliveryCharge) : 0,
      p_lead_time_days: leadTimeDays.trim() ? Number(leadTimeDays) : null,
      p_payment_terms: paymentTerms.trim() || null,
    });
    setBusy(false);
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    toast.success(myQuote ? "Quote updated" : "Quote submitted");
    onChanged();
    void load();
  };

  const withdraw = async () => {
    setBusy(true);
    const { error: rpcError } = await rpc("withdraw_rfq_quote", {
      p_rfq_id: rfqId,
      p_wholesaler_id: wholesalerId,
    });
    setBusy(false);
    if (rpcError) {
      toast.error(rpcError.message);
      return;
    }
    toast.success("Quote withdrawn");
    onChanged();
    void load();
  };

  const canEditQuote =
    canQuote &&
    rfq?.status === "open" &&
    (!myQuote || myQuote.status === "submitted" || myQuote.status === "withdrawn");

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-6xl">
        {loading || !rfq ? (
          <div className="space-y-3 pt-6">
            <Skeleton className="h-6 w-2/3" />
            <Skeleton className="h-20 w-full" />
            <Skeleton className="h-32 w-full" />
          </div>
        ) : (
          <div className="space-y-5">
            <SheetHeader>
              <div className="flex flex-wrap items-center gap-2">
                <SheetTitle>{rfq.title}</SheetTitle>
                <Badge variant="secondary" className={`border ${RFQ_STATUS_STYLES[rfq.status]}`}>
                  {RFQ_STATUS_LABELS[rfq.status]}
                </Badge>
                {myQuote && (
                  <Badge
                    variant="secondary"
                    className={`border ${RFQ_QUOTE_STATUS_STYLES[myQuote.status]}`}
                  >
                    Your quote: {RFQ_QUOTE_STATUS_LABELS[myQuote.status]}
                  </Badge>
                )}
              </div>
              <SheetDescription>
                {rfq.reference}
                {rfq.response_deadline
                  ? ` · respond by ${formatReportDate(rfq.response_deadline)}`
                  : ""}
              </SheetDescription>
            </SheetHeader>

            {rfq.notes && <p className="text-sm text-muted-foreground">{rfq.notes}</p>}

            {myQuote && (
              <dl className="flex flex-wrap gap-x-8 gap-y-2 rounded-lg border bg-muted/30 px-4 py-3 text-sm">
                <div>
                  <dt className="text-xs uppercase tracking-wide text-muted-foreground">
                    Your current total
                  </dt>
                  <dd className="font-semibold tabular-nums">{formatGHS(myQuote.total_ghs)}</dd>
                </div>
                {Number(myQuote.delivery_charge_ghs) > 0 && (
                  <div>
                    <dt className="text-xs uppercase tracking-wide text-muted-foreground">
                      Delivery
                    </dt>
                    <dd className="font-medium tabular-nums">
                      {formatGHS(myQuote.delivery_charge_ghs)}
                    </dd>
                  </div>
                )}
                {myQuote.valid_until && (
                  <div>
                    <dt className="text-xs uppercase tracking-wide text-muted-foreground">
                      Valid until
                    </dt>
                    <dd className="font-medium">{formatReportDateTime(myQuote.valid_until)}</dd>
                  </div>
                )}
              </dl>
            )}

            <section className="space-y-2">
              <h3 className="text-sm font-medium text-muted-foreground">
                {canEditQuote ? "Choose what you can supply" : "Requested items"}
              </h3>
              <LegacyQuoteTable
                businessId={wholesalerId}
                items={items}
                lines={lines}
                onChange={setLines}
                issues={issues}
                products={products}
                onProducts={(found) =>
                  setProducts((cur) => new Map([...cur, ...found.map((p) => [p.id, p] as const)]))
                }
                editable={Boolean(canEditQuote)}
                disabled={busy}
              />
            </section>

            {canEditQuote && (
              <section className="space-y-3 rounded-lg border p-4">
                <h3 className="text-sm font-medium">Quotation terms</h3>
                <div className="space-y-1.5">
                  <Label htmlFor="delivery-notes">Delivery notes (optional)</Label>
                  <Textarea
                    id="delivery-notes"
                    value={deliveryNotes}
                    onChange={(e) => setDeliveryNotes(e.target.value)}
                    rows={2}
                  />
                </div>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-4">
                  <div className="space-y-1.5">
                    <Label htmlFor="delivery-charge">Delivery charge GHS (optional)</Label>
                    <Input
                      id="delivery-charge"
                      type="number"
                      min={0}
                      step="0.01"
                      value={deliveryCharge}
                      onChange={(e) => setDeliveryCharge(e.target.value)}
                    />
                  </div>
                  <div className="space-y-1.5">
                    <Label htmlFor="lead-time">Lead time, days (optional)</Label>
                    <Input
                      id="lead-time"
                      type="number"
                      min={0}
                      step="1"
                      value={leadTimeDays}
                      onChange={(e) => setLeadTimeDays(e.target.value)}
                    />
                  </div>
                  <div className="space-y-1.5">
                    <Label htmlFor="payment-terms">Payment terms (optional)</Label>
                    <Input
                      id="payment-terms"
                      maxLength={200}
                      placeholder="e.g. Net 14"
                      value={paymentTerms}
                      onChange={(e) => setPaymentTerms(e.target.value)}
                    />
                  </div>
                  <div className="space-y-1.5">
                    <Label htmlFor="valid-until">Quote valid until (optional)</Label>
                    <Input
                      id="valid-until"
                      type="date"
                      value={validUntil}
                      onChange={(e) => setValidUntil(e.target.value)}
                    />
                  </div>
                </div>
              </section>
            )}

            {canEditQuote && (
              <div className="sticky bottom-0 z-10 -mx-6 border-t bg-background/95 px-6 py-3 backdrop-blur">
                {error && (
                  <p
                    role="alert"
                    className="mb-3 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
                  >
                    {error}
                  </p>
                )}
                <div className="flex flex-wrap items-center gap-3">
                  <p className="text-sm tabular-nums text-muted-foreground">
                    {summary.included} of {summary.total} items quoted
                    {summary.included > 0 && ` · estimated ${formatGHS(summary.estimate)}`}
                    {summary.withIssues > 0 && (
                      <span className="ml-2 text-destructive">
                        {summary.withIssues} need attention
                      </span>
                    )}
                  </p>
                  <div className="ml-auto flex flex-wrap gap-2">
                    {myQuote && myQuote.status === "submitted" && (
                      <Button
                        type="button"
                        variant="outline"
                        disabled={busy}
                        onClick={() => setConfirmWithdraw(true)}
                      >
                        Withdraw quote
                      </Button>
                    )}
                    <Button type="button" disabled={busy} onClick={() => void submitQuote()}>
                      {myQuote && myQuote.status !== "withdrawn" ? "Update quote" : "Submit quote"}
                    </Button>
                  </div>
                </div>
              </div>
            )}
          </div>
        )}
        <AlertDialog open={confirmWithdraw} onOpenChange={setConfirmWithdraw}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Withdraw your quote?</AlertDialogTitle>
              <AlertDialogDescription>
                The buyer will no longer be able to award from it. You can submit a new quote while
                the request is still open.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Keep my quote</AlertDialogCancel>
              <AlertDialogAction
                onClick={() => {
                  setConfirmWithdraw(false);
                  void withdraw();
                }}
              >
                Withdraw quote
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </SheetContent>
    </Sheet>
  );
}
