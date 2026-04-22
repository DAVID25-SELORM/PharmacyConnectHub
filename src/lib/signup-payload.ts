import { normalizeGhanaPhone } from "@/lib/ghana-phone";

export type SignupRole = "pharmacy" | "wholesaler";

export type SignupFormInput = {
  businessEmail: string;
  businessName: string;
  businessPhone: string;
  city: string;
  gpsAddress: string;
  licenseNumber: string;
  locationDescription: string;
  ownerEmail: string;
  ownerFullName: string;
  ownerIsSuperintendent: boolean;
  ownerPhone: string;
  region: string;
  superintendentEmail: string;
  superintendentName: string;
  superintendentPhone: string;
  workingHours: string;
};

type SignupMetadata = {
  business_name: string;
  city: string;
  full_name: string;
  gps_address: string | null;
  license_number: string;
  location_description: string | null;
  owner_is_superintendent: boolean;
  phone: string;
  public_email: string;
  public_phone: string;
  region: string;
  role: SignupRole;
  superintendent_email: string | null;
  superintendent_name: string | null;
  superintendent_phone: string | null;
  visibility: {
    owner: { public: false };
    pharmacy: { public: true };
    superintendent: { public: false };
  };
  working_hours: string | null;
};

export function buildSignupPayload(
  form: SignupFormInput,
  role: SignupRole,
): {
  email: string;
  metadata: SignupMetadata;
} {
  const superintendentDetails = {
    email: form.ownerIsSuperintendent ? form.ownerEmail : form.superintendentEmail,
    name: form.ownerIsSuperintendent ? form.ownerFullName : form.superintendentName,
    phone: form.ownerIsSuperintendent ? form.ownerPhone : form.superintendentPhone,
  };

  return {
    email: form.ownerEmail.trim().toLowerCase(),
    metadata: {
      full_name: form.ownerFullName.trim(),
      phone: normalizeGhanaPhone(form.ownerPhone),
      role,
      business_name: form.businessName.trim(),
      license_number: form.licenseNumber.trim(),
      city: form.city.trim(),
      region: form.region,
      public_phone: normalizeGhanaPhone(form.businessPhone),
      public_email: form.businessEmail.trim().toLowerCase(),
      gps_address: form.gpsAddress.trim() || null,
      location_description: form.locationDescription.trim() || null,
      working_hours: form.workingHours.trim() || null,
      owner_is_superintendent: role === "pharmacy" ? form.ownerIsSuperintendent : true,
      superintendent_name: role === "pharmacy" ? superintendentDetails.name.trim() : null,
      superintendent_phone:
        role === "pharmacy" ? normalizeGhanaPhone(superintendentDetails.phone) : null,
      superintendent_email:
        role === "pharmacy" ? superintendentDetails.email.trim().toLowerCase() : null,
      visibility: {
        pharmacy: { public: true },
        superintendent: { public: false },
        owner: { public: false },
      },
    },
  };
}
