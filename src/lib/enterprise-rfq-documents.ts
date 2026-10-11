import {
  rfqCall,
  type EnterpriseRfq,
  type Requirement,
  type QuoteVersion,
  type AwardGroup,
  type Allocation,
} from "./enterprise-rfq";
type Document = {
  rfq: EnterpriseRfq;
  pharmacy: string;
  supplier: string | null;
  items: Requirement[];
  version: QuoteVersion | null;
  award: AwardGroup | null;
  allocations: Allocation[] | null;
};
/** Re-fetch authorized server data at export time; never export editable form totals. */
export async function exportRfqDocument(
  id: string,
  format: "pdf" | "xlsx",
  versionId?: string,
  groupId?: string,
) {
  const data = await rfqCall<Document>("rfq_document", {
    p_rfq_id: id,
    p_version_id: versionId ?? null,
    p_group_id: groupId ?? null,
  });
  const title = data.award ? "Award" : data.version ? "Quotation" : "Request for quotation";
  const columns = data.award
    ? ["Medicine", "Offered quantity", "Unit price GHS"]
    : data.version
      ? ["Medicine", "Offered quantity", "Final unit price GHS", "Expiry", "Alternative"]
      : ["Medicine", "Requested quantity", "Unit", "Specification", "Minimum shelf life days"];
  const rows: (string | number)[][] = data.award
    ? (data.allocations ?? []).map((a) => [
        data.items.find((i) => i.id === a.rfq_item_id)?.product_name ?? "Medicine",
        a.quantity,
        a.unit_price_ghs,
      ])
    : data.version
      ? data.version.snapshot.items.map((l) => [
          String(l.offered_specification.name ?? ""),
          l.quantity,
          l.final_unit_price_ghs,
          l.expiry_date,
          l.alternative ? "Explicit alternative" : "Requested identity",
        ])
      : data.items.map((i) => [
          i.product_name,
          i.quantity,
          i.unit,
          Object.entries(i.specification)
            .filter(([, v]) => v)
            .map(([k, v]) => `${k}: ${v}`)
            .join("; "),
          i.minimum_shelf_life_days,
        ]);
  const metadata = [
    ["Document", title],
    ["Reference", data.rfq.reference],
    ["Pharmacy", data.pharmacy],
    ["Supplier", data.supplier ?? "Invited suppliers"],
    ["Deadline", data.rfq.response_deadline ?? ""],
    ["Delivery", data.rfq.delivery_location ?? "Pharmacy address"],
    ["Expected delivery", data.rfq.expected_delivery_date ?? ""],
    ["Instructions", data.rfq.delivery_instructions ?? ""],
    ["Payment preference", data.rfq.payment_preference],
  ];
  if (data.version)
    metadata.push(
      ["Quote revision", String(data.version.version)],
      ["Goods GHS", String(data.version.snapshot.quote.total_ghs)],
      ["Delivery GHS", String(data.version.snapshot.quote.delivery_charge_ghs)],
      ["Valid until", data.version.snapshot.quote.valid_until ?? ""],
      ["Payment terms", data.version.snapshot.quote.payment_terms ?? ""],
      ["Tax treatment", data.version.snapshot.taxTreatment],
    );
  if (data.award)
    metadata.push(
      ["Award status", data.award.status],
      ["Goods GHS", String(data.award.goods_ghs)],
      ["Delivery GHS", String(data.award.delivery_ghs)],
      ["Settlement", data.award.settlement_method],
      ["Order", data.award.order_id ?? "Awaiting supplier confirmation"],
    );
  const filename = `${data.rfq.reference}-${title.replaceAll(" ", "-")}`;
  if (format === "xlsx") {
    const xlsx = await import("xlsx");
    const book = xlsx.utils.book_new();
    xlsx.utils.book_append_sheet(
      book,
      xlsx.utils.aoa_to_sheet([...metadata, [], columns, ...rows]),
      "RFQ",
    );
    xlsx.writeFile(book, `${filename}.xlsx`);
    return;
  }
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([
    import("jspdf"),
    import("jspdf-autotable"),
  ]);
  const pdf = new jsPDF();
  pdf.setFontSize(18);
  pdf.text(`DrugXOne | ${title}`, 14, 18);
  autoTable(pdf, { startY: 25, body: metadata, theme: "plain", styles: { fontSize: 9 } });
  const end = (pdf as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
  autoTable(pdf, {
    startY: end + 6,
    head: [columns],
    body: rows,
    styles: { fontSize: 8 },
    headStyles: { fillColor: [0, 119, 128] },
  });
  pdf.save(`${filename}.pdf`);
}
