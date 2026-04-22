import { describe, expect, it } from "vitest";
import { buildSignupPayload } from "@/lib/signup-payload";

const baseForm = {
  businessEmail: "hello@pharmacy.com",
  businessName: "PharmaHub Pharmacy",
  businessPhone: "0241234567",
  city: "Accra",
  gpsAddress: "GA-123-4567",
  licenseNumber: "PHA-001",
  locationDescription: "Opposite the district hospital",
  ownerEmail: "owner@pharmacy.com",
  ownerFullName: "Adwoa Owusu",
  ownerIsSuperintendent: true,
  ownerPhone: "0201112223",
  region: "Greater Accra",
  superintendentEmail: "superintendent@pharmacy.com",
  superintendentName: "Dr. Superintendent",
  superintendentPhone: "0273334444",
  workingHours: "Mon-Sat 8am-9pm",
};

describe("buildSignupPayload", () => {
  it("maps a pharmacy where the owner is also the superintendent", () => {
    const payload = buildSignupPayload(baseForm, "pharmacy");

    expect(payload.email).toBe("owner@pharmacy.com");
    expect(payload.metadata).toMatchObject({
      full_name: "Adwoa Owusu",
      phone: "+233201112223",
      public_phone: "+233241234567",
      public_email: "hello@pharmacy.com",
      owner_is_superintendent: true,
      superintendent_name: "Adwoa Owusu",
      superintendent_phone: "+233201112223",
      superintendent_email: "owner@pharmacy.com",
      gps_address: "GA-123-4567",
      location_description: "Opposite the district hospital",
      working_hours: "Mon-Sat 8am-9pm",
    });
  });

  it("maps a pharmacy with a separate superintendent", () => {
    const payload = buildSignupPayload(
      {
        ...baseForm,
        ownerIsSuperintendent: false,
      },
      "pharmacy",
    );

    expect(payload.metadata).toMatchObject({
      owner_is_superintendent: false,
      superintendent_name: "Dr. Superintendent",
      superintendent_phone: "+233273334444",
      superintendent_email: "superintendent@pharmacy.com",
    });
  });

  it("nulls superintendent fields for wholesalers", () => {
    const payload = buildSignupPayload(
      {
        ...baseForm,
        gpsAddress: "",
        locationDescription: "",
        workingHours: "",
      },
      "wholesaler",
    );

    expect(payload.metadata).toMatchObject({
      role: "wholesaler",
      owner_is_superintendent: true,
      superintendent_name: null,
      superintendent_phone: null,
      superintendent_email: null,
      gps_address: null,
      location_description: null,
      working_hours: null,
    });
  });
});
