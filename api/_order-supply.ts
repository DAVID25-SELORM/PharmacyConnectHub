// What a receipt shows for an order whose supply was reduced by an accepted proposal: the quantities actually supplied and the
// effective total, never the quantities first ordered. An order that was never amended is described exactly as before.

export type ReceiptSupply = {
  effective_total_ghs: number | string;
  delivery_fee_ghs: number | string | null;
  lines: Array<{ order_item_id: string; product_name: string; supplied_qty: number }>;
} | null;

type OrderForReceipt = {
  total_ghs: number | string;
  subtotal_ghs: number | string | null;
  discount_amount_ghs: number | string | null;
  order_items: Array<{
    id?: string;
    product_name: string;
    quantity: number;
    unit_price_ghs: number | string;
  }>;
};

export type ReceiptFigures = {
  totalGhs: number;
  deliveryFeeGhs: number;
  items: Array<{ productName: string; quantity: number; unitPriceGhs: number }>;
};

const money = (value: number) => Math.round(value * 100) / 100;

/** The total, delivery fee and lines for the receipt. `supply` is null for an order that was never amended. */
export function receiptFigures(order: OrderForReceipt, supply: ReceiptSupply): ReceiptFigures {
  const placedTotal = Number(order.total_ghs);
  // The delivery fee is whatever the placed total holds beyond the goods; an amendment never changes it.
  const placedFee = Math.max(
    0,
    money(
      placedTotal -
        (Number(order.subtotal_ghs ?? order.total_ghs) - Number(order.discount_amount_ghs ?? 0)),
    ),
  );
  if (!supply) {
    return {
      totalGhs: placedTotal,
      deliveryFeeGhs: placedFee,
      items: order.order_items.map((item) => ({
        productName: item.product_name,
        quantity: item.quantity,
        unitPriceGhs: Number(item.unit_price_ghs),
      })),
    };
  }
  const supplied = new Map(supply.lines.map((line) => [line.order_item_id, line.supplied_qty]));
  const fee =
    supply.delivery_fee_ghs === null || supply.delivery_fee_ghs === undefined
      ? placedFee
      : money(Number(supply.delivery_fee_ghs));
  return {
    totalGhs: Number(supply.effective_total_ghs),
    deliveryFeeGhs: fee,
    items: order.order_items
      .map((item) => ({
        productName: item.product_name,
        quantity:
          item.id && supplied.has(item.id) ? (supplied.get(item.id) as number) : item.quantity,
        unitPriceGhs: Number(item.unit_price_ghs),
      }))
      .filter((item) => item.quantity > 0),
  };
}
