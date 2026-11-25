export type FacilityKind = "hospital_clinic";

type KindSource = {
  type: "pharmacy" | "wholesaler";
  facility_kind?: FacilityKind | null;
};

/**
 * A hospital or clinic is a buyer that works like a pharmacy, so its type stays "pharmacy" and
 * facility_kind says which kind of buyer it is. Everything keyed on type keeps working for it.
 */
export function isHospitalOrClinic(business: KindSource) {
  return business.type === "pharmacy" && business.facility_kind === "hospital_clinic";
}

/** What to call the business in the interface: Pharmacy, Hospital / clinic or Wholesaler. */
export function businessKindLabel(business: KindSource) {
  if (business.type === "wholesaler") {
    return "Wholesaler";
  }
  return isHospitalOrClinic(business) ? "Hospital / clinic" : "Pharmacy";
}

/** The same, for the middle of a sentence: "your pharmacy", "your hospital or clinic". */
export function businessKindNoun(business: KindSource) {
  if (business.type === "wholesaler") {
    return "wholesale business";
  }
  return isHospitalOrClinic(business) ? "hospital or clinic" : "pharmacy";
}

/**
 * What an unapproved business is asked to upload. A hospital or clinic needs the same Pharmacy
 * Council licence as a pharmacy: the one for its own pharmacy or dispensary.
 */
export function licenceUploadPrompt(business: KindSource) {
  if (business.type === "wholesaler") {
    return "Upload your wholesale license to start receiving orders.";
  }
  return isHospitalOrClinic(business)
    ? "Upload the Pharmacy Council license for your facility's pharmacy or dispensary to start ordering."
    : "Upload your Pharmacy Council license to start ordering.";
}

/** The label of the Pharmacy Council licence on the document upload page. */
export function pharmacyLicenceLabel(business: KindSource) {
  return isHospitalOrClinic(business)
    ? "Pharmacy Council License (facility pharmacy or dispensary)"
    : "Pharmacy Council License";
}
