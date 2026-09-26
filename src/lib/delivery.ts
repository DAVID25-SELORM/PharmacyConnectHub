export type Delivery = {
  driver_name?: string | null;
  driver_phone?: string | null;
  delivery_reference?: string | null;
  expected_delivery_at?: string | null;
  received_by_name?: string | null;
  received_at?: string | null;
  delivery_note?: string | null;
};

/** Delivery details can be added until the order is delivered; proof once it is out for delivery. */
export function canRecordDispatch(status: string) {
  return status === "accepted" || status === "packed" || status === "dispatched";
}

export function canRecordProof(status: string) {
  return status === "dispatched" || status === "delivered";
}

export function hasDispatchDetails(delivery: Delivery | null | undefined) {
  return Boolean(
    delivery?.driver_name ||
    delivery?.driver_phone ||
    delivery?.delivery_reference ||
    delivery?.expected_delivery_at,
  );
}

export function hasProof(delivery: Delivery | null | undefined) {
  return Boolean(delivery?.received_by_name && delivery?.received_at);
}

/** ISO timestamp -> value for <input type="datetime-local"> in the viewer's own timezone. */
export function toDateTimeLocal(iso: string | null | undefined) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 16);
}
