import type { PrintableOrder, OrderPrintMode } from "@/components/order-print";
import {
  documentTotals,
  lineAmount,
  suppliedQuantity,
  paymentTermsLine,
  partyLines,
} from "./order-documents";
import { documentMoney, type BusinessDocumentModel } from "./business-document-model";
import { formatReportDate } from "./reports";

export function orderDocumentModel(
  order: PrintableOrder,
  mode: OrderPrintMode,
): BusinessDocumentModel {
  const priced = mode === "invoice" || mode === "pharmacy";
  const issuer = mode === "pharmacy" ? order.pharmacy : order.wholesaler;
  const recipient = mode === "pharmacy" ? order.wholesaler : order.pharmacy;
  const totals = documentTotals(order);
  const summary: Array<[string, string]> = [];
  if (priced) {
    if (totals.subtotal !== null)
      summary.push([
        totals.amended ? "Goods as supplied" : "Subtotal",
        documentMoney(totals.subtotal),
      ]);
    if (!totals.amended && totals.discount > 0)
      summary.push(["Discount", `-${documentMoney(totals.discount)}`]);
    if (totals.delivery !== null) summary.push(["Delivery", documentMoney(totals.delivery)]);
    summary.push(["Total (GHS)", documentMoney(totals.total)]);
    // Never infer cash received from COD, paid status or invoice existence.
    if (order.amount_paid_ghs != null)
      summary.push(["Amount paid (GHS)", documentMoney(order.amount_paid_ghs)]);
    if (order.balance_due_ghs != null)
      summary.push(["Balance due (GHS)", documentMoney(order.balance_due_ghs)]);
  }
  return {
    title:
      mode === "invoice"
        ? "Invoice"
        : mode === "pharmacy"
          ? "Pharmacy order copy"
          : "Delivery note",
    reference: order.order_number,
    issuer,
    recipient: {
      label: mode === "invoice" ? "Bill to" : mode === "pharmacy" ? "Supplier" : "Deliver to",
      name: recipient?.name ?? "Not recorded",
      lines: partyLines(recipient),
    },
    metadata: [
      ["Issued", formatReportDate(order.created_at)],
      ...(priced
        ? [["Payment terms", paymentTermsLine(order, formatReportDate)] as [string, string]]
        : []),
      ...(order.credit_due_date && priced
        ? [["Due date", formatReportDate(order.credit_due_date)] as [string, string]]
        : []),
      ...(order.procurement_reference
        ? [["Procurement reference", order.procurement_reference] as [string, string]]
        : []),
    ],
    columns: priced
      ? ["Description", "Quantity", "Unit price (GHS)", "Amount (GHS)"]
      : ["Description", "Quantity supplied", "Batch", "Expiry"],
    numericColumns: priced ? [1, 2, 3] : [1],
    rows: order.order_items.map((item) => {
      // These fields belong to the recorded line. Never substitute live product/catalogue relations.
      const details = [item.strength, item.form, item.pack_size].filter(Boolean).join(" · ");
      const description = [
        item.product_name,
        details,
        item.supplied_quantity != null && item.supplied_quantity !== item.quantity
          ? `Originally ordered: ${item.quantity}`
          : "",
      ]
        .filter(Boolean)
        .join("\n");
      return priced
        ? [
            description,
            String(suppliedQuantity(item)),
            item.unit_price_ghs == null ? "Not recorded" : documentMoney(item.unit_price_ghs),
            item.unit_price_ghs == null ? "Not recorded" : documentMoney(lineAmount(item)),
          ]
        : [
            description,
            String(suppliedQuantity(item)),
            item.batch_number ?? "________",
            item.expiry_date ?? "________",
          ];
    }),
    summary,
    notes: [
      ...(totals.amended && priced
        ? [
            `Supply amended by agreement. Original order total: GHS ${documentMoney(totals.originalTotal)}.`,
          ]
        : []),
      ...(priced && issuer?.branding?.payment_instructions
        ? [`Payment instructions: ${issuer.branding.payment_instructions}`]
        : []),
      ...(mode === "delivery"
        ? ["Received by: __________________    Signature: __________________    Date: __________"]
        : []),
    ],
  };
}
