import { useEffect, useMemo, useState, type ReactNode } from "react";
import { AlertTriangle, CheckCircle2, Wand2 } from "lucide-react";
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
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import {
  rfqCall,
  rfqDb,
  type EnterpriseRfq,
  type QuoteVersion,
  type Requirement,
} from "@/lib/enterprise-rfq";
import { formatGHS } from "@/lib/format";
import { rfqDate } from "@/lib/rfq-format";
import {
  blankDraftLine,
  lineIssues,
  matchCatalogue,
  summarizeQuote,
  toPayloadLines,
  type DraftLine,
} from "@/lib/rfq-quote-lines";
import type { OfferedProduct } from "./QuoteProductCombobox";
import { RfqQuoteTable } from "./RfqQuoteTable";

type Terms = {
  validUntil: string;
  deliveryCharge: string;
  leadTimeDays: string;
  paymentTerms: string;
  deliveryNotes: string;
  reason: string;
  orderDiscountPercent: string;
};

const CHUNK = 100;
const chunks = <T,>(all: T[]) =>
  Array.from({ length: Math.ceil(all.length / CHUNK) }, (_, i) =>
    all.slice(i * CHUNK, (i + 1) * CHUNK),
  );

function Field({
  label,
  hint,
  children,
  className,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <label className={`block space-y-1.5 ${className ?? ""}`}>
      <span className="text-sm font-medium">{label}</span>
      {children}
      {hint && <span className="block text-xs text-muted-foreground">{hint}</span>}
    </label>
  );
}

export function EnterpriseQuoteEditor({
  rfq,
  items,
  businessId,
  current,
  onSaved,
}: {
  rfq: EnterpriseRfq;
  items: Requirement[];
  businessId: string;
  current?: QuoteVersion;
  onSaved: () => void;
}) {
  const itemMap = useMemo(() => new Map(items.map((i) => [i.id, i])), [items]);
  const [lines, setLines] = useState<DraftLine[]>(() =>
    items.map((i) => {
      const old = current?.snapshot.items.find((l) => l.rfq_item_id === i.id);
      return old
        ? {
            ...blankDraftLine(i),
            productId: old.product_id ?? "",
            quantity: String(old.quantity),
            unitPriceGhs: String(old.unit_price_ghs ?? ""),
            discountPercent: String(old.discount_percent ?? 0),
            alternative: old.alternative ?? false,
            conversion: String(old.requested_units_per_offered_unit ?? 1),
            expiryDate: old.expiry_date ?? "",
            batchNumber: old.batch_number ?? "",
            expectedAvailableOn: old.expected_available_on ?? "",
            coldChainSupported: old.cold_chain_supported ?? false,
            specialHandling: old.special_handling ?? "",
            notes: old.notes ?? "",
          }
        : blankDraftLine(i);
    }),
  );
  const [terms, setTerms] = useState<Terms>({
    validUntil: current?.snapshot.quote.valid_until?.slice(0, 16) ?? "",
    deliveryCharge: String(current?.snapshot.quote.delivery_charge_ghs ?? 0),
    leadTimeDays: String(current?.snapshot.quote.lead_time_days ?? ""),
    paymentTerms: current?.snapshot.quote.payment_terms ?? "",
    deliveryNotes: current?.snapshot.quote.delivery_notes ?? "",
    reason: "",
    orderDiscountPercent: String(current?.snapshot.orderDiscountPercent ?? 0),
  });
  const [products, setProducts] = useState<Map<string, OfferedProduct>>(new Map());
  const [masters, setMasters] = useState<Map<string, string | null>>(new Map());
  const [busy, setBusy] = useState(false);
  const [matching, setMatching] = useState(false);
  const [error, setError] = useState("");
  const [confirm, setConfirm] = useState(false);

  // A private draft saved earlier takes precedence over the last submitted version.
  useEffect(() => {
    let active = true;
    void rfqDb
      .from("rfq_quote_drafts")
      .select("payload")
      .eq("rfq_id", rfq.id)
      .eq("wholesaler_id", businessId)
      .maybeSingle()
      .then(
        ({
          data,
          error,
        }: {
          data: { payload: Terms & { items: DraftLine[] } } | null;
          error: { message: string } | null;
        }) => {
          if (!active) return;
          if (error) setError(error.message);
          if (data) {
            const { items: saved, ...rest } = data.payload;
            setTerms((t) => ({ ...t, ...rest }));
            setLines(
              items.map((i) => saved.find((l) => l.rfqItemId === i.id) ?? blankDraftLine(i)),
            );
          }
        },
      );
    return () => {
      active = false;
    };
  }, [rfq.id, businessId, items]);

  // Look up the names and catalogue identity of chosen products (the lines only hold their ids).
  const chosen = [...new Set(lines.map((l) => l.productId).filter(Boolean))].sort();
  const chosenKey = chosen.join(",");
  useEffect(() => {
    const missing = chosen.filter((id) => !products.has(id) || !masters.has(id));
    if (!missing.length) return;
    let active = true;
    void (async () => {
      const foundProducts: OfferedProduct[] = [];
      const foundMasters: [string, string | null][] = [];
      for (const part of chunks(missing)) {
        const [p, m] = await Promise.all([
          rfqDb
            .from("products")
            .select("id,name,stock,price_ghs")
            .eq("wholesaler_id", businessId)
            .in("id", part),
          rfqDb
            .from("wholesaler_products")
            .select("id,product_id")
            .eq("wholesaler_id", businessId)
            .in("id", part),
        ]);
        foundProducts.push(...((p.data as OfferedProduct[] | null) ?? []));
        for (const row of (m.data as { id: string; product_id: string | null }[] | null) ?? [])
          foundMasters.push([row.id, row.product_id]);
        // A product with no catalogue link has no identity to compare.
        for (const id of part)
          if (!foundMasters.some(([k]) => k === id)) foundMasters.push([id, null]);
      }
      if (!active) return;
      setProducts((cur) => new Map([...cur, ...foundProducts.map((p) => [p.id, p] as const)]));
      setMasters((cur) => new Map([...cur, ...foundMasters]));
    })();
    return () => {
      active = false;
    };
    // `chosen` is derived from `chosenKey`; products/masters are read to find what is still missing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chosenKey, businessId]);

  const today = new Date().toISOString().slice(0, 10);
  const orderDiscount = Number(terms.orderDiscountPercent || 0);
  const issues = useMemo(
    () =>
      lineIssues(lines, itemMap, (line) => ({
        expectedDelivery: rfq.expected_delivery_date,
        today,
        offeredMaster: masters.has(line.productId) ? masters.get(line.productId) : undefined,
      })),
    [lines, itemMap, masters, rfq.expected_delivery_date, today],
  );
  const summary = summarizeQuote(lines, issues, orderDiscount);

  const submitProblems = [
    summary.quoted === 0 && "Choose your product on at least one line to quote it.",
    summary.withIssues > 0 &&
      `${summary.withIssues} quoted line${summary.withIssues === 1 ? " needs" : "s need"} attention.`,
    (!terms.validUntil || new Date(terms.validUntil).getTime() <= Date.now()) &&
      "Set a quotation validity date in the future.",
    current && !terms.reason.trim() && "Say why you are revising this quotation.",
    !(orderDiscount >= 0 && orderDiscount < 100) &&
      "The additional order discount must be from 0 up to 100.",
  ].filter(Boolean) as string[];

  const registerProducts = (found: OfferedProduct[]) =>
    setProducts((cur) => new Map([...cur, ...found.map((p) => [p.id, p] as const)]));

  const matchFromCatalogue = async () => {
    setMatching(true);
    try {
      const wanted = [
        ...new Set(
          lines
            .filter((l) => !l.productId)
            .map((l) => itemMap.get(l.rfqItemId)?.master_product_id)
            .filter(Boolean) as string[],
        ),
      ];
      if (!wanted.length) {
        toast.info("Nothing to match: every line has a product, or has no catalogue identity.");
        return;
      }
      const links: { id: string; product_id: string }[] = [];
      for (const part of chunks(wanted)) {
        const { data, error } = await rfqDb
          .from("wholesaler_products")
          .select("id,product_id")
          .eq("wholesaler_id", businessId)
          .in("product_id", part);
        if (error) throw new Error(error.message);
        links.push(...(data ?? []));
      }
      const active: OfferedProduct[] = [];
      for (const part of chunks(links.map((l) => l.id))) {
        const { data, error } = await rfqDb
          .from("products")
          .select("id,name,stock,price_ghs")
          .eq("wholesaler_id", businessId)
          .eq("active", true)
          .in("id", part);
        if (error) throw new Error(error.message);
        active.push(...(data ?? []));
      }
      const live = new Set(active.map((p) => p.id));
      const candidates = new Map<string, string[]>();
      for (const link of links)
        if (live.has(link.id))
          candidates.set(link.product_id, [...(candidates.get(link.product_id) ?? []), link.id]);
      const out = matchCatalogue(lines, itemMap, candidates);
      setLines(out.lines);
      registerProducts(active);
      setMasters((cur) => new Map([...cur, ...links.map((l) => [l.id, l.product_id] as const)]));
      toast.success(
        out.matched
          ? `Matched ${out.matched} line${out.matched === 1 ? "" : "s"} to your catalogue.${
              out.ambiguous
                ? ` ${out.ambiguous} have several candidates: choose those yourself.`
                : ""
            }`
          : out.ambiguous
            ? `No automatic match: ${out.ambiguous} line${out.ambiguous === 1 ? " has" : "s have"} several candidates.`
            : "None of the requested medicines match your catalogue exactly.",
      );
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setMatching(false);
    }
  };

  const save = async (submit: boolean) => {
    setBusy(true);
    setError("");
    try {
      await rfqCall("save_enterprise_quote", {
        p_rfq_id: rfq.id,
        p_wholesaler_id: businessId,
        p_payload: {
          ...terms,
          validUntil: terms.validUntil ? new Date(terms.validUntil).toISOString() : null,
          items: toPayloadLines(lines),
        },
        p_submit: submit,
        p_version: current?.version ?? 0,
        p_request_id: crypto.randomUUID(),
      });
      toast.success(submit ? "Quotation submitted." : "Private draft saved.");
      onSaved();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const set = (key: keyof Terms) => (e: { target: { value: string } }) =>
    setTerms((t) => ({ ...t, [key]: e.target.value }));

  return (
    <div className="w-full space-y-6">
      <header className="space-y-2">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="text-2xl font-semibold tracking-tight">
            {current ? "Revise quotation" : "Prepare quotation"}
          </h3>
          <Badge variant="secondary">
            {current ? `Revision of version ${current.version}` : "Private draft"}
          </Badge>
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Choose your product for each line you can supply and leave the rest. Drafts stay private
          to your workspace; a submitted version is preserved and can only be revised, never edited.
        </p>
        <dl className="flex flex-wrap gap-x-8 gap-y-2 rounded-lg border bg-muted/30 px-4 py-3 text-sm">
          {(
            [
              ["Request", `${rfq.reference} · ${rfq.title}`],
              ["Respond by", rfqDate(rfq.response_deadline)],
              ["Delivery needed", rfqDate(rfq.expected_delivery_date)],
              ["Deliver to", rfq.delivery_location || "Not specified"],
              ["Buyer pays by", rfq.payment_preference],
            ] as const
          ).map(([label, value]) => (
            <div key={label}>
              <dt className="text-xs uppercase tracking-wide text-muted-foreground">{label}</dt>
              <dd className="font-medium">{value}</dd>
            </div>
          ))}
        </dl>
      </header>

      <fieldset disabled={busy} className="min-w-0 space-y-6">
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">1. Lines</CardTitle>
            <CardDescription>
              One row per requested medicine. Expiry dates must leave the buyer's minimum shelf life
              at the delivery date. Stock shown is a snapshot, not a reservation, and product
              authorisation is not verified by this RFQ.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <RfqQuoteTable
              businessId={businessId}
              items={items}
              lines={lines}
              onChange={setLines}
              issues={issues}
              products={products}
              onProducts={registerProducts}
              orderDiscountPercent={orderDiscount}
              disabled={busy}
              tools={
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="gap-1.5"
                  disabled={busy || matching}
                  onClick={() => void matchFromCatalogue()}
                >
                  <Wand2 className="h-4 w-4" /> {matching ? "Matching…" : "Match my catalogue"}
                </Button>
              }
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-lg">2. Terms</CardTitle>
            <CardDescription>
              Prices include applicable taxes. The server calculates the discounted totals, and a
              zero delivery fee is kept when an award becomes an order.
            </CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-2">
            <Field label="Valid until" hint="Required to submit. Must be in the future.">
              <Input type="datetime-local" value={terms.validUntil} onChange={set("validUntil")} />
            </Field>
            <Field label="Delivery fee (GHS)" hint="Zero means free delivery.">
              <Input
                type="number"
                min="0"
                step="0.01"
                value={terms.deliveryCharge}
                onChange={set("deliveryCharge")}
              />
            </Field>
            <Field label="Delivery lead time (days)">
              <Input
                type="number"
                min="0"
                value={terms.leadTimeDays}
                onChange={set("leadTimeDays")}
              />
            </Field>
            <Field
              label="Additional order discount (%)"
              hint="Applied per unit, on top of each line's discount."
            >
              <Input
                type="number"
                min="0"
                max="99.99"
                step="0.01"
                value={terms.orderDiscountPercent}
                onChange={set("orderDiscountPercent")}
              />
            </Field>
            <Field label="Payment terms" className="sm:col-span-2">
              <Input value={terms.paymentTerms} onChange={set("paymentTerms")} />
            </Field>
            <Field label="Delivery notes" className="sm:col-span-2">
              <Textarea rows={2} value={terms.deliveryNotes} onChange={set("deliveryNotes")} />
            </Field>
            {current && (
              <Field
                label="Reason for this revision"
                hint="Required to submit a revision. Shown to the buyer in the version history."
                className="sm:col-span-2"
              >
                <Input value={terms.reason} onChange={set("reason")} />
              </Field>
            )}
          </CardContent>
        </Card>
      </fieldset>

      <div className="sticky bottom-0 z-10 -mx-4 border-t bg-background/95 px-4 py-3 backdrop-blur sm:mx-0 sm:rounded-lg sm:border">
        {error && (
          <p
            role="alert"
            className="mb-3 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
          >
            {error}
          </p>
        )}
        <div className="flex flex-wrap items-center gap-3">
          <ul className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <li className="flex items-center gap-1 tabular-nums">
              {summary.quoted ? (
                <CheckCircle2 className="h-3.5 w-3.5 text-success" />
              ) : (
                <AlertTriangle className="h-3.5 w-3.5 text-warning" />
              )}
              {summary.quoted} of {summary.total} lines quoted
            </li>
            {summary.withIssues > 0 && (
              <li className="flex items-center gap-1 text-destructive">
                <AlertTriangle className="h-3.5 w-3.5" /> {summary.withIssues} need attention
              </li>
            )}
            {summary.quoted > 0 && (
              <li
                className="tabular-nums"
                title="An estimate: the server calculates the final total when you submit."
              >
                Estimated total {formatGHS(summary.estimate)}
              </li>
            )}
          </ul>
          <div className="ml-auto flex flex-wrap gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={busy}
              onClick={() => void save(false)}
            >
              Save private draft
            </Button>
            <Button
              type="button"
              disabled={busy}
              onClick={() => {
                if (submitProblems.length) {
                  setError(submitProblems.join(" "));
                  return;
                }
                setError("");
                setConfirm(true);
              }}
            >
              Submit quotation
            </Button>
          </div>
        </div>
      </div>

      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Submit this quotation?</AlertDialogTitle>
            <AlertDialogDescription>
              {summary.quoted} of {summary.total} lines, estimated total{" "}
              {formatGHS(summary.estimate)}. A submitted quotation is preserved exactly as sent. You
              can revise it later, with a reason, but not edit it.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep editing</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                setConfirm(false);
                void save(true);
              }}
            >
              Submit quotation
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
