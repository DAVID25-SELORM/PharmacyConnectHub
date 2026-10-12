import { jsPDF } from "jspdf";
import autoTable from "jspdf-autotable";
import { resolveDocumentBranding } from "./document-branding";
import type { BusinessDocumentModel } from "./business-document-model";

/** Vector text, explicit physical paper size, shared margins and pagination. */
export function buildBusinessDocumentPdf(model: BusinessDocumentModel, logo?: string) {
  const pdf = new jsPDF({ orientation: "portrait", unit: "mm", format: "a4" });
  pdf.setProperties({
    title: `${model.title} - ${model.reference}`,
    author: model.issuer?.name ?? "",
  });
  const identity = resolveDocumentBranding(model.issuer);
  const margin = { top: 16, right: 12, bottom: 20, left: 12 };
  const end = () => (pdf as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
  let logoBottom = 12;
  if (logo) {
    const image = pdf.getImageProperties(logo);
    const scale = Math.min(36 / image.width, 20 / image.height);
    pdf.addImage(logo, "PNG", 12, 12, image.width * scale, image.height * scale);
    logoBottom = 12 + image.height * scale + 3;
  }
  autoTable(pdf, {
    startY: logoBottom,
    margin,
    theme: "plain",
    styles: { fontSize: 10, cellPadding: 1.5, overflow: "linebreak", textColor: 30 },
    columnStyles: { 0: { cellWidth: 116 }, 1: { halign: "right" } },
    body: [
      [
        { content: identity.name, styles: { fontSize: 18, fontStyle: "bold" } },
        { content: model.title.toUpperCase(), styles: { fontSize: 16, fontStyle: "bold" } },
      ],
      [
        [
          identity.display_name !== identity.name ? identity.display_name : "",
          ...identity.contactLines,
        ]
          .filter(Boolean)
          .join("\n"),
        model.reference,
      ],
    ],
  });
  autoTable(pdf, {
    startY: end() + 5,
    margin,
    theme: "plain",
    styles: { fontSize: 10, cellPadding: 1.5 },
    body: [
      ...(model.recipient
        ? [
            [
              model.recipient.label,
              [model.recipient.name, ...(model.recipient.lines ?? [])].join("\n"),
            ],
          ]
        : []),
      ...model.metadata.filter(([, value]) => value),
    ],
    columnStyles: { 0: { cellWidth: 42, fontStyle: "bold" } },
  });
  const numeric = Object.fromEntries(
    (model.numericColumns ?? []).map((index) => [
      index,
      { halign: "right" as const, cellWidth: 26 },
    ]),
  );
  autoTable(pdf, {
    startY: end() + 6,
    margin,
    head: [model.columns],
    body: model.rows,
    theme: "striped",
    showHead: "everyPage",
    rowPageBreak: "avoid",
    styles: { fontSize: 10, cellPadding: 2.5, overflow: "linebreak", textColor: 25 },
    headStyles: { fillColor: identity.accentColor, textColor: 255 },
    columnStyles: numeric,
    alternateRowStyles: { fillColor: [247, 249, 249] },
  });
  if (model.summary?.length)
    autoTable(pdf, {
      startY: end() + 5,
      margin: { ...margin, left: 100 },
      theme: "plain",
      pageBreak: "avoid",
      styles: { fontSize: 11, cellPadding: 2 },
      columnStyles: { 1: { halign: "right", fontStyle: "bold" } },
      body: model.summary,
    });
  const notes = [...(model.notes ?? []), identity.footer_note].filter((v): v is string =>
    Boolean(v),
  );
  if (notes.length)
    autoTable(pdf, {
      startY: end() + 6,
      margin,
      theme: "plain",
      styles: { fontSize: 9, cellPadding: 2 },
      body: notes.map((note) => [note]),
    });
  const pages = pdf.getNumberOfPages();
  for (let page = 1; page <= pages; page++) {
    pdf.setPage(page);
    pdf.setDrawColor(190);
    pdf.line(12, 282, 198, 282);
    pdf.setFontSize(8);
    pdf.setTextColor(80);
    pdf.text(`${model.title} | Page ${page} of ${pages}`, 198, 288, { align: "right" });
  }
  return pdf;
}

/** Only an issuer's authorized/snapshotted logo URL is passed here. */
export async function loadDocumentLogo(url?: string | null): Promise<string | undefined> {
  if (!url) return undefined;
  const response = await fetch(url);
  if (!response.ok) throw new Error("The document logo could not be loaded. Please retry.");
  const bitmap = await createImageBitmap(await response.blob());
  const canvas = document.createElement("canvas");
  const scale = Math.min(1, 1200 / Math.max(bitmap.width, bitmap.height));
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  return canvas.toDataURL("image/png");
}
