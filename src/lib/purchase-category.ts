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
  // Stored as "cash_private" (six report functions and all history use that key); shown as "Cash".
  cash_private: "Cash",
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

/** The two classifications offered on a new order. "other" stays valid in the database (and on
 * history) but is not offered at checkout. */
export const CHECKOUT_CATEGORIES: ItemPurchaseCategory[] = ["nhis", "cash_private"];

export type ClassificationLine = {
  id: string;
  /** Estimated line value after discounts (the database computes the authoritative figure). */
  amount: number;
  category: ItemPurchaseCategory | undefined;
};

export type ClassificationSummary = {
  byCategory: Record<ItemPurchaseCategory, { lines: number; amount: number }>;
  unclassified: { lines: number; amount: number; ids: string[] };
  total: number;
  /** "NHIS Order" / "Cash Order" / "Other Order" / "Mixed Purchase", derived from the lines;
   * null while any line is still unclassified (or the cart is empty). */
  label: string | null;
};

const roundMoney = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;

/**
 * Checkout summary, derived entirely from the lines: spend and line count per classification, which
 * lines still need one, and the order label. Nothing here is stored or editable -- the server
 * derives the real order category from the lines it saves.
 */
export function summarizeClassification(lines: ClassificationLine[]): ClassificationSummary {
  const byCategory: ClassificationSummary["byCategory"] = {
    nhis: { lines: 0, amount: 0 },
    cash_private: { lines: 0, amount: 0 },
    other: { lines: 0, amount: 0 },
  };
  const unclassified: ClassificationSummary["unclassified"] = { lines: 0, amount: 0, ids: [] };
  for (const line of lines) {
    if (line.category) {
      byCategory[line.category].lines += 1;
      byCategory[line.category].amount += line.amount;
    } else {
      unclassified.lines += 1;
      unclassified.amount += line.amount;
      unclassified.ids.push(line.id);
    }
  }
  for (const key of ITEM_PURCHASE_CATEGORIES)
    byCategory[key].amount = roundMoney(byCategory[key].amount);
  unclassified.amount = roundMoney(unclassified.amount);
  const total = roundMoney(
    ITEM_PURCHASE_CATEGORIES.reduce((sum, key) => sum + byCategory[key].amount, 0) +
      unclassified.amount,
  );

  const used = ITEM_PURCHASE_CATEGORIES.filter((key) => byCategory[key].lines > 0);
  let label: string | null = null;
  if (lines.length > 0 && unclassified.lines === 0) {
    label = used.length > 1 ? "Mixed Purchase" : `${purchaseCategoryLabels[used[0]]} Order`;
  }
  return { byCategory, unclassified, total, label };
}

/** "3 items still need a purchase classification." (and the singular form). */
export function unclassifiedMessage(count: number): string {
  return count === 1
    ? "1 item still needs a purchase classification."
    : `${count} items still need a purchase classification.`;
}
