import { supplyLine, type SupplyLine } from "./external-supply-orders";
export const PROCUREMENT_UNITS = [
  "packs",
  "boxes",
  "bottles",
  "tubes",
  "vials",
  "ampoules",
  "pieces",
] as const;
export type CatalogueData = {
  name: string;
  category: string;
  unit: string;
  strength: string;
  dosage_form: string;
  pack_size: string;
  brand_name: string;
  generic_name: string;
  manufacturer: string;
  product_code: string;
  ingredients: string;
  aliases: string;
  notes: string;
};
export type CatalogueEntry = {
  id: string;
  source: "business" | "master";
  data: CatalogueData;
  version: number;
  archived: boolean;
};
export const emptyMedicine = (): CatalogueData => ({
  name: "",
  category: "medicine",
  unit: "packs",
  strength: "",
  dosage_form: "",
  pack_size: "",
  brand_name: "",
  generic_name: "",
  manufacturer: "",
  product_code: "",
  ingredients: "",
  aliases: "",
  notes: "",
});
export const medicineLabel = (p: Partial<CatalogueData>) =>
  [p.name, p.strength, p.dosage_form, p.pack_size].filter(Boolean).join(" / ");
export function catalogueLine(p: CatalogueEntry): SupplyLine {
  return {
    ...supplyLine(),
    name: medicineLabel(p.data),
    specification: p.data.notes || "",
    unit: p.data.unit || "packs",
    catalogue_id: p.id,
    catalogue_source: p.source,
    product_snapshot: { ...p.data },
  };
}
export const lineMinor = (line: SupplyLine) =>
  Math.round((line.unit_price ?? 0) * 100) * line.quantity;
export function importProcurementRows(matrix: unknown[][]): { line: SupplyLine; issue: string }[] {
  const [header, ...rows] = matrix.filter((row) => row.some((cell) => String(cell ?? "").trim()));
  if (!header) throw new Error("The file is empty.");
  const keys = header.map((x) => String(x).trim().toLowerCase().replaceAll("_", " "));
  const nameIndex = keys.findIndex((x) => ["medicine", "medicine name", "name"].includes(x));
  if (nameIndex < 0 || !keys.includes("quantity"))
    throw new Error("Include Medicine name and Quantity headers.");
  if (rows.length > 200) throw new Error("Import at most 200 rows.");
  const seen = new Set<string>();
  return rows.map((row) => {
    const get = (key: string) => String(row[keys.indexOf(key)] ?? "").trim();
    const baseName = String(row[nameIndex] ?? "").trim();
    const name = [baseName, get("strength"), get("dosage form"), get("pack size")]
      .filter(Boolean)
      .join(" / ");
    const quantity = Number(get("quantity"));
    const unit = get("unit").toLowerCase() || "packs";
    const price = get("unit price");
    const line = {
      ...supplyLine(),
      name,
      quantity,
      unit,
      specification: get("specification"),
      unit_price: price ? Number(price) : null,
      product_snapshot: {
        ...emptyMedicine(),
        name: baseName,
        strength: get("strength"),
        dosage_form: get("dosage form"),
        pack_size: get("pack size"),
        unit,
        category: get("category") || "medicine",
      },
    };
    let issue = !baseName
      ? "Missing medicine name"
      : !Number.isSafeInteger(quantity) || quantity < 1 || quantity > 1000000
        ? "Invalid quantity"
        : !PROCUREMENT_UNITS.includes(unit as (typeof PROCUREMENT_UNITS)[number])
          ? "Unrecognized unit"
          : price &&
              (!Number.isFinite(Number(price)) ||
                Number(price) < 0 ||
                Number(price) >= 100000000 ||
                !/^\d+(\.\d{1,2})?$/.test(price))
            ? "Invalid price"
            : seen.has(name.toLowerCase())
              ? "Possible duplicate in file"
              : "";
    seen.add(name.toLowerCase());
    return { line, issue };
  });
}
