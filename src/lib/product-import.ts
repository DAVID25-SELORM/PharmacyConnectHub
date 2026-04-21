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
  stock: number;
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

  const overflow = cells.length - expectedLength + 1;
  return [cells.slice(0, overflow).join(" "), ...cells.slice(overflow)];
}

function buildRowsFromMatrix(matrix: string[][]) {
  const [headerRow, ...bodyRows] = matrix.filter((row) => row.some((cell) => cell.trim()));
  if (!headerRow || headerRow.length < 2) {
    return [];
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
    .map((line) => line.trim())
    .filter(Boolean);

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
  const rawRows = XLSX.utils.sheet_to_json<Record<string, unknown>>(worksheet, {
    defval: "",
    raw: false,
  });

  return rawRows.map((row) =>
    Object.fromEntries(
      Object.entries(row)
        .filter(([header]) => !header.startsWith("__EMPTY"))
        .map(([header, value]) => [header, String(value ?? "").trim()]),
    ),
  );
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

  const normalized = value.replace(/[^\d.,-]/g, "").replace(/,/g, "");
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function buildImportedProducts(rawRows: RawImportRow[], sourceLabel: string): ProductImportResult {
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
    const isEmptyRow = Object.values(mappedRow).every((value) => !(value ?? "").trim());

    if (isEmptyRow) {
      return;
    }

    if (!name || price <= 0) {
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
      stock: Math.max(0, Math.round(parseNumericValue(mappedRow.stock ?? "", 0))),
    });
  });

  if (categoryFallbackCount > 0) {
    warnings.push(
      `${categoryFallbackCount} row(s) used "Other" because the category name didn't match the PharmaHub list.`,
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

export async function parseProductImportFile(file: File): Promise<ProductImportResult> {
  const extension = file.name.split(".").pop()?.toLowerCase() ?? "";

  if (extension === "pdf") {
    const rows = await rowsFromPdf(await file.arrayBuffer());
    return buildImportedProducts(rows, "PDF");
  }

  if (["xls", "xlsx"].includes(extension)) {
    const rows = await rowsFromWorksheet(await file.arrayBuffer());
    return buildImportedProducts(rows, extension.toUpperCase());
  }

  if (["csv", "tsv", "txt"].includes(extension)) {
    const rows = parseDelimitedText(await file.text());
    return buildImportedProducts(rows, extension.toUpperCase());
  }

  throw new Error("Unsupported file type. Use CSV, TSV, TXT, XLSX, XLS, or PDF.");
}

export function parseProductImportText(text: string): ProductImportResult {
  const rows = parseDelimitedText(text);
  return buildImportedProducts(rows, "pasted table");
}
