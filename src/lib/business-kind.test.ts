import { describe, expect, it } from "vitest";
import { businessKindLabel, isHospitalOrClinic } from "@/lib/business-kind";

describe("business kind", () => {
  it("treats a pharmacy-type business marked hospital_clinic as a hospital or clinic", () => {
    expect(isHospitalOrClinic({ type: "pharmacy", facility_kind: "hospital_clinic" })).toBe(true);
    expect(businessKindLabel({ type: "pharmacy", facility_kind: "hospital_clinic" })).toBe(
      "Hospital / clinic",
    );
  });

  it("keeps ordinary pharmacies and wholesalers as they were", () => {
    expect(businessKindLabel({ type: "pharmacy" })).toBe("Pharmacy");
    expect(businessKindLabel({ type: "pharmacy", facility_kind: null })).toBe("Pharmacy");
    expect(businessKindLabel({ type: "wholesaler", facility_kind: null })).toBe("Wholesaler");
  });

  it("never reports a wholesaler as a hospital or clinic", () => {
    expect(isHospitalOrClinic({ type: "wholesaler", facility_kind: "hospital_clinic" })).toBe(
      false,
    );
  });
});
