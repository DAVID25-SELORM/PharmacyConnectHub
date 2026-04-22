function trimPhoneValue(value: string) {
  return value.replace(/\s+/g, "").replace(/[^\d+]/g, "");
}

export function normalizeGhanaPhone(phone: string) {
  const sanitized = trimPhoneValue(phone);

  if (!sanitized) {
    throw new Error("Phone number is required");
  }

  let nationalNumber = "";

  if (sanitized.startsWith("+233")) {
    nationalNumber = sanitized.slice(4).replace(/\D/g, "");
  } else if (sanitized.startsWith("233")) {
    nationalNumber = sanitized.slice(3).replace(/\D/g, "");
  } else if (sanitized.startsWith("0")) {
    nationalNumber = sanitized.slice(1).replace(/\D/g, "");
  } else {
    nationalNumber = sanitized.replace(/\D/g, "");
  }

  if (nationalNumber.length === 10 && nationalNumber.startsWith("0")) {
    nationalNumber = nationalNumber.slice(1);
  }

  if (nationalNumber.length !== 9) {
    throw new Error("Enter a valid Ghana phone number");
  }

  return `+233${nationalNumber}`;
}

export function isValidGhanaPhone(phone: string) {
  try {
    normalizeGhanaPhone(phone);
    return true;
  } catch {
    return false;
  }
}

export function formatGhanaPhone(phone: string) {
  try {
    const normalized = normalizeGhanaPhone(phone);
    const nationalNumber = normalized.slice(4);
    return `+233 ${nationalNumber.slice(0, 2)} ${nationalNumber.slice(2, 5)} ${nationalNumber.slice(5)}`;
  } catch {
    return phone.trim();
  }
}
