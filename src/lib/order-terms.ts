import type { Discount } from "@/lib/reorder";

export type OrderTerms = {
  wholesaler_id: string;
  min_order_value_ghs: number;
  delivery_fee_ghs: number;
  free_delivery_threshold_ghs: number | null;
};

export type CartGroupLine = { price_ghs: number | string; quantity: number };

export type GroupEstimate = {
  gross: number;
  discount: number;
  goods: number;
  deliveryFee: number;
  total: number;
  /** How much more goods value is needed to reach the minimum order (0 when met). */
  shortfall: number;
  /** How much more goods value earns free delivery (null when no fee or no threshold). */
  freeDeliveryRemaining: number | null;
  minimumMet: boolean;
};

const cents = (value: number) => Math.round(value * 100) / 100;

/**
 * Estimated totals for one wholesaler's part of the cart. It follows the checkout rules the server
 * applies: the customer discount is worked out on the gross value (only when the gross reaches the
 * discount's own minimum), the minimum order and free-delivery amount are measured on the goods
 * total AFTER the discount. The server recalculates everything at checkout.
 */
export function estimateGroup(
  lines: CartGroupLine[],
  discount: Discount | undefined,
  terms: OrderTerms | undefined,
): GroupEstimate {
  const gross = cents(lines.reduce((sum, line) => sum + Number(line.price_ghs) * line.quantity, 0));

  let discountAmount = 0;
  if (discount && gross >= Number(discount.minimum_order_value ?? 0)) {
    if (discount.discount_type === "percentage" && discount.discount_percent) {
      discountAmount = lines.reduce((sum, line) => {
        const unit = Number(line.price_ghs);
        const net = cents(unit * (1 - Number(discount.discount_percent) / 100));
        return sum + cents((unit - net) * line.quantity);
      }, 0);
    } else if (discount.discount_amount) {
      discountAmount = Math.min(Number(discount.discount_amount), gross);
    }
  }
  discountAmount = cents(discountAmount);

  const goods = cents(gross - discountAmount);
  const minimum = Number(terms?.min_order_value_ghs ?? 0);
  const fee = Number(terms?.delivery_fee_ghs ?? 0);
  const freeFrom = terms?.free_delivery_threshold_ghs ?? null;

  const feeWaived = freeFrom !== null && goods >= Number(freeFrom);
  const deliveryFee = fee > 0 && !feeWaived ? cents(fee) : 0;

  return {
    gross,
    discount: discountAmount,
    goods,
    deliveryFee,
    total: cents(goods + deliveryFee),
    shortfall: minimum > goods ? cents(minimum - goods) : 0,
    freeDeliveryRemaining:
      fee > 0 && freeFrom !== null && !feeWaived ? cents(Number(freeFrom) - goods) : null,
    minimumMet: minimum <= goods,
  };
}

const money = (value: number) =>
  `GHS ${Number(value).toLocaleString("en-GH", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** One short line describing a wholesaler's terms, or null when they have none. */
export function describeTerms(terms: OrderTerms | undefined): string | null {
  if (!terms) return null;
  const parts: string[] = [];
  if (Number(terms.min_order_value_ghs) > 0)
    parts.push(`Min. order ${money(terms.min_order_value_ghs)}`);
  if (Number(terms.delivery_fee_ghs) > 0) {
    parts.push(
      terms.free_delivery_threshold_ghs !== null
        ? `Delivery ${money(terms.delivery_fee_ghs)}, free from ${money(terms.free_delivery_threshold_ghs)}`
        : `Delivery ${money(terms.delivery_fee_ghs)}`,
    );
  }
  return parts.length > 0 ? parts.join(" · ") : null;
}

/** Validates the wholesaler's terms form. The database repeats every check. */
export function validateTermsForm(input: { min: string; fee: string; freeFrom: string }) {
  const min = input.min.trim() === "" ? 0 : Number(input.min);
  const fee = input.fee.trim() === "" ? 0 : Number(input.fee);
  const freeFrom = input.freeFrom.trim() === "" ? null : Number(input.freeFrom);
  if (!Number.isFinite(min) || min < 0 || min > 1_000_000)
    return { error: "The minimum order must be between 0 and 1,000,000." };
  if (!Number.isFinite(fee) || fee < 0 || fee > 10_000)
    return { error: "The delivery fee must be between 0 and 10,000." };
  if (freeFrom !== null) {
    if (!Number.isFinite(freeFrom) || freeFrom <= 0)
      return { error: "The free-delivery amount must be above zero." };
    if (fee === 0) return { error: "Set a delivery fee before setting a free-delivery amount." };
    if (freeFrom < min)
      return { error: "The free-delivery amount cannot be lower than the minimum order." };
  }
  return { error: null, min, fee, freeFrom };
}
