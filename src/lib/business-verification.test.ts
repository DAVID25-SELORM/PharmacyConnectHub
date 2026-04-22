import { describe, expect, it } from "vitest";
import { getIncompleteVerificationFields } from "@/lib/business-verification";

describe("getIncompleteVerificationFields", () => {
  it("returns no issues when a wholesaler owner contact is complete", () => {
    expect(
      getIncompleteVerificationFields(
        {
          type: "wholesaler",
          owner_is_superintendent: true,
          superintendent_name: null,
        },
        {
          owner_full_name: "Ama Boateng",
          owner_phone: "+233241234567",
          owner_email: "ama@example.com",
          superintendent_full_name: null,
          superintendent_phone: null,
          superintendent_email: null,
        },
      ),
    ).toEqual([]);
  });

  it("flags missing owner details", () => {
    expect(
      getIncompleteVerificationFields(
        {
          type: "pharmacy",
          owner_is_superintendent: true,
          superintendent_name: null,
        },
        {
          owner_full_name: "",
          owner_phone: "123",
          owner_email: "wrong",
          superintendent_full_name: null,
          superintendent_phone: null,
          superintendent_email: null,
        },
      ),
    ).toEqual(["owner name", "owner phone", "owner email"]);
  });

  it("flags separate superintendent details for pharmacies that require them", () => {
    expect(
      getIncompleteVerificationFields(
        {
          type: "pharmacy",
          owner_is_superintendent: false,
          superintendent_name: null,
        },
        {
          owner_full_name: "Kwame Mensah",
          owner_phone: "+233241234567",
          owner_email: "kwame@example.com",
          superintendent_full_name: "",
          superintendent_phone: null,
          superintendent_email: "not-an-email",
        },
      ),
    ).toEqual(["superintendent name", "superintendent phone", "superintendent email"]);
  });

  it("accepts a superintendent name from the public business record when the private row is blank", () => {
    expect(
      getIncompleteVerificationFields(
        {
          type: "pharmacy",
          owner_is_superintendent: false,
          superintendent_name: "Pharm. Efua Asare",
        },
        {
          owner_full_name: "Kwame Mensah",
          owner_phone: "+233241234567",
          owner_email: "kwame@example.com",
          superintendent_full_name: "",
          superintendent_phone: "+233201112223",
          superintendent_email: "efua@example.com",
        },
      ),
    ).toEqual([]);
  });
});
