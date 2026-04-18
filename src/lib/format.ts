export function formatGHS(amount: number | string): string {
  const n = typeof amount === "string" ? Number(amount) : amount;
  return `GH₵ ${(isFinite(n) ? n : 0).toFixed(2)}`;
}

export function timeAgo(iso: string): string {
  const d = new Date(iso).getTime();
  const diff = Math.max(0, Date.now() - d);
  const m = Math.floor(diff / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const days = Math.floor(h / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString();
}

export const GH_REGIONS = [
  "Greater Accra",
  "Ashanti",
  "Western",
  "Central",
  "Eastern",
  "Volta",
  "Northern",
  "Upper East",
  "Upper West",
  "Bono",
  "Bono East",
  "Ahafo",
  "Western North",
  "Oti",
  "Savannah",
  "North East",
];

export const PRODUCT_CATEGORIES = [
  "Analgesics & Pain Relief",
  "Antibiotics",
  "Antidiabetics",
  "Antifungals",
  "Antihistamines & Allergy",
  "Antihypertensives",
  "Anti-inflammatory",
  "Antimalarials",
  "Antiparasitics",
  "Antivirals",
  "Antacids & Digestive",
  "Cardiovascular",
  "Contraceptives & Family Planning",
  "Cough, Cold & Flu",
  "Dermatology & Skin Care",
  "Eye & Ear Care",
  "Gastrointestinal",
  "Herbal & Traditional Medicine",
  "Injectable Medications",
  "IV Fluids & Solutions",
  "Medical Devices & Supplies",
  "Men's Health",
  "Nutritional Supplements",
  "Pediatrics & Child Care",
  "Respiratory",
  "Vitamins & Minerals",
  "Women's Health",
  "Wound Care & Dressings",
  "Antiseptics & Disinfectants",
  "Other",
];
