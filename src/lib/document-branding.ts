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
  logo_path?: string | null;
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
/** Keep colored text and white-on-color table headers readable. */
export function readableAccent(value: string | null | undefined) {
  if (!SAFE_ACCENT.test(value ?? "")) return "#0f766e";
  const channels = [1,3,5].map(i => parseInt(value!.slice(i,i+2),16)/255).map(v=>v<=0.04045?v/12.92:((v+0.055)/1.055)**2.4);
  const luminance=0.2126*channels[0]+0.7152*channels[1]+0.0722*channels[2];
  return 1.05/(luminance+0.05)>=4.5 ? value! : "#0f766e";
}

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
    accentColor: readableAccent(branding.accent_color),
    contactLines: [...address, ...contacts],
    show_license: branding.show_license !== false,
    show_secondary_contact: branding.show_secondary_contact !== false,
  };
}

export function documentFileName(type: string, reference: string) {
  const safe = `${type}-${reference}`.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
  return `${safe || "business-document"}.pdf`;
}
