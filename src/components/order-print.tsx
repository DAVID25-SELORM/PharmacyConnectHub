import { useState } from "react";
import { Printer } from "lucide-react";
import { Button } from "@/components/ui/button";
import { formatGHS } from "@/lib/format";
import {
  canPrintInvoice,
  documentTotals,
  lineAmount,
  lineDiscount,
  partyLines,
  paymentTermsLine,
  type PartyDetails,
} from "@/lib/order-documents";
import { purchaseCategoryLabel, type PurchaseCategory } from "@/lib/purchase-category";
import { formatReportDate } from "@/lib/reports";

export type OrderPrintMode = "pharmacy" | "pick-pack" | "delivery" | "invoice";

export type PrintableOrder = {
  order_number: string;
  created_at: string;
  total_ghs: number;
  subtotal_ghs?: number | null;
  discount_amount_ghs?: number | null;
  delivery_fee_ghs?: number | null;
  status: string;
  payment_status: string;
  payment_method?: string;
  settlement_method?: string | null;
  is_credit_order?: boolean | null;
  credit_due_date?: string | null;
  credit_terms_days?: number | null;
  paystack_reference?: string | null;
  purchase_category?: PurchaseCategory | null;
  procurement_reference?: string | null;
  pharmacy?: PartyDetails | null;
  wholesaler?: PartyDetails | null;
  order_items: Array<{
    product_name: string;
    quantity: number;
    unit_price_ghs?: number;
    base_unit_price_ghs?: number | null;
    strength?: string | null;
    form?: string | null;
    pack_size?: string | null;
    sku?: string | null;
    location?: string | null;
    batch_number?: string | null;
    expiry_date?: string | null;
    purchase_category?: PurchaseCategory | null;
    product?: {
      form?: string | null;
      pack_size?: string | null;
      warehouse?: string | null;
      zone?: string | null;
      rack?: string | null;
      shelf?: string | null;
      bin?: string | null;
    } | null;
  }>;
};

const modeLabels: Record<OrderPrintMode, string> = {
  pharmacy: "Pharmacy Order Copy",
  "pick-pack": "Pick & Pack Sheet",
  delivery: "Delivery Note",
  invoice: "Invoice",
};

export function OrderPrintActions({
  order,
  wholesaler = false,
}: {
  order: PrintableOrder;
  wholesaler?: boolean;
}) {
  const [mode, setMode] = useState<OrderPrintMode | null>(null);
  const print = (next: OrderPrintMode) => {
    setMode(next);
    window.setTimeout(() => {
      const previousTitle = document.title;
      document.title = "Drugxone";
      window.print();
      window.setTimeout(() => {
        document.title = previousTitle;
      }, 0);
    }, 0);
  };
  return (
    <div className="mt-4">
      <div className="flex flex-wrap justify-end gap-2 print:hidden">
        <Button type="button" variant="outline" size="sm" onClick={() => print("pharmacy")}>
          <Printer className="mr-2 h-4 w-4" /> Pharmacy Order Copy
        </Button>
        {canPrintInvoice(order) && (
          <Button type="button" variant="outline" size="sm" onClick={() => print("invoice")}>
            <Printer className="mr-2 h-4 w-4" /> {wholesaler ? "Invoice" : "Invoice copy"}
          </Button>
        )}
        {wholesaler && (
          <>
            <Button type="button" variant="outline" size="sm" onClick={() => print("pick-pack")}>
              Pick &amp; Pack Sheet
            </Button>
            <Button type="button" variant="outline" size="sm" onClick={() => print("delivery")}>
              Delivery Note
            </Button>
          </>
        )}
      </div>
      {mode && <PrintableOrderDocument order={order} mode={mode} />}
    </div>
  );
}

function PartyBlock({ title, party }: { title: string; party: PartyDetails | null | undefined }) {
  return (
    <div>
      <div className="text-xs font-semibold uppercase tracking-wider">{title}</div>
      <div className="font-bold">{party?.name ?? "—"}</div>
      {partyLines(party).map((line) => (
        <div key={line} className="text-xs">
          {line}
        </div>
      ))}
    </div>
  );
}

export function PrintableOrderDocument({
  order,
  mode,
}: {
  order: PrintableOrder;
  mode: OrderPrintMode;
}) {
  const operational = mode === "pick-pack" || mode === "delivery";
  const priced = mode === "pharmacy" || mode === "invoice";
  const items = mode === "pick-pack" ? sortPrintableItems(order.order_items) : order.order_items;
  const showLineCategory = priced && order.purchase_category === "mixed";
  const totals = documentTotals(order);
  const terms = paymentTermsLine(order, formatReportDate);
  return (
    <article className="print-document hidden print:block">
      <header className="mb-6 border-b-2 border-black pb-3">
        <h1 className="text-2xl font-bold">Drugxone</h1>
        <h2 className="mt-2 text-xl font-bold uppercase">{modeLabels[mode]}</h2>
        {mode === "invoice" ? (
          <>
            <div className="mt-3 grid grid-cols-2 gap-4 text-sm">
              <PartyBlock title="From (supplier)" party={order.wholesaler} />
              <PartyBlock title="Bill to" party={order.pharmacy} />
            </div>
            <div className="mt-3 grid grid-cols-2 gap-1 text-sm">
              <span>
                Invoice no.: <b>{order.order_number}</b>
              </span>
              <span>
                Invoice date: <b>{formatReportDate(order.created_at)}</b>
              </span>
              <span>
                Payment terms: <b>{terms}</b>
              </span>
              {order.credit_due_date && (
                <span>
                  Due date: <b>{formatReportDate(order.credit_due_date)}</b>
                </span>
              )}
              {order.procurement_reference && (
                <span>
                  Procurement ref: <b>{order.procurement_reference}</b>
                </span>
              )}
              {order.purchase_category && (
                <span>
                  Purchase category: <b>{purchaseCategoryLabel(order.purchase_category)}</b>
                </span>
              )}
            </div>
          </>
        ) : (
          <div className="mt-2 grid grid-cols-2 gap-1 text-sm">
            <span>
              Order: <b>{order.order_number}</b>
            </span>
            <span>
              Date: <b>{new Date(order.created_at).toLocaleString()}</b>
            </span>
            <span>
              Pharmacy: <b>{order.pharmacy?.name ?? "—"}</b>
            </span>
            <span>
              Wholesaler: <b>{order.wholesaler?.name ?? "—"}</b>
            </span>
            {order.procurement_reference && (
              <span>
                Procurement ref: <b>{order.procurement_reference}</b>
              </span>
            )}
            {mode === "pharmacy" && order.purchase_category && (
              <span>
                Purchase Category: <b>{purchaseCategoryLabel(order.purchase_category)}</b>
              </span>
            )}
            {mode === "pharmacy" && (
              <span className="col-span-2">
                Payment terms: <b>{terms}</b>
              </span>
            )}
            {mode === "pick-pack" && (
              <>
                <span>Picker: __________________</span>
                <span>Packer/Checker: __________________</span>
              </>
            )}
          </div>
        )}
      </header>
      <table className="w-full border-collapse text-sm">
        <thead className="[&]:table-header-group">
          <tr className="border-b-2 border-black text-left">
            {mode === "pick-pack" && <th className="p-2">[ ]</th>}
            {mode === "pick-pack" && <th className="p-2">Location</th>}
            <th className="p-2">Product</th>
            <th className="p-2">Details</th>
            <th className="p-2">{mode === "invoice" ? "Qty" : "Ordered"}</th>
            {priced && (
              <>
                <th className="p-2">Unit</th>
                <th className="p-2">{mode === "invoice" ? "Amount" : "Total"}</th>
                {showLineCategory && <th className="p-2">Category</th>}
              </>
            )}
            {mode === "pick-pack" && <th className="p-2">Picked</th>}
            {mode === "delivery" && (
              <>
                <th className="p-2">Dispatched</th>
                <th className="p-2">Batch</th>
                <th className="p-2">Expiry</th>
              </>
            )}
          </tr>
        </thead>
        <tbody>
          {items.map((item, index) => {
            const discount = lineDiscount(item);
            return (
              <tr key={`${item.product_name}-${index}`} className="border-b border-gray-400">
                {mode === "pick-pack" && <td className="p-3 text-lg">[ ]</td>}
                {mode === "pick-pack" && (
                  <td className="p-3 font-medium">{locationFor(item) || "UNASSIGNED"}</td>
                )}
                <td className="p-3 font-semibold">
                  {item.product_name}
                  {item.sku && <div className="text-xs">SKU: {item.sku}</div>}
                </td>
                <td className="p-3">
                  {[
                    item.strength,
                    item.form ?? item.product?.form,
                    item.pack_size ?? item.product?.pack_size,
                  ]
                    .filter(Boolean)
                    .join(" / ") || "—"}
                </td>
                <td className="p-3 text-lg font-bold">{item.quantity}</td>
                {priced && (
                  <>
                    <td className="p-3">
                      {formatGHS(item.unit_price_ghs ?? 0)}
                      {mode === "invoice" && discount && (
                        <div className="text-xs">
                          List {formatGHS(discount.listPrice)}, less {formatGHS(discount.saving)}
                        </div>
                      )}
                    </td>
                    <td className="p-3">{formatGHS(lineAmount(item))}</td>
                    {showLineCategory && (
                      <td className="p-3">{purchaseCategoryLabel(item.purchase_category)}</td>
                    )}
                  </>
                )}
                {mode === "pick-pack" && <td className="p-3">________</td>}
                {mode === "delivery" && (
                  <>
                    <td className="p-3">________</td>
                    <td className="p-3">________</td>
                    <td className="p-3">________</td>
                  </>
                )}
              </tr>
            );
          })}
        </tbody>
      </table>
      {priced && (
        <div className="mt-6 ml-auto w-72 space-y-1 text-right text-sm">
          {totals.subtotal !== null && <div>Subtotal: {formatGHS(totals.subtotal)}</div>}
          {totals.subtotal !== null && <div>Discounts: {formatGHS(totals.discount)}</div>}
          {totals.delivery !== null && <div>Delivery fee: {formatGHS(totals.delivery)}</div>}
          <div className="border-t border-black pt-2 text-lg font-bold">
            {mode === "invoice" ? "Invoice total" : "Grand total"}: {formatGHS(totals.total)}
          </div>
          {mode === "pharmacy" && <div>Payment: {order.payment_status}</div>}
          {order.paystack_reference && <div>Reference: {order.paystack_reference}</div>}
        </div>
      )}
      {mode === "invoice" && (
        <p className="mt-6 text-xs">
          Amounts are in Ghana cedis (GHS). Prices are those charged on the order, after any
          discounts.
        </p>
      )}
      {operational && (
        <div className="mt-8 grid grid-cols-2 gap-6 text-sm">
          <div>
            Picked by: __________________
            <br />
            Date: __________ Time: __________
          </div>
          <div>
            Checked/Packed by: __________________
            <br />
            Date: __________ Time: __________
          </div>
          <div>
            Received by: __________________
            <br />
            Signature: __________________
          </div>
          <div>Notes / shortages: __________________</div>
        </div>
      )}
      {mode === "pharmacy" && (
        <div className="mt-10 grid grid-cols-3 gap-4 text-sm">
          Receiving name: __________________
          <br />
          Signature: __________________
          <br />
          Date: __________
        </div>
      )}
      <footer className="mt-8 break-inside-avoid border-t border-black pt-2 text-center text-xs">
        Developed by Daventra Technologies
      </footer>
    </article>
  );
}

export function locationFor(item: PrintableOrder["order_items"][number]) {
  if (item.location) return item.location;
  const p = item.product;
  return p ? [p.warehouse, p.zone, p.rack, p.shelf, p.bin].filter(Boolean).join("-") : "";
}

export function sortPrintableItems<T extends PrintableOrder["order_items"][number]>(items: T[]) {
  return [...items].sort((a, b) => {
    const left = locationFor(a);
    const right = locationFor(b);
    return (left ? 0 : 1) - (right ? 0 : 1) || left.localeCompare(right);
  });
}
