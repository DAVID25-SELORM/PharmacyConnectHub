// Pharmacy-owned inventory: shared types for the list/add/adjust/edit/import UI.

export type PharmacyItemType = "medicine" | "medical_consumable" | "medical_equipment" | "non_medical";

export const ITEM_TYPE_OPTIONS: Array<{ value: PharmacyItemType; label: string }> = [
  { value: "medicine", label: "Medicine" },
  { value: "medical_consumable", label: "Medical Consumable" },
  { value: "medical_equipment", label: "Medical Equipment" },
  { value: "non_medical", label: "Non-Medical Item" },
];

export const ITEM_TYPE_LABELS: Record<PharmacyItemType, string> = {
  medicine: "Medicine",
  medical_consumable: "Medical Consumable",
  medical_equipment: "Medical Equipment",
  non_medical: "Non-Medical Item",
};

/** Which optional fields apply to each item type, so the Add/Edit form can show only relevant
 * inputs and the list/import views can stay consistent with what was actually asked for. Fields
 * not listed here (name, category, stock, reorder_level, unit_cost_ghs, selling_price_ghs,
 * supplier, brand, active) apply to every type. */
export const ITEM_TYPE_FIELDS: Record<
  PharmacyItemType,
  { form: boolean; packSize: boolean; genericName: boolean; strength: boolean; manufacturer: boolean;
    barcode: boolean; batch: boolean; expiry: boolean; unitOfMeasure: boolean; model: boolean;
    serialNumber: boolean; warranty: boolean }
> = {
  medicine: {
    form: true, packSize: true, genericName: true, strength: true, manufacturer: true,
    barcode: true, batch: true, expiry: true, unitOfMeasure: false, model: false,
    serialNumber: false, warranty: false,
  },
  medical_consumable: {
    form: false, packSize: true, genericName: false, strength: false, manufacturer: false,
    barcode: true, batch: true, expiry: true, unitOfMeasure: true, model: false,
    serialNumber: false, warranty: false,
  },
  medical_equipment: {
    form: false, packSize: false, genericName: false, strength: false, manufacturer: false,
    barcode: false, batch: false, expiry: false, unitOfMeasure: false, model: true,
    serialNumber: true, warranty: true,
  },
  non_medical: {
    form: false, packSize: false, genericName: false, strength: false, manufacturer: false,
    barcode: true, batch: false, expiry: false, unitOfMeasure: true, model: false,
    serialNumber: false, warranty: false,
  },
};

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
  item_type: PharmacyItemType;
  generic_name: string | null;
  strength: string | null;
  manufacturer: string | null;
  barcode: string | null;
  batch_number: string | null;
  expiry_date: string | null;
  selling_price_ghs: number | null;
  supplier: string | null;
  unit_of_measure: string | null;
  model: string | null;
  serial_number: string | null;
  warranty_info: string | null;
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
  sellingPriceGhs?: string;
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
  if (input.sellingPriceGhs?.trim()) {
    const price = Number(input.sellingPriceGhs);
    if (!Number.isFinite(price) || price < 0) {
      return { error: "Selling price must be zero or more." };
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
