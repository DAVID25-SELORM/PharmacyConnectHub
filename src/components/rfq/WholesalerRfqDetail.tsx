import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
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
  type QuoteLineDraft,
  type Rfq,
  type RfqItem,
  type RfqQuote,
  type RfqQuoteItem,
} from "@/lib/rfq";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Product = { id: string; name: string };

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
  const [products, setProducts] = useState<Product[]>([]);
  const [myQuote, setMyQuote] = useState<RfqQuote | null>(null);
  const [lines, setLines] = useState<QuoteLineDraft[]>([]);
  const [deliveryNotes, setDeliveryNotes] = useState("");
  const [validUntil, setValidUntil] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!rfqId) return;
    setLoading(true);
    const [{ data: rfqData }, { data: itemsData }, { data: productsData }, { data: quoteData }] =
      await Promise.all([
        db.from("rfqs").select("*").eq("id", rfqId).maybeSingle(),
        db.from("rfq_items").select("*").eq("rfq_id", rfqId),
        supabase.from("products").select("id, name").eq("wholesaler_id", wholesalerId).eq("active", true).order("name"),
        db.from("rfq_quotes").select("*").eq("rfq_id", rfqId).eq("wholesaler_id", wholesalerId).maybeSingle(),
      ]);
    const rfqRow = (rfqData as Rfq) ?? null;
    const itemRows = (itemsData as RfqItem[]) ?? [];
    setRfq(rfqRow);
    setItems(itemRows);
    setProducts((productsData as Product[] | null) ?? []);
    const quote = (quoteData as RfqQuote) ?? null;
    setMyQuote(quote);
    setDeliveryNotes(quote?.delivery_notes ?? "");
    setValidUntil(quote?.valid_until ? quote.valid_until.slice(0, 10) : "");

    let existingLines: RfqQuoteItem[] = [];
    if (quote) {
      const { data: lineData } = await db.from("rfq_quote_items").select("*").eq("rfq_quote_id", quote.id);
      existingLines = (lineData as RfqQuoteItem[] | null) ?? [];
    }
    setLines(
      itemRows.map((item) => {
        const existing = existingLines.find((l) => l.rfq_item_id === item.id);
        return {
          rfqItemId: item.id,
          productId: existing?.product_id ?? "",
          unitPriceGhs: existing ? String(existing.unit_price_ghs) : "",
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

  const updateLine = (rfqItemId: string, patch: Partial<QuoteLineDraft>) => {
    setLines((prev) => prev.map((l) => (l.rfqItemId === rfqItemId ? { ...l, ...patch } : l)));
  };

  const submitQuote = async () => {
    const { error: validationError, included } = validateQuoteDraft(lines);
    if (validationError || !included) {
      setError(validationError);
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
        notes: l.notes.trim() || null,
      })),
      p_delivery_notes: deliveryNotes.trim() || null,
      p_valid_until: validUntil ? new Date(validUntil).toISOString() : null,
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
    const { error: rpcError } = await rpc("withdraw_rfq_quote", { p_rfq_id: rfqId, p_wholesaler_id: wholesalerId });
    setBusy(false);
    if (rpcError) {
      toast.error(rpcError.message);
      return;
    }
    toast.success("Quote withdrawn");
    onChanged();
    void load();
  };

  const canEditQuote = canQuote && rfq?.status === "open" && (!myQuote || myQuote.status === "submitted" || myQuote.status === "withdrawn");

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
                {myQuote && (
                  <Badge variant="secondary" className={`border ${RFQ_QUOTE_STATUS_STYLES[myQuote.status]}`}>
                    Your quote: {RFQ_QUOTE_STATUS_LABELS[myQuote.status]}
                  </Badge>
                )}
              </div>
              <SheetDescription>
                {rfq.reference}
                {rfq.response_deadline ? ` · respond by ${formatReportDate(rfq.response_deadline)}` : ""}
              </SheetDescription>
            </SheetHeader>

            {rfq.notes && <p className="mt-4 text-sm text-muted-foreground">{rfq.notes}</p>}

            {myQuote && (
              <p className="mt-3 text-sm">
                Your current total: <span className="font-semibold">{formatGHS(myQuote.total_ghs)}</span>
              </p>
            )}

            <div className="mt-5 space-y-3">
              <h3 className="text-sm font-medium text-muted-foreground">
                {canEditQuote ? "Choose what you can supply" : "Requested items"}
              </h3>
              {items.map((item) => {
                const line = lines.find((l) => l.rfqItemId === item.id);
                if (!line) return null;
                return (
                  <div key={item.id} className="rounded-xl border border-border p-3">
                    <div className="flex items-start gap-2">
                      {canEditQuote && (
                        <Checkbox
                          className="mt-1"
                          checked={line.include}
                          onCheckedChange={(c) => updateLine(item.id, { include: c === true })}
                        />
                      )}
                      <div className="flex-1">
                        <div className="font-medium">
                          {item.product_name} · {item.quantity} unit{item.quantity === 1 ? "" : "s"}
                        </div>
                        {item.notes && <div className="text-xs text-muted-foreground">{item.notes}</div>}
                      </div>
                    </div>

                    {canEditQuote && line.include && (
                      <div className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-2">
                        <div className="space-y-1">
                          <Label className="text-xs">Your product</Label>
                          <select
                            className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                            value={line.productId}
                            onChange={(e) => updateLine(item.id, { productId: e.target.value })}
                          >
                            <option value="">Select a product</option>
                            {products.map((p) => (
                              <option key={p.id} value={p.id}>
                                {p.name}
                              </option>
                            ))}
                          </select>
                        </div>
                        <div className="space-y-1">
                          <Label className="text-xs">Unit price (GHS)</Label>
                          <Input
                            type="number"
                            min={0}
                            step="0.01"
                            value={line.unitPriceGhs}
                            onChange={(e) => updateLine(item.id, { unitPriceGhs: e.target.value })}
                          />
                        </div>
                        <div className="space-y-1 sm:col-span-2">
                          <Label className="text-xs">Notes (optional, e.g. substitute brand)</Label>
                          <Input value={line.notes} onChange={(e) => updateLine(item.id, { notes: e.target.value })} />
                        </div>
                      </div>
                    )}

                    {!canEditQuote && line.include && (
                      <div className="mt-2 text-sm text-muted-foreground">
                        {products.find((p) => p.id === line.productId)?.name ?? "Product"} at {formatGHS(Number(line.unitPriceGhs) || 0)} each
                      </div>
                    )}
                  </div>
                );
              })}
            </div>

            {canEditQuote && (
              <div className="mt-4 space-y-3">
                <div className="space-y-1.5">
                  <Label htmlFor="delivery-notes">Delivery notes (optional)</Label>
                  <Textarea
                    id="delivery-notes"
                    value={deliveryNotes}
                    onChange={(e) => setDeliveryNotes(e.target.value)}
                    rows={2}
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="valid-until">Quote valid until (optional)</Label>
                  <Input id="valid-until" type="date" value={validUntil} onChange={(e) => setValidUntil(e.target.value)} />
                </div>
                {error && (
                  <p role="alert" className="text-sm text-destructive">
                    {error}
                  </p>
                )}
                <div className="flex flex-wrap gap-2">
                  <Button type="button" disabled={busy} onClick={() => void submitQuote()}>
                    {myQuote && myQuote.status !== "withdrawn" ? "Update quote" : "Submit quote"}
                  </Button>
                  {myQuote && myQuote.status === "submitted" && (
                    <Button type="button" variant="outline" disabled={busy} onClick={() => void withdraw()}>
                      Withdraw quote
                    </Button>
                  )}
                </div>
              </div>
            )}

            {myQuote?.valid_until && (
              <p className="mt-3 text-xs text-muted-foreground">
                Valid until {formatReportDateTime(myQuote.valid_until)}
              </p>
            )}
          </>
        )}
      </SheetContent>
    </Sheet>
  );
}
