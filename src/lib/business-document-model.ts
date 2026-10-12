import type { DocumentBusiness } from "./document-branding";

/** Presentation only: identifiers, money and identities must come from authorized records. */
export type BusinessDocumentModel = {
  title: string;
  reference: string;
  issuer: DocumentBusiness | null | undefined;
  recipient?: { label: string; name: string; lines?: string[] };
  metadata: Array<[string, string]>;
  columns: string[];
  rows: string[][];
  numericColumns?: number[];
  summary?: Array<[string, string]>;
  notes?: string[];
};

export const documentMoney = (value: number) =>
  new Intl.NumberFormat("en-GH", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value);
