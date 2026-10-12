import { describe, expect, it } from "vitest";
import { buildBusinessDocumentPdf } from "./business-document-pdf";
import { orderDocumentModel } from "./order-document-model";
import type { PrintableOrder } from "@/components/order-print";
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";

const order: PrintableOrder = {
  order_number: "RECORDED-001",
  created_at: "2026-10-12",
  total_ghs: 12.5,
  status: "delivered",
  payment_status: "unpaid",
  payment_method: "cod",
  wholesaler: { name: "Historical supplier", branding: {} },
  pharmacy: { name: "Recorded buyer" },
  order_items: [
    {
      product_name: "Recorded medicine",
      quantity: 1,
      unit_price_ghs: 12.5,
      catalog_details: "CURRENT AND INCORRECT",
      product: { form: "CURRENT FORM" },
    },
  ],
};

describe("commercial document integrity", () => {
  it("preserves identifiers, parties and recorded descriptions without live catalogue substitutions", () => {
    const model = orderDocumentModel(order, "invoice");
    expect(model.reference).toBe(order.order_number);
    expect(model.issuer?.name).toBe("Historical supplier");
    expect(model.recipient?.name).toBe("Recorded buyer");
    expect(JSON.stringify(model)).not.toContain("CURRENT");
    expect(model.metadata.find(([key]) => key === "Payment terms")?.[1]).toContain(
      "payment pending",
    );
    expect(model.summary?.some(([key]) => key.includes("paid"))).toBe(false);
  });
  it("uses supplied quantities and explicit allocated payment amounts", () => {
    const model = orderDocumentModel(
      {
        ...order,
        effective_total_ghs: 25,
        amount_paid_ghs: 10,
        balance_due_ghs: 15,
        order_items: [
          { product_name: "Recorded", quantity: 5, supplied_quantity: 2, unit_price_ghs: 12.5 },
        ],
      },
      "invoice",
    );
    expect(model.rows[0].slice(1)).toEqual(["2", "12.50", "25.00"]);
    expect(model.summary).toContainEqual(["Amount paid (GHS)", "10.00"]);
    expect(model.summary).toContainEqual(["Balance due (GHS)", "15.00"]);
  });
  it("does not expose prices on delivery notes", () => {
    const model = orderDocumentModel(order, "delivery");
    expect(model.summary).toEqual([]);
    expect(JSON.stringify(model)).not.toContain("12.50");
  });
});

describe("actual vector A4 PDF output", () => {
  for (const count of [1, 5, 20, 50, 100])
    it(`retains every one of ${count} lines on A4 pages`, async () => {
      const model = orderDocumentModel(
        {
          ...order,
          total_ghs: count * 12.5,
          order_items: Array.from({ length: count }, (_, i) => ({
            product_name: `PRODUCT-${String(i).padStart(3, "0")} Long recorded pharmaceutical name`,
            strength: "300 mg",
            form: "Tablet",
            quantity: 1,
            unit_price_ghs: 12.5,
          })),
        },
        "invoice",
      );
      const pdf = buildBusinessDocumentPdf(model);
      if (process.env.DOCUMENT_QA_OUTPUT) {
        const { mkdirSync, writeFileSync } = await import("node:fs");
        mkdirSync("tmp/pdfs", { recursive: true });
        writeFileSync(`tmp/pdfs/invoice-${count}.pdf`, new Uint8Array(pdf.output("arraybuffer")));
      }
      const task = getDocument({
        data: new Uint8Array(pdf.output("arraybuffer")),
        useSystemFonts: true,
      });
      const parsed = await task.promise;
      let text = "";
      for (let page = 1; page <= parsed.numPages; page++) {
        const p = await parsed.getPage(page);
        expect(p.view[2]).toBeCloseTo(595.28, 1);
        expect(p.view[3]).toBeCloseTo(841.89, 1);
        const content = await p.getTextContent();
        const strings = content.items
          .filter((item) => "str" in item)
          .map((item) => (item as { str: string }).str);
        text += strings.join(" ");
        expect(strings.join(" ")).toContain(`Page ${page} of ${parsed.numPages}`);
      }
      for (let i = 0; i < count; i++)
        expect(text.match(new RegExp(`PRODUCT-${String(i).padStart(3, "0")}`, "g"))).toHaveLength(
          1,
        );
      expect(text).toContain((count * 12.5).toLocaleString("en-GH", { minimumFractionDigits: 2 }));
      await task.destroy();
    });
});

it("preserves all fields across wide, multi-section report pages", async () => {
  const columns = Array.from({ length: 14 }, (_, i) => `Column ${i}`);
  const pdf = buildBusinessDocumentPdf({
    title: "Report",
    reference: "",
    issuer: { name: "Business" },
    metadata: [],
    columns,
    rows: [columns.map((_, i) => `VALUE-${i}-END`)],
    sections: [
      { title: "Second section", columns: ["Name", "Amount"], rows: [["FINAL-RECORD", "25.00"]] },
    ],
  });
  if (process.env.DOCUMENT_QA_OUTPUT) {
    const { mkdirSync, writeFileSync } = await import("node:fs");
    mkdirSync("tmp/pdfs", {recursive:true});
    writeFileSync("tmp/pdfs/report-wide.pdf", new Uint8Array(pdf.output("arraybuffer")));
  }
  const task = getDocument({
    data: new Uint8Array(pdf.output("arraybuffer")),
    useSystemFonts: true,
  });
  const doc = await task.promise;
  let text = "";
  for (let i = 1; i <= doc.numPages; i++) {
    const page = await doc.getPage(i);
    text += (await page.getTextContent()).items.map((x) => ("str" in x ? x.str : "")).join(" ");
  }
  for (let i = 0; i < 14; i++) expect(text).toContain(`VALUE-${i}-END`);
  expect(text).toContain("FINAL-RECORD");
  expect(doc.numPages).toBeGreaterThan(2);
  await task.destroy();
});
