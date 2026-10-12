import type { OrderReceiptPayload } from "./_order-receipts.js";
import type { BusinessDocumentModel } from "../src/lib/business-document-model";
import { documentMoney } from "../src/lib/business-document-model";

/** Input is supplied only after the existing receipt endpoint validates payment and business access. */
export function receiptDocumentModel(order: OrderReceiptPayload): BusinessDocumentModel {
  const date = (value: string | null) =>
    value
      ? new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeZone: "Africa/Accra" }).format(
          new Date(value),
        )
      : "Not recorded";
  return {
    title: "Payment receipt",
    reference: order.orderNumber,
    issuer: order.issuer ?? order.parties.wholesaler,
    recipient: {
      label: "Received from",
      name: order.parties.pharmacy.name,
      lines: [order.parties.pharmacy.city, order.parties.pharmacy.region].filter((v): v is string =>
        Boolean(v),
      ),
    },
    metadata: [
      ["Payment date", date(order.paidAt)],
      ["Payment method", order.paymentMethod === "cod" ? "Cash on delivery" : "Paystack"],
      ["Delivered", date(order.deliveredAt)],
    ],
    columns: ["Description", "Quantity", "Unit price (GHS)", "Amount (GHS)"],
    numericColumns: [1, 2, 3],
    rows: order.items.map((item) => [
      item.productName,
      String(item.quantity),
      documentMoney(item.unitPriceGhs),
      documentMoney((Math.round(item.unitPriceGhs * 100) * item.quantity) / 100),
    ]),
    summary: [
      ...(order.deliveryFeeGhs
        ? [["Delivery (GHS)", documentMoney(order.deliveryFeeGhs)] as [string, string]]
        : []),
      ["Amount received (GHS)", documentMoney(order.totalGhs)],
    ],
    notes: order.issuer?.legacy_branding
      ? ["Original branding was not recorded; current business identity is displayed."]
      : [],
  };
}
