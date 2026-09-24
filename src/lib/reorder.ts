// Pure logic for supplier comparison and reordering. No network, no React: everything here is
// unit-tested. Displayed prices are a convenience; checkout re-prices and re-validates
// everything on the server, so nothing computed here is authoritative.

export type Offer = {
  id: string;
  wholesaler_id: string;
  price_ghs: number | string;
  stock: number;
  minimum_order_quantity?: number | null;
  lead_time_days?: number | null;
  wholesaler?: { name: string } | null;
};

export type Discount = {
  discount_type: string;
  discount_percent?: number;
  discount_amount?: number;
  minimum_order_value: number;
};

export type DiscountMap = Record<string, Discount>;

/** True when the customer's discount applies to any order size (no minimum order value). */
export function discountApplies(discount: Discount | undefined): boolean {
  return Boolean(discount) && Number(discount!.minimum_order_value) <= 0;
}

/** Net unit price after the pharmacy's customer discount with that wholesaler, if unconditional. */
export function netPrice(offer: Pick<Offer, "price_ghs">, discount: Discount | undefined): number {
  const list = Number(offer.price_ghs);
  if (!discount || !discountApplies(discount)) return list;
  if (discount.discount_type === "percentage" && discount.discount_percent) {
    return Math.max(
      0,
      Math.round(list * (1 - Number(discount.discount_percent) / 100) * 100) / 100,
    );
  }
  return Math.max(0, list - Number(discount.discount_amount ?? 0));
}

export function minimumQuantity(offer: Pick<Offer, "minimum_order_quantity">): number {
  return Math.max(1, Number(offer.minimum_order_quantity ?? 1));
}

/** Highlights for the comparison table. Only in-stock offers can be "best". */
export function comparisonHighlights(offers: Offer[], discounts: DiscountMap) {
  const inStock = offers.filter((offer) => offer.stock > 0);
  let cheapest: Offer | null = null;
  let fastest: Offer | null = null;

  for (const offer of inStock) {
    const price = netPrice(offer, discounts[offer.wholesaler_id]);
    if (!cheapest || price < netPrice(cheapest, discounts[cheapest.wholesaler_id]))
      cheapest = offer;
    const lead = offer.lead_time_days;
    if (lead !== null && lead !== undefined) {
      if (!fastest || lead < (fastest.lead_time_days ?? Infinity)) fastest = offer;
    }
  }

  // "Fastest" is only meaningful when suppliers actually differ.
  const leads = new Set(inStock.map((offer) => offer.lead_time_days ?? null));
  return {
    cheapestId: cheapest?.id ?? null,
    fastestId: fastest && leads.size > 1 ? fastest.id : null,
  };
}

export type CompareSort = "net-price" | "fastest" | "supplier";

export function sortOffers(offers: Offer[], discounts: DiscountMap, sort: CompareSort): Offer[] {
  const price = (offer: Offer) => netPrice(offer, discounts[offer.wholesaler_id]);
  const name = (offer: Offer) => offer.wholesaler?.name ?? "";
  return [...offers].sort((a, b) => {
    // Out-of-stock offers always sink to the bottom.
    if (a.stock > 0 !== b.stock > 0) return a.stock > 0 ? -1 : 1;
    if (sort === "supplier") return name(a).localeCompare(name(b));
    if (sort === "fastest") {
      const diff = (a.lead_time_days ?? Infinity) - (b.lead_time_days ?? Infinity);
      if (diff !== 0 && !Number.isNaN(diff)) return diff;
    }
    return price(a) - price(b) || name(a).localeCompare(name(b));
  });
}

// ---------------------------------------------------------------------------
// Resolving a wanted line against today's catalogue
// ---------------------------------------------------------------------------

export type WantedLine = {
  masterProductId: string | null;
  name: string;
  quantity: number;
  preferredWholesalerId?: string | null;
};

export type ResolvedLine = {
  wanted: WantedLine;
  status: "ready" | "adjusted" | "unavailable";
  offer: Offer | null;
  quantity: number;
  note: string | null;
  switchedSupplier: boolean;
  unitPrice: number | null;
};

/**
 * Picks the offer to buy today: the preferred supplier if it can supply, otherwise the best net
 * price among suppliers with stock. Quantity is raised to the supplier's minimum order quantity
 * and capped at its stock; a line that cannot be supplied at all is "unavailable" (never silently
 * dropped, never silently changed).
 */
export function resolveLine(
  wanted: WantedLine,
  offersByMaster: Map<string, Offer[]>,
  discounts: DiscountMap,
): ResolvedLine {
  const unavailable = (note: string): ResolvedLine => ({
    wanted,
    status: "unavailable",
    offer: null,
    quantity: 0,
    note,
    switchedSupplier: false,
    unitPrice: null,
  });

  const offers = wanted.masterProductId ? (offersByMaster.get(wanted.masterProductId) ?? []) : [];
  if (offers.length === 0) return unavailable("No longer listed by any supplier.");

  const supplied = offers.filter(
    (offer) => offer.stock > 0 && offer.stock >= minimumQuantity(offer),
  );
  if (supplied.length === 0) {
    const anyStock = offers.some((offer) => offer.stock > 0);
    return unavailable(
      anyStock
        ? "Available stock is below the suppliers' minimum order."
        : "Out of stock at every supplier.",
    );
  }

  const preferred = wanted.preferredWholesalerId
    ? supplied.find((offer) => offer.wholesaler_id === wanted.preferredWholesalerId)
    : undefined;
  const chosen =
    preferred ??
    [...supplied].sort(
      (a, b) =>
        netPrice(a, discounts[a.wholesaler_id]) - netPrice(b, discounts[b.wholesaler_id]) ||
        (a.wholesaler?.name ?? "").localeCompare(b.wholesaler?.name ?? ""),
    )[0];

  const switchedSupplier = Boolean(wanted.preferredWholesalerId) && !preferred;
  const notes: string[] = [];
  if (switchedSupplier) {
    notes.push(
      `Usual supplier can't supply now; using ${chosen.wholesaler?.name ?? "another supplier"}.`,
    );
  }

  let quantity = Math.max(1, Math.floor(wanted.quantity));
  const minimum = minimumQuantity(chosen);
  if (quantity < minimum) {
    quantity = minimum;
    notes.push(`Raised to the minimum order of ${minimum}.`);
  }
  if (quantity > chosen.stock) {
    quantity = chosen.stock;
    notes.push(`Only ${chosen.stock} in stock.`);
  }

  return {
    wanted,
    status: notes.length > 0 ? "adjusted" : "ready",
    offer: chosen,
    quantity,
    note: notes.length > 0 ? notes.join(" ") : null,
    switchedSupplier,
    unitPrice: netPrice(chosen, discounts[chosen.wholesaler_id]),
  };
}

export function summarizeResolved(lines: ResolvedLine[]) {
  const available = lines.filter((line) => line.status !== "unavailable");
  return {
    total: lines.length,
    available: available.length,
    unavailable: lines.length - available.length,
    adjusted: lines.filter((line) => line.status === "adjusted").length,
    estimatedTotal:
      Math.round(
        available.reduce((sum, line) => sum + (line.unitPrice ?? 0) * line.quantity, 0) * 100,
      ) / 100,
  };
}

/** Index offers by master product for resolveLine. */
export function groupOffersByMaster<T extends Offer & { master_product_id: string }>(offers: T[]) {
  const map = new Map<string, T[]>();
  for (const offer of offers) {
    const list = map.get(offer.master_product_id) ?? [];
    list.push(offer);
    map.set(offer.master_product_id, list);
  }
  return map as unknown as Map<string, Offer[]>;
}

/** Add lines into cart quantities without exceeding stock. Returns the new cart and how many lines were added. */
export function mergeIntoCart(
  cart: Array<{ productId: string; quantity: number }>,
  lines: Array<{ productId: string; quantity: number; stock: number }>,
) {
  const next = cart.map((item) => ({ ...item }));
  let added = 0;
  for (const line of lines) {
    const existing = next.find((item) => item.productId === line.productId);
    const desired = (existing?.quantity ?? 0) + line.quantity;
    const quantity = Math.min(desired, line.stock);
    if (quantity <= 0) continue;
    if (existing) existing.quantity = quantity;
    else next.push({ productId: line.productId, quantity });
    added += 1;
  }
  return { cart: next, added };
}

/** The offer shape the pharmacy catalogue loads (structurally compatible with pharmacy.tsx Product). */
export type CatalogueOffer = Offer & {
  master_product_id: string;
  name: string;
  form: string | null;
  pack_size: string | null;
};
