// Small display helpers shared by the RFQ screens.

export const RFQ_PAYMENT_OPTIONS: [string, string][] = [
  ["cod", "Cash on delivery"],
  ["credit", "Credit"],
  ["bank_transfer", "Bank transfer"],
  ["momo", "Mobile money"],
  ["cheque", "Cheque"],
  ["other", "Other"],
];
export const paymentLabel = (value: string) =>
  RFQ_PAYMENT_OPTIONS.find(([v]) => v === value)?.[1] ?? value.replaceAll("_", " ");

export const RFQ_CATEGORY_OPTIONS: [string, string][] = [
  ["cash_private", "Cash / private"],
  ["nhis", "NHIS"],
  ["other", "Other"],
];

export const rfqDate = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })
    : "Not set";

export const rfqDateTime = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" })
    : "Not set";
