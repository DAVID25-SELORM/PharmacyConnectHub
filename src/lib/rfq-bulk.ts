import type { RfqItemDraft } from "./rfq";
export function rfqRows(matrix: unknown[][]): RfqItemDraft[] {
  const rows = matrix.filter((row) => row.some((cell) => String(cell ?? "").trim()));
  const headers = (rows.shift() ?? []).map((cell) => String(cell).trim().toLowerCase());
  const name = headers.findIndex((h) =>
    ["medicine", "name", "product", "product name"].includes(h),
  );
  const quantity = headers.findIndex((h) => ["quantity", "qty"].includes(h));
  const notes = headers.indexOf("notes");
  if (name < 0 || quantity < 0)
    throw new Error("Use Medicine, Quantity and optional Notes column headers.");
  if (!rows.length) throw new Error("No medicine rows found.");
  return rows.map((row) => ({
    productName: String(row[name] ?? "").trim(),
    quantity: String(row[quantity] ?? "").trim(),
    notes: notes < 0 ? "" : String(row[notes] ?? "").trim(),
  }));
}
export function rfqRowIssues(items: RfqItemDraft[]): Map<number, string> {
  const counts = new Map<string, number>();
  items.forEach((i) => {
    const key = i.productName.trim().toLowerCase();
    if (key) counts.set(key, (counts.get(key) ?? 0) + 1);
  });
  const issues = new Map<number, string>();
  items.forEach((i, index) => {
    if (!i.productName.trim()) issues.set(index, "Enter a medicine name.");
    else if (
      !Number.isSafeInteger(Number(i.quantity)) ||
      Number(i.quantity) <= 0 ||
      Number(i.quantity) > 2147483647
    )
      issues.set(index, "Enter a whole quantity from 1 to 2,147,483,647.");
    else if ((counts.get(i.productName.trim().toLowerCase()) ?? 0) > 1)
      issues.set(index, "Duplicate medicine: combine quantities or distinguish the name/strength.");
  });
  return issues;
}
