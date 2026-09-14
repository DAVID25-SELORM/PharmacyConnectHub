import { z } from "zod";
import { PLATFORM } from "./platform";

const money = z.string().regex(/^-?\d+(\.\d{1,2})?$/);
const party = z.object({
  name: z.string(),
  phone: z.string().nullable(),
  email: z.string().nullable(),
  address: z.string().nullable(),
  city: z.string().nullable(),
  region: z.string().nullable(),
  location_description: z.string().nullable(),
});
export const printableOrderSchema = z.object({
  order_number: z.string(),
  created_at: z.string().datetime({ offset: true }),
  status: z.enum(["pending", "accepted", "packed", "dispatched", "delivered", "cancelled"]),
  payment_status: z.enum(["unpaid", "paid", "refunded", "failed"]),
  payment_method: z.enum(["cod", "paystack"]),
  total_ghs: money,
  notes: z.string().nullable(),
  buyer: party,
  seller: party,
  items: z.array(
    z.object({
      product_name: z.string(),
      brand: z.string().nullish(),
      generic_name: z.string().nullish(),
      strength: z.string().nullish(),
      dosage_form: z.string().nullish(),
      pack_size: z.string().nullish(),
      quantity: z.number().int().positive(),
      unit_price_ghs: money,
      line_subtotal_ghs: money,
    }),
  ),
});
export type PrintableOrder = z.infer<typeof printableOrderSchema>;

function escape(value: string) {
  return value.replace(
    /[&<>"']/g,
    (character) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]!,
  );
}
export function printMoney(value: string) {
  // Format PostgreSQL decimal text without binary floating point or precision loss.
  const [whole, fraction = ""] = value.split(".");
  return `GH₵ ${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${fraction.padEnd(2, "0")}`;
}
const textLine = (label: string, value: string | null) =>
  value?.trim() ? `<div><span class="label">${label}</span> ${escape(value)}</div>` : "";
function renderProductDetails(item: PrintableOrder["items"][number]) {
  const fields = [
    ["Brand", item.brand],
    ["Generic", item.generic_name],
    ["Strength", item.strength],
    ["Form", item.dosage_form],
    ["Pack", item.pack_size],
  ];
  return fields
    .filter(([, value]) => value?.trim())
    .map(
      ([label, value]) =>
        `<div class="muted" style="font-size:8pt">${label}: ${escape(value!)}</div>`,
    )
    .join("");
}
function renderParty(label: string, value: PrintableOrder["buyer"]) {
  return `<section class="party"><h2>${label}</h2><strong>${escape(value.name)}</strong>
    ${textLine("Phone:", value.phone)}${textLine("Email:", value.email)}
    ${textLine("Business address:", [value.address, value.city, value.region].filter(Boolean).join(", "))}
  </section>`;
}

export function renderOrderPrint(order: PrintableOrder): string {
  const when = new Intl.DateTimeFormat("en-GH", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Africa/Accra",
  }).format(new Date(order.created_at));
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
    <meta name="referrer" content="no-referrer" />
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'" />
    <title>${escape(PLATFORM.name)} — Order ${escape(order.order_number)}</title>
    <style>
      @page { size:A4; margin:15mm 12mm; }
      * { box-sizing:border-box; }
      body { margin:0; background:white; color:#182b35; font:10pt/1.45 Arial,sans-serif; }
      main { max-width:186mm; margin:0 auto; padding:8mm 4mm; }
      header { display:flex; justify-content:space-between; gap:10mm; border-bottom:2px solid #0f766e; padding-bottom:5mm; }
      .brand { font-size:23pt; font-weight:700; color:#0f766e; letter-spacing:-.8px; }
      h1 { margin:0; font-size:18pt; letter-spacing:2px; } h2 { font-size:10pt; text-transform:uppercase; letter-spacing:1px; margin:0 0 2mm; color:#0f766e; }
      .reference { text-align:right; } .label,.muted { color:#52616b; } .label { font-weight:400; }
      .parties { display:grid; grid-template-columns:1fr 1fr; gap:8mm; margin:6mm 0; }
      .party { border-left:2px solid #d8e7e4; padding-left:3mm; } .party strong { display:block; margin-bottom:2mm; }
      .party,.notes,.summary,footer,header { break-inside:avoid; }
      div,p,td,strong { overflow-wrap:anywhere; } p { margin:2mm 0; }
      table { width:100%; border-collapse:collapse; table-layout:fixed; }
      thead { display:table-header-group; } tr { break-inside:avoid; page-break-inside:avoid; }
      th { color:#29483f; background:#eef6f4; font-size:9pt; text-align:left; }
      th,td { padding:3mm 2mm; border-bottom:1px solid #d9e2e8; vertical-align:top; }
      .quantity { width:12%; text-align:right; } .money { width:22%; text-align:right; font-variant-numeric:tabular-nums; }
      .summary { display:flex; justify-content:flex-end; gap:8mm; padding:5mm 0; font-size:13pt; font-weight:700; }
      .notes { border-top:1px solid #d9e2e8; padding-top:4mm; margin-top:3mm; } .pre { white-space:pre-wrap; }
      footer { margin-top:8mm; padding-top:4mm; border-top:1px solid #d9e2e8; font-size:8pt; color:#52616b; }
      @media print { main { max-width:none; padding:0; } body { print-color-adjust:exact; -webkit-print-color-adjust:exact; } }
    </style></head><body><main>
    <header><div><div class="brand">${PLATFORM.name}</div><div>Powered by ${PLATFORM.company}</div></div>
      <div class="reference"><h1>ORDER</h1><strong>${escape(order.order_number)}</strong><div>${escape(when)} GMT</div></div></header>
    <p style="margin-top:4mm"><span class="label">Order status:</span> ${escape(order.status)} &nbsp; · &nbsp;
      <span class="label">Payment:</span> ${escape(order.payment_status)} (${order.payment_method === "cod" ? "Cash on delivery" : "Paystack"})</p>
    <div class="parties">${renderParty("Buyer · Pharmacy", order.buyer)}${renderParty("Seller · Wholesaler", order.seller)}</div>
    <table><thead><tr><th>Product</th><th class="quantity">Qty</th><th class="money">Unit price</th><th class="money">Line subtotal</th></tr></thead><tbody>
      ${order.items.map((item) => `<tr><td>${escape(item.product_name)}${renderProductDetails(item)}</td><td class="quantity">${item.quantity}</td><td class="money">${printMoney(item.unit_price_ghs)}</td><td class="money">${printMoney(item.line_subtotal_ghs)}</td></tr>`).join("")}
    </tbody></table><div class="summary"><span>Order total</span><span>${printMoney(order.total_ghs)}</span></div>
    ${order.notes?.trim() ? `<section class="notes"><h2>Order notes / fulfilment instructions</h2><p class="pre">${escape(order.notes)}</p></section>` : ""}
    ${order.buyer.location_description?.trim() ? `<section class="notes"><h2>Buyer location reference</h2><p>${escape(order.buyer.location_description)}</p></section>` : ""}
    <footer><p>Order record for picking, packing and internal records. This document is not a tax invoice or proof of payment.</p>
      <p>Prices and product names are recorded at order creation. Business contact details reflect the current business record; confirm delivery or pickup arrangements with the parties.</p>
      <p><strong>Platform support · ${PLATFORM.name}</strong><br />${PLATFORM.company} · ${PLATFORM.contactPerson}<br />${PLATFORM.email} · ${PLATFORM.phone}</p></footer>
    </main></body></html>`;
}
