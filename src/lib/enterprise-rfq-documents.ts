import {
  rfqCall,
  type EnterpriseRfq,
  type Requirement,
  type QuoteVersion,
  type AwardGroup,
  type Allocation,
} from "./enterprise-rfq";
import { resolveDocumentBranding, type DocumentBusiness } from "./document-branding";
import { supabase } from "@/integrations/supabase/client";
type Document = {
  historical?: boolean;
  issuer?: DocumentBusiness & { branding?: DocumentBusiness["branding"] & { logo_path?: string | null } };
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
  const identity = resolveDocumentBranding(data.issuer ?? { name: data.version && !data.award ? data.supplier ?? "Supplier" : data.pharmacy });
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
    ...(!data.historical ? [["Branding history", "Original branding was not recorded; current identity is shown."]] : []),
    ["Issued by", identity.name],
    ...identity.contactLines.map(line => ["Contact", line]),
    ...(identity.display_name ? [["Trading name", identity.display_name]] : []),
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
  if (identity.payment_instructions) metadata.push(["Payment instructions", identity.payment_instructions]);
  if (identity.signatory_name) metadata.push(["Authorized signatory", [identity.signatory_name, identity.signatory_title].filter(Boolean).join(" — ")]);
  if (identity.footer_note) metadata.push(["Issuer note", identity.footer_note]);
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
  let logo: string | null = null;
  const path = data.issuer?.branding?.logo_path;
  if (path) {
    const url = supabase.storage.from("business-document-logos").getPublicUrl(path).data.publicUrl;
    const response = await fetch(url);
    if (!response.ok) throw new Error("Logo could not be loaded. Retry the export.");
    const bitmap = await createImageBitmap(await response.blob());
    const canvas = document.createElement("canvas");
    canvas.width = 160; canvas.height = 80;
    const scale = Math.min(160 / bitmap.width, 80 / bitmap.height);
    canvas.getContext("2d")!.drawImage(bitmap, 0, 0, bitmap.width * scale, bitmap.height * scale);
    bitmap.close();
    logo = canvas.toDataURL("image/png");
  }
  if (logo) pdf.addImage(logo, "PNG", 14, 10, 40, 20);
  autoTable(pdf, { startY: logo ? 34 : 14, body: [[identity.name], [title]], theme: "plain", styles: { fontSize: 16 } });
  const headerEnd = (pdf as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
  autoTable(pdf, { startY: headerEnd + 4, body: metadata, theme: "plain", styles: { fontSize: 9 } });
  const end = (pdf as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
  autoTable(pdf, {
    startY: end + 6,
    head: [columns],
    body: rows,
    styles: { fontSize: 8 },
    margin: { bottom: 20 },
    headStyles: { fillColor: identity.accentColor },
  });
  const pages = pdf.getNumberOfPages();
  for (let page = 1; page <= pages; page++) {
    pdf.setPage(page);
    pdf.setFontSize(8);
    pdf.text(`Generated through DrugXOne | ${page} / ${pages}`, 14, 290);
  }
  pdf.save(`${filename}.pdf`);
}
