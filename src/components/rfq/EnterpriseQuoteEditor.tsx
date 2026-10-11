import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  rfqCall,
  rfqDb,
  type EnterpriseRfq,
  type QuoteVersion,
  type Requirement,
} from "@/lib/enterprise-rfq";
import { toIlikeTerm } from "@/lib/rfq";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
type DraftLine = {
  rfqItemId: string;
  productId: string;
  quantity: string;
  unitPriceGhs: string;
  discountPercent: string;
  alternative: boolean;
  conversion: string;
  expiryDate: string;
  batchNumber: string;
  expectedAvailableOn: string;
  coldChainSupported: boolean;
  specialHandling: string;
  notes: string;
};
type Terms = {
  validUntil: string;
  deliveryCharge: string;
  leadTimeDays: string;
  paymentTerms: string;
  deliveryNotes: string;
  reason: string;
  orderDiscountPercent: string;
};
function ProductSelect({
  businessId,
  value,
  onChange,
}: {
  businessId: string;
  value: string;
  onChange: (id: string) => void;
}) {
  const [query, setQuery] = useState("");
  const search = useDebouncedValue(query, 250);
  const [rows, setRows] = useState<{ id: string; name: string; stock: number }[]>([]);
  const [error, setError] = useState("");
  useEffect(() => {
    let active = true;
    void rfqDb
      .from("products")
      .select("id,name,stock")
      .eq("wholesaler_id", businessId)
      .eq("active", true)
      .ilike("name", `%${toIlikeTerm(search)}%`)
      .order("name")
      .limit(25)
      .then(({ data, error }: { data: typeof rows; error: { message: string } | null }) => {
        if (active) {
          setRows(data ?? []);
          setError(error?.message ?? "");
        }
      });
    return () => {
      active = false;
    };
  }, [businessId, search]);
  return (
    <div>
      <Input
        aria-label="Search your catalogue"
        placeholder="Search your catalogue"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      <select
        aria-label="Offered product"
        className="w-full rounded border p-2"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        <option value="">Choose your product</option>
        {value && !rows.some((p) => p.id === value) && (
          <option value={value}>Selected product {value}</option>
        )}
        {rows.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name} — {p.stock} available
          </option>
        ))}
      </select>
      {error && <p role="alert">{error}</p>}
    </div>
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
  const [lines, setLines] = useState<DraftLine[]>(() =>
    items.map((i) => {
      const old = current?.snapshot.items.find((l) => l.rfq_item_id === i.id);
      return {
        rfqItemId: i.id,
        productId: old?.product_id ?? "",
        quantity: String(old?.quantity ?? i.quantity),
        unitPriceGhs: String(old?.unit_price_ghs ?? ""),
        discountPercent: String(old?.discount_percent ?? 0),
        alternative: old?.alternative ?? false,
        conversion: String(old?.requested_units_per_offered_unit ?? 1),
        expiryDate: old?.expiry_date ?? "",
        batchNumber: old?.batch_number ?? "",
        expectedAvailableOn: old?.expected_available_on ?? "",
        coldChainSupported: old?.cold_chain_supported ?? false,
        specialHandling: old?.special_handling ?? "",
        notes: old?.notes ?? "",
      };
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
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [page, setPage] = useState(0);
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
            setTerms(data.payload);
            setLines(
              items.map(
                (i) =>
                  data.payload.items.find((l) => l.rfqItemId === i.id) ?? {
                    rfqItemId: i.id,
                    productId: "",
                    quantity: String(i.quantity),
                    unitPriceGhs: "",
                    discountPercent: "0",
                    alternative: false,
                    conversion: "1",
                    expiryDate: "",
                    batchNumber: "",
                    expectedAvailableOn: "",
                    coldChainSupported: false,
                    specialHandling: "",
                    notes: "",
                  },
              ),
            );
          }
        },
      );
    return () => {
      active = false;
    };
  }, [rfq.id, businessId, items]);
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
          items: lines.filter((l) => l.productId),
        },
        p_submit: submit,
        p_version: current?.version ?? 0,
        p_request_id: crypto.randomUUID(),
      });
      onSaved();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="space-y-3 rounded border p-4">
      <h3 className="font-semibold">{current ? "Revise quotation" : "Prepare quotation"}</h3>
      <p className="text-sm">
        Leave products unselected for lines you cannot supply. Drafts remain private to your
        supplier workspace. Submitted versions are preserved.
      </p>
      <fieldset disabled={busy} className="space-y-3">
        {lines.slice(page * 15, page * 15 + 15).map((line, offset) => {
          const idx = page * 15 + offset;
          const item = items.find((i) => i.id === line.rfqItemId)!;
          const patch = (p: Partial<DraftLine>) =>
            setLines((ls) => ls.map((l, i) => (i === idx ? { ...l, ...p } : l)));
          return (
            <div key={line.rfqItemId} className="space-y-2 rounded border p-3">
              <h4 className="font-medium">
                {item.product_name}: {item.quantity} {item.unit}
              </h4>
              <p className="text-xs">
                {Object.entries(item.specification)
                  .filter(([, v]) => v)
                  .map(([k, v]) => `${k}: ${v}`)
                  .join(" · ")}{" "}
                · Minimum shelf life {item.minimum_shelf_life_days} days ·{" "}
                {item.partial_allowed ? "Partial supply allowed" : "Full quantity required"}
                {item.cold_chain_required ? " · Cold chain required" : ""}
                {item.special_handling ? ` · Handling: ${item.special_handling}` : ""}
              </p>
              <ProductSelect
                businessId={businessId}
                value={line.productId}
                onChange={(productId) => patch({ productId })}
              />
              {line.productId && (
                <>
                  <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                    <label>
                      Offered units
                      <Input
                        type="number"
                        min="1"
                        value={line.quantity}
                        onChange={(e) => patch({ quantity: e.target.value })}
                      />
                    </label>
                    <label>
                      Unit price (GHS)
                      <Input
                        type="number"
                        step="0.01"
                        min="0.01"
                        value={line.unitPriceGhs}
                        onChange={(e) => patch({ unitPriceGhs: e.target.value })}
                      />
                    </label>
                    <label>
                      Discount %
                      <Input
                        type="number"
                        step="0.01"
                        min="0"
                        max="99.99"
                        value={line.discountPercent}
                        onChange={(e) => patch({ discountPercent: e.target.value })}
                      />
                    </label>
                    <label>
                      Expiry date
                      <Input
                        type="date"
                        value={line.expiryDate}
                        onChange={(e) => patch({ expiryDate: e.target.value })}
                      />
                    </label>
                  </div>
                  <label className="flex gap-2">
                    <input
                      type="checkbox"
                      disabled={!item.alternatives_allowed}
                      checked={line.alternative}
                      onChange={(e) => patch({ alternative: e.target.checked })}
                    />
                    Explicit alternative proposal (requires buyer acceptance)
                  </label>
                  {line.alternative && (
                    <label className="block">
                      Requested units supplied by one offered unit
                      <Input
                        type="number"
                        min="0.001"
                        step="0.001"
                        value={line.conversion}
                        onChange={(e) => patch({ conversion: e.target.value })}
                      />
                      <span className="text-xs">
                        No therapeutic equivalence is inferred. Describe strength, form and pack
                        differences.
                      </span>
                    </label>
                  )}
                  <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                    <label>
                      Batch / lot number
                      <Input
                        value={line.batchNumber}
                        onChange={(e) => patch({ batchNumber: e.target.value })}
                      />
                    </label>
                    <label>
                      Expected available on
                      <Input
                        type="date"
                        value={line.expectedAvailableOn}
                        onChange={(e) => patch({ expectedAvailableOn: e.target.value })}
                      />
                    </label>
                    <label className="flex items-center gap-2">
                      <input
                        type="checkbox"
                        checked={line.coldChainSupported}
                        onChange={(e) => patch({ coldChainSupported: e.target.checked })}
                      />
                      Cold chain confirmed
                    </label>
                  </div>
                  <label className="block">
                    Special handling offered
                    <Input
                      value={line.specialHandling}
                      onChange={(e) => patch({ specialHandling: e.target.value })}
                    />
                  </label>
                  <p className="text-xs text-muted-foreground">
                    Catalogue stock shown above is a snapshot at quote submission, not a reservation
                    or guarantee. Product authorization or regulator registration is not
                    independently verified by this RFQ.
                  </p>
                  <Input
                    aria-label="Supplier line notes"
                    placeholder="Availability, batch or special handling notes"
                    value={line.notes}
                    onChange={(e) => patch({ notes: e.target.value })}
                  />
                </>
              )}
            </div>
          );
        })}
        <div className="flex gap-2">
          <Button variant="outline" disabled={!page} onClick={() => setPage((p) => p - 1)}>
            Previous lines
          </Button>
          <Button
            variant="outline"
            disabled={(page + 1) * 15 >= lines.length}
            onClick={() => setPage((p) => p + 1)}
          >
            Next lines
          </Button>
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
          {Object.entries({
            validUntil: "Valid until",
            deliveryCharge: "Delivery fee GHS (zero means free)",
            leadTimeDays: "Delivery lead time in days",
            paymentTerms: "Payment terms",
            deliveryNotes: "Delivery notes",
            reason: "Revision reason",
            orderDiscountPercent: "Additional order discount % (applied per unit)",
          }).map(([key, title]) => (
            <label key={key}>
              {title}
              <Input
                type={
                  key === "validUntil"
                    ? "datetime-local"
                    : ["deliveryCharge", "leadTimeDays", "orderDiscountPercent"].includes(key)
                      ? "number"
                      : "text"
                }
                value={terms[key as keyof Terms]}
                onChange={(e) => setTerms((t) => ({ ...t, [key]: e.target.value }))}
              />
            </label>
          ))}
        </div>
        <p className="text-xs">
          GHS prices include applicable taxes. The server calculates discounted totals; zero
          delivery is preserved when an award becomes an order.
        </p>
      </fieldset>
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
      <div className="flex gap-2">
        <Button disabled={busy} variant="outline" onClick={() => void save(false)}>
          Save private draft
        </Button>
        <Button disabled={busy} onClick={() => void save(true)}>
          Submit immutable quotation
        </Button>
      </div>
    </section>
  );
}
