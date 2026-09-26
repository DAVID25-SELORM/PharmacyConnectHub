import { useMemo, useState } from "react";
import { Plus } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatGHS } from "@/lib/format";
import { describeTerms, type OrderTerms } from "@/lib/order-terms";
import {
  comparisonHighlights,
  discountApplies,
  minimumQuantity,
  netPrice,
  sortOffers,
  type CatalogueOffer,
  type CompareSort,
  type DiscountMap,
} from "@/lib/reorder";

function leadTimeLabel(days: number | null | undefined) {
  if (days === null || days === undefined) return "Not stated";
  if (days === 0) return "Same day";
  return days === 1 ? "1 day" : `${days} days`;
}

/** Side-by-side supplier comparison for one medicine: list price, discount, net price, minimum order, lead time, stock. */
export function SupplierComparison({
  offers,
  discounts,
  canOrder,
  addToCart,
  terms,
}: {
  offers: CatalogueOffer[];
  discounts: DiscountMap;
  canOrder: boolean;
  addToCart: (offerId: string) => void;
  terms?: Record<string, OrderTerms>;
}) {
  const [sort, setSort] = useState<CompareSort>("net-price");
  const highlights = useMemo(() => comparisonHighlights(offers, discounts), [offers, discounts]);
  const sorted = useMemo(() => sortOffers(offers, discounts, sort), [offers, discounts, sort]);

  return (
    <div className="mt-3">
      <div className="mb-2 flex items-center gap-2 text-sm">
        <label htmlFor={`sort-${offers[0]?.master_product_id}`} className="text-muted-foreground">
          Sort by
        </label>
        <select
          id={`sort-${offers[0]?.master_product_id}`}
          className="h-8 rounded-md border border-input bg-background px-2 text-sm"
          value={sort}
          onChange={(event) => setSort(event.target.value as CompareSort)}
        >
          <option value="net-price">Best net price</option>
          <option value="fastest">Fastest delivery</option>
          <option value="supplier">Supplier name</option>
        </select>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full min-w-[640px] text-left text-sm">
          <thead className="text-xs uppercase tracking-wider text-muted-foreground">
            <tr>
              <th scope="col" className="p-2">
                Supplier
              </th>
              <th scope="col" className="p-2 text-right">
                List price
              </th>
              <th scope="col" className="p-2 text-right">
                Your price
              </th>
              <th scope="col" className="p-2 text-right">
                Min. order
              </th>
              <th scope="col" className="p-2">
                Lead time
              </th>
              <th scope="col" className="p-2">
                Availability
              </th>
              <th scope="col" className="p-2">
                <span className="sr-only">Order</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {sorted.map((offer) => {
              const discount = discounts[offer.wholesaler_id];
              const net = netPrice(offer, discount);
              const list = Number(offer.price_ghs);
              const inStock = offer.stock > 0;
              return (
                <tr key={offer.id} className="border-t align-top">
                  <td className="p-2">
                    <div className="font-medium">{offer.wholesaler?.name}</div>
                    {describeTerms(terms?.[offer.wholesaler_id]) && (
                      <div className="text-xs text-muted-foreground">
                        {describeTerms(terms?.[offer.wholesaler_id])}
                      </div>
                    )}
                    <div className="mt-1 flex flex-wrap gap-1">
                      {offer.id === highlights.cheapestId && (
                        <Badge variant="secondary">Best price</Badge>
                      )}
                      {offer.id === highlights.fastestId && (
                        <Badge variant="secondary">Fastest</Badge>
                      )}
                    </div>
                  </td>
                  <td className="p-2 text-right tabular-nums">{formatGHS(list)}</td>
                  <td className="p-2 text-right tabular-nums">
                    <div className="font-semibold">{formatGHS(net)}</div>
                    {discountApplies(discount) && net < list && (
                      <div className="text-xs font-normal text-success">
                        Your discount: −{formatGHS(list - net)}
                      </div>
                    )}
                    {discount && !discountApplies(discount) && (
                      <div className="text-xs font-normal text-muted-foreground">
                        Discount on orders of {formatGHS(discount.minimum_order_value)}+
                      </div>
                    )}
                  </td>
                  <td className="p-2 text-right tabular-nums">{minimumQuantity(offer)}</td>
                  <td className="p-2">{leadTimeLabel(offer.lead_time_days)}</td>
                  <td className="p-2">{inStock ? `${offer.stock} in stock` : "Out of stock"}</td>
                  <td className="p-2 text-right">
                    <Button
                      size="sm"
                      variant="hero"
                      onClick={() => addToCart(offer.id)}
                      disabled={!canOrder || !inStock}
                    >
                      <Plus className="h-4 w-4" aria-hidden="true" />
                      Add
                    </Button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Prices shown are guides; the final price and any discount are confirmed when you place the
        order.
      </p>
    </div>
  );
}
