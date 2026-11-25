import { describe, expect, it } from "vitest";
import {
  businessKindLabel,
  isHospitalOrClinic,
  businessKindNoun,
  licenceUploadPrompt,
  pharmacyLicenceLabel,
} from "@/lib/business-kind";

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

describe("wording for each kind of business", () => {
  const pharmacy = { type: "pharmacy" } as const;
  const clinic = { type: "pharmacy", facility_kind: "hospital_clinic" } as const;
  const wholesaler = { type: "wholesaler" } as const;

  it("names the business in a sentence", () => {
    expect(businessKindNoun(pharmacy)).toBe("pharmacy");
    expect(businessKindNoun(clinic)).toBe("hospital or clinic");
    expect(businessKindNoun(wholesaler)).toBe("wholesale business");
  });

  it("keeps the pharmacy and wholesaler wording as it was", () => {
    expect(licenceUploadPrompt(pharmacy)).toBe(
      "Upload your Pharmacy Council license to start ordering.",
    );
    expect(licenceUploadPrompt(wholesaler)).toBe(
      "Upload your wholesale license to start receiving orders.",
    );
    expect(pharmacyLicenceLabel(pharmacy)).toBe("Pharmacy Council License");
  });

  it("tells a hospital or clinic which Pharmacy Council licence is meant", () => {
    expect(licenceUploadPrompt(clinic)).toContain("your facility's pharmacy or dispensary");
    expect(pharmacyLicenceLabel(clinic)).toBe(
      "Pharmacy Council License (facility pharmacy or dispensary)",
    );
  });
});
