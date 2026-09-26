import { describe, expect, it } from "vitest";
import {
  buildVerificationChecklist,
  checklistProgress,
  missingBusinessDetails,
  type ChecklistBusiness,
} from "./onboarding-checklist";

const pharmacy: ChecklistBusiness = {
  type: "pharmacy",
  name: "Good Pharmacy",
  license_number: "P-1",
  phone: "0241000000",
  public_email: "a@b.co",
  city: "Accra",
  region: "Greater Accra",
  address: "GA-123-4567",
  owner_is_superintendent: false,
  superintendent_name: "Ama Mensah",
  verification_status: "pending",
  rejection_reason: null,
};
const docs = [
  { key: "pharmacy_council", label: "Pharmacy Council License" },
  { key: "business_registration", label: "Business Registration" },
];
const states = (steps: ReturnType<typeof buildVerificationChecklist>) =>
  steps.map((step) => `${step.key}:${step.state}`);

describe("verification checklist", () => {
  it("marks everything done except admin review for a complete pending pharmacy", () => {
    const steps = buildVerificationChecklist({
      business: pharmacy,
      uploadedDocTypes: ["pharmacy_council", "business_registration"],
      requiredDocs: docs,
    });
    expect(states(steps)).toEqual([
      "details:done",
      "doc:pharmacy_council:done",
      "doc:business_registration:done",
      "superintendent:done",
      "submitted:done",
      "review:current",
    ]);
    expect(checklistProgress(steps)).toEqual({ done: 5, total: 6, percent: 83 });
  });

  it("points at the first missing document and waits to submit", () => {
    const steps = buildVerificationChecklist({
      business: pharmacy,
      uploadedDocTypes: ["pharmacy_council"],
      requiredDocs: docs,
    });
    expect(states(steps)).toEqual([
      "details:done",
      "doc:pharmacy_council:done",
      "doc:business_registration:current",
      "superintendent:done",
      "submitted:todo",
      "review:todo",
    ]);
  });

  it("asks for the superintendent only for pharmacies that need one", () => {
    const noSuper = { ...pharmacy, superintendent_name: null };
    expect(
      states(
        buildVerificationChecklist({ business: noSuper, uploadedDocTypes: [], requiredDocs: docs }),
      ),
    ).toContain("superintendent:todo");
    expect(
      states(
        buildVerificationChecklist({
          business: { ...noSuper, owner_is_superintendent: true },
          uploadedDocTypes: [],
          requiredDocs: docs,
        }),
      ),
    ).toContain("superintendent:done");
    const wholesaler = { ...pharmacy, type: "wholesaler" as const };
    expect(
      states(
        buildVerificationChecklist({
          business: wholesaler,
          uploadedDocTypes: [],
          requiredDocs: docs,
        }),
      ).some((s) => s.startsWith("superintendent")),
    ).toBe(false);
  });

  it("shows correction requested with the reviewer's note for a rejected business", () => {
    const rejected = {
      ...pharmacy,
      verification_status: "rejected" as const,
      rejection_reason: "Licence unreadable",
    };
    const steps = buildVerificationChecklist({
      business: rejected,
      uploadedDocTypes: ["pharmacy_council", "business_registration"],
      requiredDocs: docs,
    });
    expect(steps.at(-1)).toMatchObject({
      key: "review",
      state: "attention",
      detail: "Reviewer note: Licence unreadable",
    });
    expect(steps.some((step) => step.state === "current")).toBe(false);
  });

  it("shows all done once approved", () => {
    const steps = buildVerificationChecklist({
      business: { ...pharmacy, verification_status: "approved" },
      uploadedDocTypes: ["pharmacy_council", "business_registration"],
      requiredDocs: docs,
    });
    expect(checklistProgress(steps).percent).toBe(100);
  });

  it("lists missing business details", () => {
    expect(
      missingBusinessDetails({ ...pharmacy, license_number: " ", address: null, city: null }),
    ).toEqual(["licence number", "city and region"]);
    expect(
      states(
        buildVerificationChecklist({
          business: { ...pharmacy, phone: null },
          uploadedDocTypes: [],
          requiredDocs: docs,
        }),
      )[0],
    ).toBe("details:current");
  });
});
