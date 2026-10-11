/**
 * Trusted business identity used by commercial documents.  The issuer is selected
 * from the transaction, never from the person viewing or printing the document.
 */
export type DocumentBusiness = {
  id?: string;
  name: string;
  address?: string | null;
  city?: string | null;
  region?: string | null;
  phone?: string | null;
  public_email?: string | null;
  license_number?: string | null;
  branding?: DocumentBranding | null;
};

export type DocumentBranding = {
  display_name?: string | null;
  logo_url?: string | null;
  accent_color?: string | null;
  show_license?: boolean | null;
  show_secondary_contact?: boolean | null;
  footer_note?: string | null;
  signatory_name?: string | null;
  signatory_title?: string | null;
  payment_instructions?: string | null;
};

export type ResolvedBranding = Required<Pick<DocumentBranding, "show_license" | "show_secondary_contact">> &
  Omit<DocumentBranding, "show_license" | "show_secondary_contact"> & {
    name: string;
    accentColor: string;
    contactLines: string[];
  };

const SAFE_ACCENT = /^#[0-9a-f]{6}$/i;

export function resolveDocumentBranding(business: DocumentBusiness | null | undefined): ResolvedBranding {
  const branding = business?.branding ?? {};
  const address = [business?.address, [business?.city, business?.region].filter(Boolean).join(", ")]
    .filter((value): value is string => Boolean(value?.trim()))
    .map((value) => value.trim());
  const contacts = [
    business?.phone ? `Tel: ${business.phone}` : "",
    branding.show_secondary_contact !== false && business?.public_email ? business.public_email : "",
    branding.show_license !== false && business?.license_number ? `Licence: ${business.license_number}` : "",
  ].filter(Boolean);
  return {
    ...branding,
    name: business?.name || "Business",
    accentColor: SAFE_ACCENT.test(branding.accent_color ?? "") ? branding.accent_color! : "#0f766e",
    contactLines: [...address, ...contacts],
    show_license: branding.show_license !== false,
    show_secondary_contact: branding.show_secondary_contact !== false,
  };
}

export function documentFileName(type: string, reference: string) {
  const safe = `${type}-${reference}`.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
  return `${safe || "business-document"}.pdf`;
}
