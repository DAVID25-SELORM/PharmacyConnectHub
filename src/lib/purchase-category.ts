/**
 * Purchase classification for pharmacy checkout (NHIS / Cash-Private / Other), plus the derived
 * "Mixed" value the server computes when an order or procurement spans more than one category.
 * Mirrors the values enforced by the purchase_category CHECK constraints added in
 * 20260928100000_purchase_classification_and_procurements.sql.
 */

/** What a pharmacy can pick for a single line item. Never "mixed" - that only exists at the
 * order/procurement level, derived from a set of item-level categories that disagree. */
export type ItemPurchaseCategory = "nhis" | "cash_private" | "other";

/** What an order or procurement can end up as: any item-level value, "mixed" (derived), or null
 * (unclassified - historical orders, or a checkout that didn't use classification at all). */
export type PurchaseCategory = ItemPurchaseCategory | "mixed";

/** The whole-purchase choice offered at the top of checkout. "mixed" reveals per-item selectors;
 * the other three are applied to every line in the cart without asking again per item. */
export type PurchaseCategoryChoice = ItemPurchaseCategory | "mixed";

export const ITEM_PURCHASE_CATEGORIES: ItemPurchaseCategory[] = ["nhis", "cash_private", "other"];

export const purchaseCategoryLabels: Record<PurchaseCategory, string> = {
  nhis: "NHIS",
  cash_private: "Cash / Private",
  mixed: "Mixed",
  other: "Other",
};

export const purchaseCategoryChoiceDescriptions: Record<PurchaseCategoryChoice, string> = {
  nhis: "Every item in this purchase is for NHIS.",
  cash_private: "Every item in this purchase is cash / private.",
  other: "Every item in this purchase is another category.",
  mixed: "This purchase has a mix - classify each item below.",
};

/**
 * Resolve the category to submit for one cart line, given the whole-purchase choice and (for
 * "mixed" only) the per-item selections made so far. Returns undefined when nothing has been
 * chosen yet (no whole-purchase choice made) or the mixed selector for this item is still empty -
 * both cases the caller should treat as "not yet classified", never silently default to a value.
 */
export function resolveItemCategory(
  choice: PurchaseCategoryChoice | "",
  itemCategories: Record<string, ItemPurchaseCategory | undefined>,
  productId: string,
): ItemPurchaseCategory | undefined {
  if (!choice) return undefined;
  if (choice === "mixed") return itemCategories[productId];
  return choice;
}

/** True once every product id in the cart has a resolved category, for the current choice. */
export function allItemsClassified(
  choice: PurchaseCategoryChoice | "",
  itemCategories: Record<string, ItemPurchaseCategory | undefined>,
  productIds: string[],
): boolean {
  if (!choice) return true; // classification is optional; nothing to validate if it's skipped entirely
  return productIds.every((id) => Boolean(resolveItemCategory(choice, itemCategories, id)));
}

export function purchaseCategoryBadgeClass(category: PurchaseCategory | null | undefined): string {
  switch (category) {
    case "nhis":
      return "bg-blue-100 text-blue-800";
    case "cash_private":
      return "bg-green-100 text-green-800";
    case "mixed":
      return "bg-amber-100 text-amber-800";
    case "other":
      return "bg-gray-100 text-gray-800";
    default:
      return "bg-gray-100 text-gray-500";
  }
}

export function purchaseCategoryLabel(category: PurchaseCategory | null | undefined): string {
  return category ? purchaseCategoryLabels[category] : "Not classified";
}
