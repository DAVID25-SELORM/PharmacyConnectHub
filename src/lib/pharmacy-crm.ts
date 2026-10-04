export const crmEntities = [
  "representatives",
  "companies",
  "rep_companies",
  "rep_products",
  "interactions",
  "followups",
  "procurement_links",
  "activity",
] as const;
export type CrmEntity = (typeof crmEntities)[number];
export type CrmRow = {
  id: string;
  [key: string]: string | boolean | null | Record<string, unknown>;
};
export type CrmData = Record<CrmEntity, CrmRow[]>;
export const emptyCrm = (): CrmData =>
  Object.fromEntries(crmEntities.map((key) => [key, []])) as unknown as CrmData;
export const value = (row: CrmRow, key: string): string => String(row[key] ?? "");
export function lastVisit(data: CrmData, rep: string) {
  return (
    data.interactions
      .filter((r) => r.rep_id === rep && !r.archived && r.interaction_type === "visit")
      .map((r) => value(r, "occurred_at"))
      .sort()
      .at(-1) ?? ""
  );
}
export function nextFollowup(data: CrmData, rep: string) {
  return (
    data.followups
      .filter((r) => r.rep_id === rep && !r.archived && r.status === "pending")
      .map((r) => value(r, "due_at"))
      .sort()[0] ?? ""
  );
}
export function matchesRep(data: CrmData, row: CrmRow, search: string) {
  const companies = data.rep_companies
    .filter((r) => r.rep_id === row.id && !r.archived)
    .map((link) => data.companies.find((c) => c.id === link.company_id))
    .filter(Boolean);
  const products = data.rep_products.filter((r) => r.rep_id === row.id && !r.archived);
  return [
    row.name,
    row.territory,
    row.phone,
    row.email,
    ...companies.map((c) => c?.name),
    ...products.flatMap((p) => [p.label, p.brand]),
  ]
    .join(" ")
    .toLowerCase()
    .includes(search.trim().toLowerCase());
}
