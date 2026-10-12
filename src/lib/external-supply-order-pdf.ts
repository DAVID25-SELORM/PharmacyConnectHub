import { buildBusinessDocumentPdf } from "./business-document-pdf";
import { documentMoney, type BusinessDocumentModel } from "./business-document-model";
import type { SupplyOrder } from "./external-supply-orders";

export function supplyOrderDocumentModel(order: SupplyOrder): BusinessDocumentModel {
  if (!order.issuer || !order.issued_at)
    throw new Error("Issue the saved document before downloading it.");
  const request = order.kind === "request";
  return {
    title: request ? "Request for quotation" : "Purchase order",
    reference: order.reference,
    issuer: order.issuer,
    recipient: {
      label: "Supplier",
      name: order.data.supplier,
      lines: [order.data.supplier_contact].filter((v): v is string => Boolean(v)),
    },
    metadata: [
      ["Issued", order.issued_at.slice(0, 10)],
      ["Required by", order.data.required_date || "To be agreed"],
      ["Deliver to", order.data.delivery_address || "To be agreed"],
      ...(order.status === "cancelled"
        ? [["Status", "CANCELLED - Do not fulfil"] as [string, string]]
        : []),
    ],
    columns: [
      "Description",
      "Quantity / unit",
      request ? "Target (GHS)" : "Unit price (GHS)",
      "Amount (GHS)",
    ],
    numericColumns: [1, 2, 3],
    rows: order.data.lines.map((line) => [
      [line.name, line.specification].filter(Boolean).join("\n"),
      `${line.quantity} ${line.unit || "packs"}`,
      line.unit_price === null ? "Quote requested" : documentMoney(line.unit_price),
      line.unit_price === null
        ? "-"
        : documentMoney((Math.round(line.unit_price * 100) * line.quantity) / 100),
    ]),
    summary: [
      [
        "Goods total (GHS)",
        order.data.lines.some((line) => line.unit_price === null)
          ? "Awaiting quotation"
          : documentMoney(
              order.data.lines.reduce(
                (sum, line) => sum + Math.round((line.unit_price ?? 0) * 100) * line.quantity,
                0,
              ) / 100,
            ),
      ],
    ],
    notes: [
      request
        ? "Request for availability and quotation. This is not a purchase commitment."
        : "Payment and receipt are recorded separately. Additional charges require agreement.",
      ...(order.data.notes ? [order.data.notes] : []),
    ],
  };
}
/** Saved issued snapshot only; rendering does not issue, share or receive goods. */
export function buildSupplyOrderPdf(order: SupplyOrder, logo?: string) {
  return buildBusinessDocumentPdf(supplyOrderDocumentModel(order), logo);
}
