import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PLATFORM } from "./platform";
import {
  printableOrderSchema,
  printMoney,
  renderOrderPrint,
  type PrintableOrder,
} from "./order-print";

const party = (name: string) => ({
  name,
  phone: null,
  email: null,
  address: null,
  city: null,
  region: null,
  location_description: null,
});
const order: PrintableOrder = {
  order_number: "ORD-100001",
  created_at: "2026-09-14T09:30:00Z",
  status: "accepted",
  payment_status: "unpaid",
  payment_method: "cod",
  buyer: { ...party("Buyer Pharmacy"), phone: "0241112222", email: "buyer@registered.test" },
  seller: { ...party("Seller Wholesale"), phone: "0243334444", email: "seller@registered.test" },
  total_ghs: "14.50",
  notes: "Please call before delivery.",
  items: [
    {
      product_name: "Recorded medicine name",
      quantity: 2,
      unit_price_ghs: "7.25",
      line_subtotal_ghs: "14.50",
    },
  ],
};

describe("private order print document", () => {
  it("renders optional historical product details only when recorded", () => {
    const html = renderOrderPrint({
      ...order,
      items: [
        {
          ...order.items[0],
          brand: "Recorded Brand",
          generic_name: "Recorded Generic",
          strength: "5 mg",
          dosage_form: "Tablet",
          pack_size: "20 tablets",
        },
      ],
    });
    for (const detail of ["Recorded Brand", "Recorded Generic", "5 mg", "Tablet", "20 tablets"])
      expect(html).toContain(detail);
  });
  it("renders actual buyer and seller independently of platform support", () => {
    const html = renderOrderPrint(order);
    for (const value of [
      order.buyer.name,
      order.seller.name,
      order.buyer.email!,
      order.seller.email!,
      ...Object.values(PLATFORM).filter((x) => typeof x === "string"),
    ])
      expect(html).toContain(value);
    expect(html).toContain("Buyer · Pharmacy");
    expect(html).toContain("Seller · Wholesaler");
    expect(html).toContain("<h1>ORDER</h1>");
  });
  it("uses stored decimal prices and recorded names without current catalogue data", () => {
    const parsed = printableOrderSchema.parse({
      ...order,
      price_ghs: 999,
      items: [{ ...order.items[0], product: { price_ghs: 999 } }],
    });
    const html = renderOrderPrint(parsed);
    expect(html).toContain("GH₵ 7.25");
    expect(html).toContain("GH₵ 14.50");
    expect(html).not.toContain("999");
  });
  it("formats currency without floating-point precision loss", () => {
    expect(printMoney("9007199254740993.01")).toBe("GH₵ 9,007,199,254,740,993.01");
    expect(printMoney("0")).toBe("GH₵ 0.00");
  });
  it("does not invent addresses, discounts, delivery charges or missing product attributes", () => {
    const html = renderOrderPrint(order);
    expect(html).not.toContain("Business address:");
    expect(html).not.toContain("Accra, Ghana");
    expect(html).not.toContain("Discount:");
    expect(html).not.toContain("Delivery charge:");
    expect(html).not.toContain("Generic name:");
    expect(PLATFORM).not.toHaveProperty("address");
    expect(PLATFORM).not.toHaveProperty("website");
    expect(PLATFORM.socialLinks).toEqual({});
  });
  it("escapes user-controlled markup and has no external resources or scripts", () => {
    const html = renderOrderPrint({
      ...order,
      notes: '<script>alert(1)</script><img src="https://attacker.test">',
      buyer: party('<iframe src="evil">'),
    });
    expect(html).not.toContain("<script>");
    expect(html).not.toContain("<img");
    expect(html).not.toContain("<iframe");
    expect(html).toContain("&lt;script&gt;");
    expect(html).toContain("default-src 'none'");
  });
  it("does not mutate its input or expose internal fields", () => {
    const input = {
      ...order,
      id: "INTERNAL-ID",
      access_token: "SECRET-TOKEN",
      payment_confirmed_by: "ACTOR-ID",
    };
    const before = JSON.stringify(input);
    const html = renderOrderPrint(printableOrderSchema.parse(input));
    expect(JSON.stringify(input)).toBe(before);
    for (const secret of ["INTERNAL-ID", "SECRET-TOKEN", "ACTOR-ID"])
      expect(html).not.toContain(secret);
  });
  it("has A4 pagination rules and no dashboard controls", () => {
    const html = renderOrderPrint(order);
    expect(html).toContain("size:A4");
    expect(html).toContain("display:table-header-group");
    expect(html).toContain("break-inside:avoid");
    expect(html).not.toContain("<button");
    expect(html).not.toContain("<nav");
    mkdirSync(".tmp/print-qa", { recursive: true });
    writeFileSync(".tmp/print-qa/order.html", html);
    writeFileSync(
      ".tmp/print-qa/multipage.html",
      renderOrderPrint({
        ...order,
        items: Array.from({ length: 65 }, (_, i) => ({
          ...order.items[0],
          product_name: `${i + 1}. Recorded medicine with a longer name for picking and packing`,
        })),
      }),
    );
  });
});

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory()
      ? sourceFiles(join(dir, entry.name))
      : /\.(tsx?|html)$/.test(entry.name)
        ? [join(dir, entry.name)]
        : [],
  );
}
it("has no visible legacy platform branding or fake contact placeholders in runtime source", () => {
  const files = [...sourceFiles("src"), ...sourceFiles("api"), "index.html"].filter(
    (p) => !p.includes(".test.") && !p.endsWith("mock-data.ts"),
  );
  for (const file of files) {
    const source = readFileSync(file, "utf8")
      .replace(/pharmahub\.active_business_id/g, "technical-storage-key")
      .replace(/\/\^pharma\\s\?hub\(\?: gh\)\?\$\/i/g, "legacy-normalizer");
    expect(source, file).not.toMatch(
      /PharmaHub|Pharma Hub|gabiondavidselorm@gmail\.com|hello@pharmahub|\+233 20 000 0000|placeholder="[^"\n]*@(?:example\.com|business\.(?:gh|com)|pharmacy\.gh)"/i,
    );
  }
});
