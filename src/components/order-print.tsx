import { useState } from "react";
import { Printer } from "lucide-react";
import { Button } from "@/components/ui/button";
import { formatGHS } from "@/lib/format";

export type OrderPrintMode = "pharmacy" | "pick-pack" | "delivery";

export type PrintableOrder = {
  order_number: string;
  created_at: string;
  total_ghs: number;
  subtotal_ghs?: number | null;
  discount_amount_ghs?: number | null;
  status: string;
  payment_status: string;
  payment_method?: string;
  paystack_reference?: string | null;
  pharmacy?: { name: string; address?: string | null; city?: string | null } | null;
  wholesaler?: { name: string; address?: string | null; city?: string | null } | null;
  order_items: Array<{
    product_name: string;
    quantity: number;
    unit_price_ghs?: number;
    strength?: string | null;
    form?: string | null;
    pack_size?: string | null;
    sku?: string | null;
    location?: string | null;
    batch_number?: string | null;
    expiry_date?: string | null;
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
    window.setTimeout(() => window.print(), 0);
  };
  return (
    <div className="mt-4">
      <div className="flex flex-wrap justify-end gap-2 print:hidden">
        <Button type="button" variant="outline" size="sm" onClick={() => print("pharmacy")}>
          <Printer className="mr-2 h-4 w-4" /> Pharmacy Order Copy
        </Button>
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

export function PrintableOrderDocument({ order, mode }: { order: PrintableOrder; mode: OrderPrintMode }) {
  const operational = mode !== "pharmacy";
  const items = mode === "pick-pack" ? sortPrintableItems(order.order_items) : order.order_items;
  return (
    <article className="print-document hidden print:block">
      <header className="mb-6 border-b-2 border-black pb-3">
        <h1 className="text-2xl font-bold">Drugxone</h1>
        <p className="text-xs">Developed by Daventra Technologies</p>
        <h2 className="mt-2 text-xl font-bold uppercase">{modeLabels[mode]}</h2>
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
          {mode === "pick-pack" && (
            <>
              <span>Picker: __________________</span>
              <span>Packer/Checker: __________________</span>
            </>
          )}
        </div>
      </header>
      <table className="w-full border-collapse text-sm">
        <thead className="[&]:table-header-group">
          <tr className="border-b-2 border-black text-left">
            {mode === "pick-pack" && <th className="p-2">[ ]</th>}
            {mode === "pick-pack" && <th className="p-2">Location</th>}
            <th className="p-2">Product</th>
            <th className="p-2">Details</th>
            <th className="p-2">Ordered</th>
            {mode === "pharmacy" && (
              <>
                <th className="p-2">Unit</th>
                <th className="p-2">Total</th>
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
          {items.map((item, index) => (
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
              {mode === "pharmacy" && (
                <>
                  <td className="p-3">{formatGHS(item.unit_price_ghs ?? 0)}</td>
                  <td className="p-3">{formatGHS((item.unit_price_ghs ?? 0) * item.quantity)}</td>
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
          ))}
        </tbody>
      </table>
      {mode === "pharmacy" && (
        <div className="mt-6 ml-auto w-64 space-y-1 text-right text-sm">
          <div>Subtotal: {formatGHS(order.subtotal_ghs ?? order.total_ghs)}</div>
          <div>Discounts: {formatGHS(order.discount_amount_ghs ?? 0)}</div>
          <div>Delivery fee: __________</div>
          <div className="border-t border-black pt-2 text-lg font-bold">
            Grand total: {formatGHS(order.total_ghs)}
          </div>
          <div>Payment: {order.payment_status}</div>
          {order.paystack_reference && <div>Reference: {order.paystack_reference}</div>}
        </div>
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
