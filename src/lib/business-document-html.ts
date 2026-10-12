import type { BusinessDocumentModel } from "./business-document-model";
import { resolveDocumentBranding } from "./document-branding";

const escape = (value: unknown) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!,
  );
/** Server/email counterpart to CommercialDocument. All values are escaped, never executable markup. */
export function businessDocumentHtml(model: BusinessDocumentModel, logoUrl?: string) {
  const identity = resolveDocumentBranding(model.issuer);
  const logo =
    logoUrl && /^https:\/\//i.test(logoUrl)
      ? `<img alt="" src="${escape(logoUrl)}" style="max-width:140px;max-height:70px;object-fit:contain">`
      : "";
  const table = (columns: string[], rows: string[][]) =>
    `<table style="width:100%;border-collapse:collapse;font-size:14px"><thead><tr>${columns.map((column) => `<th style="padding:10px 8px;text-align:left;border-bottom:2px solid #526565;background:#eef3f3">${escape(column)}</th>`).join("")}</tr></thead><tbody>${rows.map((row) => `<tr>${row.map((cell, index) => `<td style="padding:10px 8px;border-bottom:1px solid #dde4e4;vertical-align:top;white-space:pre-line;overflow-wrap:anywhere;${model.numericColumns?.includes(index) ? "text-align:right;" : ""}">${escape(cell)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
  return `<!doctype html><html><head><meta charset="utf-8"><title>${escape(model.title)} ${escape(model.reference)}</title><style>@page{size:A4 portrait;margin:12mm} @media print{body{margin:0!important;padding:0!important}.document{max-width:none!important;padding:0!important}thead{display:table-header-group}tr,.summary{break-inside:avoid}.no-print{display:none!important}}</style></head><body style="margin:0;padding:24px;font:14px/1.5 Arial,sans-serif;color:#202828;background:white"><article class="document" style="max-width:720px;margin:auto">
  <table style="width:100%;border-bottom:2px solid ${identity.accentColor};padding-bottom:16px"><tr><td style="vertical-align:top">${logo}<h1 style="font-size:24px;margin:4px 0">${escape(identity.name)}</h1>${identity.contactLines.map((line) => `<div>${escape(line)}</div>`).join("")}</td><td style="text-align:right;vertical-align:top"><h2 style="font-size:22px;margin:4px 0">${escape(model.title)}</h2><strong>${escape(model.reference)}</strong></td></tr></table>
  ${model.recipient ? `<p><strong>${escape(model.recipient.label)}</strong><br>${[model.recipient.name, ...(model.recipient.lines ?? [])].map(escape).join("<br>")}</p>` : ""}
  ${model.metadata
    .filter(([, v]) => v)
    .map(([k, v]) => `<p style="margin:4px 0"><strong>${escape(k)}:</strong> ${escape(v)}</p>`)
    .join("")}
  <div style="margin-top:20px">${table(model.columns, model.rows)}</div>
  ${(model.sections ?? []).map((section) => `<h2>${escape(section.title)}</h2>${table(section.columns, section.rows)}`).join("")}
  <div class="summary" style="margin:20px 0 20px auto;max-width:340px">${(model.summary ?? []).map(([k, v]) => `<p style="display:flex;justify-content:space-between;gap:24px"><span>${escape(k)}</span><strong>${escape(v)}</strong></p>`).join("")}</div>
  ${(model.notes ?? []).map((note) => `<p>${escape(note)}</p>`).join("")}
  ${identity.footer_note ? `<footer style="border-top:1px solid #ccd4d4;padding-top:12px">${escape(identity.footer_note)}</footer>` : ""}
  </article></body></html>`;
}
