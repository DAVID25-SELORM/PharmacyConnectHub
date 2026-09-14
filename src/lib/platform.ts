export type PublicPlatformIdentity = {
  name: string;
  company: string;
  contactPerson: string;
  email: string;
  phone: string;
  address?: string;
  website?: string;
  socialLinks: Readonly<Record<string, string>>;
};

// Public information only. Optional details stay absent until supplied.
export const PLATFORM = {
  name: "DrugXone",
  company: "DAVENTRA Technologies",
  contactPerson: "David Selorm Gabion",
  email: "drugxone@gmail.com",
  phone: "0247654381",
  socialLinks: {},
} as const satisfies PublicPlatformIdentity;
