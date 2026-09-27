import { netPrice, type Discount, type Offer } from "@/lib/reorder";

export type ProductRule = {
  product_id: string;
  wholesaler_id: string;
  discount_percent: number;
  min_quantity: number;
  ends_at?: string | null;
};

const cents = (value: number) => Math.round(value * 100) / 100;

/** The rule that applies to a line: highest percentage, then highest minimum quantity, among those the quantity reaches. */
export function bestRule(rules: ProductRule[] | undefined, productId: string, quantity: number) {
  let best: ProductRule | undefined;
  for (const rule of rules ?? []) {
    if (rule.product_id !== productId || quantity < rule.min_quantity) continue;
    if (
      !best ||
      Number(rule.discount_percent) > Number(best.discount_percent) ||
      (Number(rule.discount_percent) === Number(best.discount_percent) &&
        rule.min_quantity > best.min_quantity)
    ) {
      best = rule;
    }
  }
  return best;
}

export function ruleUnitPrice(listPrice: number | string, rule: ProductRule) {
  return cents(Number(listPrice) * (1 - Number(rule.discount_percent) / 100));
}

/**
 * Unit price shown for an offer: a product-specific rule for that quantity replaces the general
 * customer discount; otherwise the general (unconditional) discount applies. Checkout recalculates.
 */
export function makePriceOf(discounts: Record<string, Discount>, rules: ProductRule[] | undefined) {
  return (offer: Pick<Offer, "id" | "price_ghs" | "wholesaler_id">, quantity = 1) => {
    const rule = bestRule(rules, offer.id, quantity);
    return rule
      ? ruleUnitPrice(offer.price_ghs, rule)
      : netPrice(offer, discounts[offer.wholesaler_id]);
  };
}

/** e.g. "15% off from 10 units" for the volume rules on a product, cheapest tier last. */
export function volumeTierTexts(rules: ProductRule[] | undefined, productId: string) {
  return (rules ?? [])
    .filter((rule) => rule.product_id === productId && rule.min_quantity > 1)
    .sort((a, b) => a.min_quantity - b.min_quantity)
    .map((rule) => `${Number(rule.discount_percent)}% off from ${rule.min_quantity} units`);
}
