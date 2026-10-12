import { jsPDF } from "jspdf";
import autoTable from "jspdf-autotable";
import { resolveDocumentBranding } from "./document-branding";
import type { SupplyOrder } from "./external-supply-orders";

/** Render the saved, issued document, never the unsaved editor state. */
export function buildSupplyOrderPdf(order: SupplyOrder, logo?: string) {
  if (!order.issuer || !order.issued_at)
    throw new Error("Issue the saved document before downloading it.");
  const identity = resolveDocumentBranding(order.issuer);
  const pdf = new jsPDF();
  if (logo) pdf.addImage(logo, "PNG", 14, 10, 40, 20);
  const end = () => (pdf as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
  const table = {
    margin: { top: 15, bottom: 22 },
    styles: { fontSize: 9, overflow: "linebreak" as const },
  };
  autoTable(pdf, {
    ...table,
    startY: logo ? 34 : 14,
    theme: "plain",
    body: [
      [identity.name],
      [
        order.kind === "request"
          ? "External purchase request / request for quotation"
          : "External purchase order",
      ],
    ],
  });
  autoTable(pdf, {
    ...table,
    startY: end() + 3,
    theme: "plain",
    body: [
      ["Reference", order.reference],
      ["Issued", order.issued_at.slice(0, 10)],
      ...identity.contactLines.map((x) => ["Issuer contact", x]),
      ...(identity.display_name ? [["Trading name", identity.display_name]] : []),
      ["Supplier", order.data.supplier],
      ["Supplier contact", order.data.supplier_contact || "Not provided"],
      ["Required by", order.data.required_date || "To be agreed"],
      ["Deliver to", order.data.delivery_address || "To be agreed"],
      ["Instructions", order.data.notes || "None"],
      [
        "Document purpose",
        order.kind === "request"
          ? "Request for availability and quotation. This is not a purchase commitment."
          : "Purchase order. Payment and receipt are recorded separately. Prices are in GHS; additional charges require agreement.",
      ],
      ...(order.status === "cancelled" ? [["CANCELLED", "Do not fulfil this document."]] : []),
    ],
  });
  autoTable(pdf, {
    ...table,
    startY: end() + 5,
    head: [["Medicine / pack", "Specification", "Quantity / unit", order.kind === "request" ? "Target GHS" : "Unit GHS", "Line GHS"]],
    body: order.data.lines.map((l) => [
      l.name,
      l.specification,
      `${l.quantity} ${l.unit || "packs"}`,
      l.unit_price === null ? "Quote requested" : l.unit_price.toFixed(2),
      l.unit_price === null ? "-" : (Math.round(l.unit_price * 100) * l.quantity / 100).toFixed(2),
    ]),
    headStyles: { fillColor: [15, 118, 110] },
  });
  autoTable(pdf, {
    ...table,
    startY: end() + 4,
    theme: "plain",
    body: [
      [
        "Goods total GHS",
        order.data.lines.some((l) => l.unit_price === null)
          ? "Awaiting quotation"
          : (
              order.data.lines.reduce(
                (n, l) => n + Math.round((l.unit_price ?? 0) * 100) * l.quantity,
                0,
              ) / 100
            ).toFixed(2),
      ],
      [
        "Sharing",
        "Prepared for manual sharing. Download does not send this document or confirm supplier acceptance.",
      ],
      ...(identity.footer_note ? [["Issuer note", identity.footer_note]] : []),
    ],
  });
  const pages = pdf.getNumberOfPages();
  for (let p = 1; p <= pages; p++) {
    pdf.setPage(p);
    pdf.setFontSize(8);
    pdf.text(`${order.reference} | ${p} / ${pages} | Prepared via Drugxone`, 14, 288);
  }
  return pdf;
}
