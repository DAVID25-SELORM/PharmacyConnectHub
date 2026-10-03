import { PRODUCT_CATEGORIES } from "@/lib/format";

type ImportField =
  | "name"
  | "brand"
  | "category"
  | "form"
  | "pack_size"
  | "price_ghs"
  | "stock"
  | "image_hue";

type RawImportRow = Record<string, string>;

type PdfTextItem = {
  str?: string;
  transform?: number[];
  width?: number;
};

type XlsxModule = typeof import("xlsx");
type PdfJsModule = typeof import("pdfjs-dist/legacy/build/pdf.mjs");

export type ImportedProductDraft = {
  name: string;
  brand: string | null;
  category: string;
  form: string;
  pack_size: string | null;
  price_ghs: number;
  stock: number | null;
  source_row: number;
  image_hue: number;
};

export type ProductImportResult = {
  invalidRows: number[];
  products: ImportedProductDraft[];
  sourceLabel: string;
  warnings: string[];
};

const fieldAliases: Record<ImportField, string[]> = {
  name: ["name", "product", "product name", "medicine", "item", "drug"],
  brand: ["brand", "manufacturer", "company", "label"],
  category: ["category", "group", "class", "therapeutic group"],
  form: ["form", "dosage form", "type"],
  pack_size: ["pack", "pack size", "packsize", "size", "packaging"],
  price_ghs: ["price", "price_ghs", "price ghs", "ghs", "unit price", "selling price"],
  stock: ["stock", "qty", "quantity", "available", "inventory", "units"],
  image_hue: ["image_hue", "hue", "color", "colour"],
};

const categoryLookup = new Map(
  PRODUCT_CATEGORIES.map((category) => [normalizeToken(category), category] as const),
);

let xlsxModulePromise: Promise<XlsxModule> | null = null;
let pdfJsModulePromise: Promise<PdfJsModule> | null = null;

async function loadXlsx() {
  xlsxModulePromise ??= import("xlsx");
  return xlsxModulePromise;
}

async function loadPdfJs() {
  pdfJsModulePromise ??= import("pdfjs-dist/legacy/build/pdf.mjs").then((module) => {
    module.GlobalWorkerOptions.workerSrc = new URL(
      "pdfjs-dist/legacy/build/pdf.worker.min.mjs",
      import.meta.url,
    ).toString();
    return module;
  });

  return pdfJsModulePromise;
}

function normalizeToken(value: string) {
  return value.trim().toLowerCase().replace(/[_-]+/g, " ").replace(/\s+/g, " ");
}

function findImportField(header: string): ImportField | null {
  const normalized = normalizeToken(header);
  for (const [field, aliases] of Object.entries(fieldAliases) as Array<[ImportField, string[]]>) {
    if (aliases.some((alias) => normalizeToken(alias) === normalized)) {
      return field;
    }
  }

  return null;
}

function parseCsvLine(line: string, delimiter: string) {
  const cells: string[] = [];
  let current = "";
  let inQuotes = false;

  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];

    if (char === '"') {
      if (inQuotes && line[index + 1] === '"') {
        current += '"';
        index += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char === delimiter && !inQuotes) {
      cells.push(current.trim());
      current = "";
      continue;
    }

    current += char;
  }

  if (inQuotes) throw new Error("Unclosed quoted value. Use one complete product per row.");
  cells.push(current.trim());
  return cells;
}

function detectDelimiter(line: string) {
  const candidates = ["\t", ";", "|", ","];
  const best = candidates
    .map((delimiter) => ({
      delimiter,
      count: line.split(delimiter).length - 1,
    }))
    .sort((left, right) => right.count - left.count)[0];

  return best && best.count > 0 ? best.delimiter : null;
}

function alignCells(cells: string[], expectedLength: number) {
  if (cells.length === expectedLength) {
    return cells;
  }

  if (cells.length < expectedLength) {
    return [...cells, ...Array.from({ length: expectedLength - cells.length }, () => "")];
  }

  throw new Error(
    "A row has more columns than the headers. Quote values containing commas or use Excel.",
  );
}

function buildRowsFromMatrix(matrix: string[][]) {
  const [headerRow, ...bodyRows] = matrix.filter((row) => row.some((cell) => cell.trim()));
  if (!headerRow || headerRow.length < 2) {
    return [];
  }
  const fields = headerRow.map(findImportField).filter(Boolean);
  if (fields.length !== new Set(fields).size) {
    throw new Error("Duplicate column headers detected. Use one column for each product field.");
  }

  return bodyRows.map((row) => {
    const alignedCells = alignCells(row, headerRow.length);
    return Object.fromEntries(
      headerRow.map((header, index) => [header, alignedCells[index] ?? ""]),
    );
  });
}

function parseDelimitedText(text: string) {
  const lines = text
    .replace(/\r\n/g, "\n")
    .split("\n")
    .filter((line) => line.trim());

  if (lines.length < 2) {
    return [];
  }

  const delimiter = detectDelimiter(lines[0]);
  if (delimiter) {
    return buildRowsFromMatrix(lines.map((line) => parseCsvLine(line, delimiter)));
  }

  return buildRowsFromMatrix(lines.map((line) => line.split(/\s{2,}/).map((cell) => cell.trim())));
}

async function rowsFromWorksheet(buffer: ArrayBuffer) {
  const XLSX = await loadXlsx();
  const workbook = XLSX.read(buffer, { type: "array" });
  const firstSheetName = workbook.SheetNames[0];
  if (!firstSheetName) {
    return [];
  }

  const worksheet = workbook.Sheets[firstSheetName];
  const matrix = XLSX.utils.sheet_to_json<unknown[]>(worksheet, {
    header: 1,
    defval: "",
    raw: false,
  });

  return buildRowsFromMatrix(matrix.map((row) => row.map((value) => String(value ?? "").trim())));
}

function splitPdfLine(line: string) {
  return line
    .split(/\s*\|\s*|\t+|\s{2,}/)
    .map((cell) => cell.trim())
    .filter(Boolean);
}

function groupPdfLines(items: PdfTextItem[]) {
  const rows: Array<{ y: number; parts: Array<{ text: string; x: number; width: number }> }> = [];

  for (const item of items) {
    const text = item.str?.trim();
    const transform = item.transform;
    if (!text || !transform) {
      continue;
    }

    const y = Math.round(transform[5]);
    const existingRow = rows.find((row) => Math.abs(row.y - y) <= 2);
    const targetRow = existingRow ?? { y, parts: [] };

    targetRow.parts.push({
      text,
      width: item.width ?? 0,
      x: transform[4],
    });

    if (!existingRow) {
      rows.push(targetRow);
    }
  }

  return rows
    .sort((left, right) => right.y - left.y)
    .map((row) => {
      const orderedParts = row.parts.sort((left, right) => left.x - right.x);

      return orderedParts
        .map((part, index) => {
          if (index === 0) {
            return part.text;
          }

          const previous = orderedParts[index - 1];
          const gap = part.x - (previous.x + previous.width);
          const separator = gap > 24 ? " | " : gap > 8 ? "  " : " ";
          return `${separator}${part.text}`;
        })
        .join("")
        .trim();
    })
    .filter(Boolean);
}

async function rowsFromPdf(buffer: ArrayBuffer) {
  const { getDocument } = await loadPdfJs();
  const pdf = await getDocument({ data: buffer }).promise;
  const lines: string[] = [];

  for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber += 1) {
    const page = await pdf.getPage(pageNumber);
    const textContent = await page.getTextContent();
    lines.push(...groupPdfLines(textContent.items as PdfTextItem[]));
  }

  const headerIndex = lines.findIndex((line) => {
    const cells = splitPdfLine(line);
    const mappedFields = cells.map(findImportField).filter(Boolean);
    return (
      mappedFields.length >= 2 &&
      mappedFields.includes("name") &&
      mappedFields.includes("price_ghs")
    );
  });

  if (headerIndex < 0) {
    throw new Error(
      "We couldn't detect a structured product table in this PDF. Use CSV, Excel, or paste the table text instead.",
    );
  }

  const matrix = lines
    .slice(headerIndex)
    .map(splitPdfLine)
    .filter((row) => row.length > 0);

  return buildRowsFromMatrix(matrix);
}

function parseNumericValue(value: string, fallback: number) {
  if (!value.trim()) {
    return fallback;
  }

  const normalized = value.trim().replace(/^(?:GH₵|GHS|GH¢)\s*/i, "");
  if (!/^-?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?$/.test(normalized)) return fallback;
  const parsed = Number(normalized.replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : fallback;
}

function buildImportedProducts(rawRows: RawImportRow[], sourceLabel: string): ProductImportResult {
  if (rawRows.length > 5000) throw new Error("Import at most 5,000 products at a time.");
  const invalidRows: number[] = [];
  const products: ImportedProductDraft[] = [];
  const warnings: string[] = [];
  let categoryFallbackCount = 0;

  rawRows.forEach((rawRow, index) => {
    const mappedRow = Object.fromEntries(
      Object.entries(rawRow).flatMap(([header, value]) => {
        const field = findImportField(header);
        return field ? [[field, value]] : [];
      }),
    ) as Partial<Record<ImportField, string>>;

    const name = mappedRow.name?.trim() ?? "";
    const price = parseNumericValue(mappedRow.price_ghs ?? "", 0);
    const stockText = mappedRow.stock?.trim() ?? "";
    const stock = stockText ? parseNumericValue(stockText, NaN) : null;
    const isEmptyRow = Object.values(mappedRow).every((value) => !(value ?? "").trim());

    if (isEmptyRow) {
      return;
    }

    if (
      !name ||
      price <= 0 ||
      price > 99999999.99 ||
      (stock !== null && (!Number.isSafeInteger(stock) || stock < 0 || stock > 2147483647))
    ) {
      invalidRows.push(index + 2);
      return;
    }

    const normalizedCategoryKey = normalizeToken(mappedRow.category ?? "");
    const category = categoryLookup.get(normalizedCategoryKey) ?? "Other";
    if (
      (mappedRow.category ?? "").trim() &&
      category === "Other" &&
      normalizedCategoryKey !== "other"
    ) {
      categoryFallbackCount += 1;
    }

    products.push({
      name,
      brand: mappedRow.brand?.trim() || null,
      category,
      form: mappedRow.form?.trim() || "Tablet",
      image_hue: Math.round(parseNumericValue(mappedRow.image_hue ?? "", hashHue(name))),
      pack_size: mappedRow.pack_size?.trim() || null,
      price_ghs: price,
      stock,
      source_row: index + 2,
    });
  });

  if (categoryFallbackCount > 0) {
    warnings.push(
      `${categoryFallbackCount} row(s) used "Other" because the category name didn't match the Drugxone list.`,
    );
  }

  return {
    invalidRows,
    products,
    sourceLabel,
    warnings,
  };
}

function hashHue(value: string) {
  let hash = 0;
  for (const char of value) {
    hash = (hash * 31 + char.charCodeAt(0)) % 360;
  }

  return hash || 200;
}

async function extractImportRows(file: File): Promise<{ rows: RawImportRow[]; sourceLabel: string }> {
  const extension = file.name.split(".").pop()?.toLowerCase() ?? "";

  if (extension === "pdf") {
    return { rows: await rowsFromPdf(await file.arrayBuffer()), sourceLabel: "PDF" };
  }

  if (["xls", "xlsx"].includes(extension)) {
    return { rows: await rowsFromWorksheet(await file.arrayBuffer()), sourceLabel: extension.toUpperCase() };
  }

  if (["csv", "tsv", "txt"].includes(extension)) {
    return { rows: parseDelimitedText(await file.text()), sourceLabel: extension.toUpperCase() };
  }

  throw new Error("Unsupported file type. Use CSV, TSV, TXT, XLSX, XLS, or PDF.");
}

export async function parseProductImportFile(file: File): Promise<ProductImportResult> {
  const { rows, sourceLabel } = await extractImportRows(file);
  return buildImportedProducts(rows, sourceLabel);
}

export function parseProductImportText(text: string): ProductImportResult {
  const rows = parseDelimitedText(text);
  return buildImportedProducts(rows, "pasted table");
}

// ---------------------------------------------------------------------------
// Pharmacy inventory import: reuses the same file/PDF/CSV extraction above, but with its own
// field aliases and relaxed validation -- a pharmacy stock count has no mandatory selling price,
// unlike a wholesaler catalog upload where price_ghs is required on every row.
// ---------------------------------------------------------------------------
type InventoryImportField =
  | "name" | "brand" | "category" | "form" | "pack_size" | "unit_cost_ghs" | "stock" | "reorder_level"
  | "item_type" | "generic_name" | "strength" | "manufacturer" | "barcode" | "batch_number"
  | "expiry_date" | "selling_price_ghs" | "supplier" | "unit_of_measure" | "model" | "serial_number" | "warranty_info";

const inventoryFieldAliases: Record<InventoryImportField, string[]> = {
  name: ["name", "product", "product name", "medicine", "item", "item name", "drug"],
  brand: ["brand", "label"],
  category: ["category", "group", "class", "therapeutic group"],
  form: ["form", "dosage form", "type"],
  pack_size: ["pack", "pack size", "packsize", "size", "packaging"],
  unit_cost_ghs: ["cost", "unit cost", "cost price", "cost_ghs", "price", "price_ghs"],
  stock: ["stock", "qty", "quantity", "available", "inventory", "units", "on hand", "stock on hand"],
  reorder_level: ["reorder level", "reorder point", "reorder_level", "min stock", "minimum stock", "low stock threshold"],
  item_type: ["item type", "item_type", "type of item"],
  generic_name: ["generic name", "generic_name", "generic"],
  strength: ["strength"],
  manufacturer: ["manufacturer", "company"],
  barcode: ["barcode", "sku", "sku/barcode", "sku / barcode"],
  batch_number: ["batch", "batch number", "batch_number", "lot", "lot number"],
  expiry_date: ["expiry", "expiry date", "expiry_date", "exp date", "exp"],
  selling_price_ghs: ["selling price", "selling_price_ghs", "sale price", "retail price"],
  supplier: ["supplier", "vendor"],
  unit_of_measure: ["unit", "unit of measure", "uom"],
  model: ["model"],
  serial_number: ["serial number", "serial_number", "serial"],
  warranty_info: ["warranty", "warranty information", "warranty_info"],
};

const KNOWN_ITEM_TYPES = new Set(["medicine", "medical_consumable", "medical_equipment", "non_medical"]);
const ITEM_TYPE_IMPORT_ALIASES: Record<string, string> = {
  medicine: "medicine",
  "medical consumable": "medical_consumable",
  medical_consumable: "medical_consumable",
  consumable: "medical_consumable",
  "medical equipment": "medical_equipment",
  medical_equipment: "medical_equipment",
  equipment: "medical_equipment",
  "non-medical item": "non_medical",
  "non medical item": "non_medical",
  non_medical: "non_medical",
  "non-medical": "non_medical",
};

/** YYYY-MM-DD that is also a real date. The format alone lets 2026-02-31 through, which Postgres
 * rejects on insert -- failing the whole batch with an unhelpful message instead of one bad row. */
export function isRealCalendarDate(text: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
  if (!match) return false;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

function normalizeItemType(raw: string | undefined): string | null {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return null;
  const key = trimmed.toLowerCase();
  if (KNOWN_ITEM_TYPES.has(key)) return key;
  return ITEM_TYPE_IMPORT_ALIASES[key] ?? null;
}

function findInventoryImportField(header: string): InventoryImportField | null {
  const normalized = normalizeToken(header);
  for (const [field, aliases] of Object.entries(inventoryFieldAliases) as Array<[InventoryImportField, string[]]>) {
    if (aliases.some((alias) => normalizeToken(alias) === normalized)) {
      return field;
    }
  }

  return null;
}

export type ImportedInventoryItemDraft = {
  name: string;
  brand: string | null;
  category: string | null;
  form: string | null;
  pack_size: string | null;
  unitCostGhs: number | null;
  stock: number | null;
  reorderLevel: number | null;
  itemType: string | null;
  genericName: string | null;
  strength: string | null;
  manufacturer: string | null;
  barcode: string | null;
  batchNumber: string | null;
  expiryDate: string | null;
  sellingPriceGhs: number | null;
  supplier: string | null;
  unitOfMeasure: string | null;
  model: string | null;
  serialNumber: string | null;
  warrantyInfo: string | null;
  source_row: number;
};

export type InventoryImportResult = {
  invalidRows: number[];
  items: ImportedInventoryItemDraft[];
  sourceLabel: string;
  warnings: string[];
};

function buildImportedInventoryItems(rawRows: RawImportRow[], sourceLabel: string): InventoryImportResult {
  if (rawRows.length > 5000) throw new Error("Import at most 5,000 items at a time.");
  const invalidRows: number[] = [];
  const items: ImportedInventoryItemDraft[] = [];
  const warnings: string[] = [];

  rawRows.forEach((rawRow, index) => {
    const mappedRow = Object.fromEntries(
      Object.entries(rawRow).flatMap(([header, value]) => {
        const field = findInventoryImportField(header);
        return field ? [[field, value]] : [];
      }),
    ) as Partial<Record<InventoryImportField, string>>;

    const name = mappedRow.name?.trim() ?? "";
    const isEmptyRow = Object.values(mappedRow).every((value) => !(value ?? "").trim());
    if (isEmptyRow) {
      return;
    }

    const stockText = mappedRow.stock?.trim() ?? "";
    const stock = stockText ? parseNumericValue(stockText, NaN) : null;
    const costText = mappedRow.unit_cost_ghs?.trim() ?? "";
    const unitCostGhs = costText ? parseNumericValue(costText, NaN) : null;
    const reorderText = mappedRow.reorder_level?.trim() ?? "";
    const reorderLevel = reorderText ? parseNumericValue(reorderText, NaN) : null;
    const sellingPriceText = mappedRow.selling_price_ghs?.trim() ?? "";
    const sellingPriceGhs = sellingPriceText ? parseNumericValue(sellingPriceText, NaN) : null;
    const itemType = normalizeItemType(mappedRow.item_type);
    const itemTypeInvalid = Boolean(mappedRow.item_type?.trim()) && itemType === null;
    const expiryDateText = mappedRow.expiry_date?.trim() ?? "";
    const expiryDateInvalid = Boolean(expiryDateText) && !isRealCalendarDate(expiryDateText);

    if (
      !name ||
      itemTypeInvalid ||
      expiryDateInvalid ||
      (stock !== null && (!Number.isSafeInteger(stock) || stock < 0 || stock > 2147483647)) ||
      (unitCostGhs !== null && (!Number.isFinite(unitCostGhs) || unitCostGhs < 0 || unitCostGhs > 99999999.99)) ||
      (sellingPriceGhs !== null && (!Number.isFinite(sellingPriceGhs) || sellingPriceGhs < 0 || sellingPriceGhs > 99999999.99)) ||
      (reorderLevel !== null && (!Number.isSafeInteger(reorderLevel) || reorderLevel < 0))
    ) {
      invalidRows.push(index + 2);
      return;
    }

    items.push({
      name,
      brand: mappedRow.brand?.trim() || null,
      category: mappedRow.category?.trim() || null,
      form: mappedRow.form?.trim() || null,
      pack_size: mappedRow.pack_size?.trim() || null,
      unitCostGhs,
      stock,
      reorderLevel,
      itemType,
      genericName: mappedRow.generic_name?.trim() || null,
      strength: mappedRow.strength?.trim() || null,
      manufacturer: mappedRow.manufacturer?.trim() || null,
      barcode: mappedRow.barcode?.trim() || null,
      batchNumber: mappedRow.batch_number?.trim() || null,
      expiryDate: mappedRow.expiry_date?.trim() || null,
      sellingPriceGhs,
      supplier: mappedRow.supplier?.trim() || null,
      unitOfMeasure: mappedRow.unit_of_measure?.trim() || null,
      model: mappedRow.model?.trim() || null,
      serialNumber: mappedRow.serial_number?.trim() || null,
      warrantyInfo: mappedRow.warranty_info?.trim() || null,
      source_row: index + 2,
    });
  });

  return { invalidRows, items, sourceLabel, warnings };
}

export async function parsePharmacyInventoryImportFile(file: File): Promise<InventoryImportResult> {
  const { rows, sourceLabel } = await extractImportRows(file);
  return buildImportedInventoryItems(rows, sourceLabel);
}

export function parsePharmacyInventoryImportText(text: string): InventoryImportResult {
  const rows = parseDelimitedText(text);
  return buildImportedInventoryItems(rows, "pasted table");
}
