import { normalizeGhanaPhone } from "@/lib/ghana-phone";

type VerificationBusiness = {
  owner_is_superintendent: boolean;
  superintendent_name: string | null;
  type: "pharmacy" | "wholesaler";
};

type VerificationPrivateContact = {
  owner_email: string | null;
  owner_full_name: string | null;
  owner_phone: string | null;
  superintendent_email: string | null;
  superintendent_full_name: string | null;
  superintendent_phone: string | null;
};

function looksLikeEmail(value: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

export function hasText(value: string | null | undefined) {
  return Boolean(value?.trim());
}

export function hasUsablePhone(value: string | null | undefined) {
  if (!hasText(value)) {
    return false;
  }

  try {
    normalizeGhanaPhone(value);
    return true;
  } catch {
    return false;
  }
}

export function hasUsableEmail(value: string | null | undefined) {
  return hasText(value) && looksLikeEmail(value);
}

export function getIncompleteVerificationFields(
  biz: VerificationBusiness,
  privateContact: VerificationPrivateContact | null,
) {
  const missingFields: string[] = [];
  const superintendentName = hasText(privateContact?.superintendent_full_name)
    ? (privateContact?.superintendent_full_name ?? null)
    : biz.superintendent_name;

  if (!hasText(privateContact?.owner_full_name)) {
    missingFields.push("owner name");
  }

  if (!hasUsablePhone(privateContact?.owner_phone)) {
    missingFields.push("owner phone");
  }

  if (!hasUsableEmail(privateContact?.owner_email)) {
    missingFields.push("owner email");
  }

  if (biz.type === "pharmacy" && !biz.owner_is_superintendent) {
    if (!hasText(superintendentName)) {
      missingFields.push("superintendent name");
    }

    if (!hasUsablePhone(privateContact?.superintendent_phone)) {
      missingFields.push("superintendent phone");
    }

    if (!hasUsableEmail(privateContact?.superintendent_email)) {
      missingFields.push("superintendent email");
    }
  }

  return missingFields;
}
