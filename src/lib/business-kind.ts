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
