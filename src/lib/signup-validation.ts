import { z } from "zod";
import { isValidGhanaPhone } from "@/lib/ghana-phone";
import type { SignupRole } from "@/lib/signup-payload";

const baseSchema = z.object({
  ownerFullName: z.string().trim().min(2, "Owner name is required").max(100),
  ownerPhone: z
    .string()
    .trim()
    .min(1, "Owner phone is required")
    .refine(isValidGhanaPhone, "Owner phone: enter one valid Ghana phone number"),
  businessName: z.string().trim().min(2, "Business name is required").max(150),
  licenseNumber: z.string().trim().min(3, "License # is required").max(50),
  businessPhone: z
    .string()
    .trim()
    .min(1, "Business phone is required")
    .refine(isValidGhanaPhone, "Business phone: enter one valid Ghana phone number"),
  businessEmail: z.string().trim().email("Enter a valid public business email").max(255),
  city: z.string().trim().min(2, "City is required").max(60),
  region: z.string().min(2, "Region is required"),
  gpsAddress: z.string().trim().max(160),
  locationDescription: z.string().trim().max(240),
  workingHours: z.string().trim().max(120),
  ownerEmail: z.string().trim().email("Enter a valid owner email").max(255),
  password: z.string().min(8, "At least 8 characters").max(100),
  ownerIsSuperintendent: z.boolean(),
  superintendentName: z.string(),
  superintendentPhone: z.string(),
  superintendentEmail: z.string(),
});

export type SignupForm = z.infer<typeof baseSchema>;

export function getSignupSchema(role: SignupRole) {
  return baseSchema.superRefine((form, ctx) => {
    // Only validate separate superintendent details when they will be submitted.
    if (role !== "pharmacy" || form.ownerIsSuperintendent) return;
    const details = z
      .object({
        superintendentName: z
          .string()
          .trim()
          .min(2, "Superintendent pharmacist name is required")
          .max(100),
        superintendentPhone: z
          .string()
          .trim()
          .refine(isValidGhanaPhone, "Superintendent phone: enter one valid Ghana phone number"),
        superintendentEmail: z
          .string()
          .trim()
          .email("Enter a valid superintendent pharmacist email address")
          .max(255),
      })
      .safeParse(form);
    if (!details.success) {
      for (const issue of details.error.issues) ctx.addIssue(issue);
    }
  });
}
