import { jsPDF } from "jspdf";
import autoTable from "jspdf-autotable";
import { describeBilledOrder } from "./billing";
import {
  INVOICE_STATUS_LABELS,
  PAYMENT_METHOD_LABELS,
  type InvoiceDetail,
} from "./billing-invoices";

const money = (n: number, currency = "GHS") =>
  `${currency === "GHS" ? "GHS" : currency} ${n.toLocaleString("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

const day = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "short",
        year: "numeric",
        timeZone: "UTC",
      })
    : "";

/** The invoice and statement for one billing period, from the saved invoice only (what was issued, never a recalculation). */
export function buildBillingInvoicePdf(inv: InvoiceDetail): jsPDF {
  const pdf = new jsPDF();
  const end = () => (pdf as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
  const table = {
    margin: { top: 15, bottom: 20 },
    styles: { fontSize: 9, overflow: "linebreak" as const },
  };
  const issuer = inv.issuer ?? {};
  const customer = inv.customer ?? {};

  autoTable(pdf, {
    ...table,
    startY: 14,
    theme: "plain",
    body: [
      [
        {
          content: issuer.name ?? "DrugXOne",
          styles: { fontSize: 16, fontStyle: "bold" as const },
        },
        "",
      ],
      ...[issuer.address, issuer.email, issuer.phone, issuer.website]
        .filter((x): x is string => Boolean(x))
        .map((x) => [x, ""]),
    ],
  });
  autoTable(pdf, {
    ...table,
    startY: end() + 4,
    theme: "plain",
    body: [
      [{ content: "INVOICE", styles: { fontSize: 14, fontStyle: "bold" as const } }, ""],
      ["Invoice number", inv.invoice_number],
      [
        "Billing period",
        inv.summary?.period_label ?? `${day(inv.period_start)} – ${day(inv.period_end)}`,
      ],
      ["Issued", day(inv.issued_at)],
      ["Due", day(inv.due_at)],
      ["Status", INVOICE_STATUS_LABELS[inv.status]],
    ],
  });
  autoTable(pdf, {
    ...table,
    startY: end() + 4,
    theme: "plain",
    body: [
      [{ content: "Billed to", styles: { fontStyle: "bold" as const } }, ""],
      [customer.name ?? inv.business_name, ""],
      ...[
        [customer.address, customer.city, customer.region].filter(Boolean).join(", ") || null,
        customer.phone,
        customer.email,
      ]
        .filter((x): x is string => Boolean(x))
        .map((x) => [x, ""]),
    ],
  });

  autoTable(pdf, {
    ...table,
    startY: end() + 5,
    head: [["Description", "Amount"]],
    body: [
      ...inv.lines.map((l) => [l.description, money(l.amount, inv.currency)]),
      [
        { content: "Total", styles: { fontStyle: "bold" as const } },
        { content: money(inv.total_amount, inv.currency), styles: { fontStyle: "bold" as const } },
      ],
      ["Paid", money(inv.amount_paid, inv.currency)],
      [
        { content: "Balance to pay", styles: { fontStyle: "bold" as const } },
        {
          content: money(inv.outstanding_amount, inv.currency),
          styles: { fontStyle: "bold" as const },
        },
      ],
    ],
    columnStyles: { 1: { halign: "right" as const } },
  });

  if (inv.payments.length > 0) {
    autoTable(pdf, {
      ...table,
      startY: end() + 5,
      head: [["Payments", "Method", "Reference", "Amount"]],
      body: inv.payments.map((p) => [
        day(p.received_at) + (p.kind === "reversal" ? " (reversal)" : ""),
        PAYMENT_METHOD_LABELS[p.method] ?? p.method,
        p.reference ?? "",
        (p.kind === "reversal" ? "-" : "") + money(p.amount, inv.currency),
      ]),
      columnStyles: { 3: { halign: "right" as const } },
    });
  }

  if (inv.orders.length > 0) {
    autoTable(pdf, {
      ...table,
      startY: end() + 5,
      head: [["Orders billed", "How it was billed", "Eligible sales", "Charged"]],
      body: inv.orders.map((o) => [
        o.order_number,
        describeBilledOrder(o, (n) => money(n, inv.currency)),
        money(o.billable_gmv, inv.currency),
        money(o.charged_amount, inv.currency),
      ]),
      columnStyles: { 2: { halign: "right" as const }, 3: { halign: "right" as const } },
    });
  }

  if (issuer.payment_instructions || issuer.tax_note) {
    autoTable(pdf, {
      ...table,
      startY: end() + 5,
      theme: "plain",
      body: [
        ...(issuer.payment_instructions
          ? [
              [{ content: "How to pay", styles: { fontStyle: "bold" as const } }],
              [issuer.payment_instructions],
            ]
          : []),
        ...(issuer.tax_note ? [[issuer.tax_note]] : []),
      ],
    });
  }
  return pdf;
}

export function invoiceFileName(inv: Pick<InvoiceDetail, "invoice_number">): string {
  return `${inv.invoice_number}.pdf`;
}
