// Pharmacy-owned inventory: shared types for the list/add/adjust/edit/import UI.

export type PharmacyInventoryItem = {
  id: string;
  pharmacy_id: string;
  name: string;
  brand: string | null;
  category: string | null;
  form: string | null;
  pack_size: string | null;
  stock: number;
  reorder_level: number | null;
  unit_cost_ghs: number | null;
  active: boolean;
  created_at: string;
  updated_at: string;
};

export type PharmacyInventoryMovementKind = "receive" | "adjust" | "write_off" | "import";
export type PharmacyInventoryMovementReason = "damaged" | "expired" | "count_correction" | "other";

export type PharmacyInventoryMovement = {
  id: string;
  item_id: string;
  pharmacy_id: string;
  kind: PharmacyInventoryMovementKind;
  quantity_delta: number;
  stock_after: number;
  reason: PharmacyInventoryMovementReason | null;
  note: string | null;
  created_at: string;
};

export const MOVEMENT_REASON_LABELS: Record<PharmacyInventoryMovementReason, string> = {
  damaged: "Damaged",
  expired: "Expired",
  count_correction: "Count correction",
  other: "Other",
};

export function isLowStock(item: Pick<PharmacyInventoryItem, "stock" | "reorder_level">) {
  return item.reorder_level !== null && item.stock <= item.reorder_level;
}

/** Validates the add-item / edit-details form before submitting. */
export function validateInventoryItemDraft(input: {
  name: string;
  stock?: string;
  reorderLevel: string;
  unitCostGhs: string;
}) {
  if (!input.name.trim()) {
    return { error: "Enter a name." };
  }
  if (input.stock !== undefined) {
    const stock = Number(input.stock);
    if (!Number.isFinite(stock) || stock < 0 || !Number.isInteger(stock)) {
      return { error: "Enter a starting stock of zero or more." };
    }
  }
  if (input.reorderLevel.trim()) {
    const level = Number(input.reorderLevel);
    if (!Number.isFinite(level) || level < 0 || !Number.isInteger(level)) {
      return { error: "Reorder level must be a whole number of zero or more." };
    }
  }
  if (input.unitCostGhs.trim()) {
    const cost = Number(input.unitCostGhs);
    if (!Number.isFinite(cost) || cost < 0) {
      return { error: "Unit cost must be zero or more." };
    }
  }
  return { error: null };
}

/** Validates the receive/adjust/write-off stock form before submitting. The "receive" and
 * "write_off" quantity fields are always entered as a positive magnitude ("units to remove" /
 * "quantity received"); only "adjust" (a free-form count correction) accepts a signed value. */
export function validateStockAdjustment(input: {
  quantity: string;
  kind: "receive" | "adjust" | "write_off";
}) {
  const quantity = Number(input.quantity);
  if (!Number.isFinite(quantity) || quantity === 0 || !Number.isInteger(quantity)) {
    return { error: "Enter a non-zero whole number." };
  }
  if (input.kind !== "adjust" && quantity < 0) {
    return { error: "Enter a positive quantity." };
  }
  const delta = input.kind === "write_off" ? -Math.abs(quantity) : quantity;
  return { error: null, delta };
}
