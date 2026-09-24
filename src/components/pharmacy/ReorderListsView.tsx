import { useMemo, useState } from "react";
import { ChevronDown, ChevronRight, ShoppingCart, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import type { ReorderItem, ReorderList, ReorderListsApi } from "@/hooks/use-reorder-lists";
import { formatGHS } from "@/lib/format";
import {
  groupOffersByMaster,
  resolveLine,
  summarizeResolved,
  type CatalogueOffer,
  type DiscountMap,
  type ResolvedLine,
} from "@/lib/reorder";

export type CartLine = { productId: string; quantity: number };

function StatusChip({ line }: { line: ResolvedLine }) {
  if (line.status === "unavailable") return <Badge variant="destructive">Unavailable</Badge>;
  if (line.status === "adjusted") return <Badge variant="secondary">Adjusted</Badge>;
  return <Badge variant="outline">Ready</Badge>;
}

function ItemRow({
  item,
  line,
  supplierOptions,
  canEdit,
  api,
}: {
  item: ReorderItem;
  line: ResolvedLine;
  supplierOptions: Array<{ id: string; name: string }>;
  canEdit: boolean;
  api: ReorderListsApi;
}) {
  const [quantity, setQuantity] = useState(String(item.quantity));

  const commitQuantity = () => {
    const next = Math.floor(Number(quantity));
    if (!Number.isFinite(next) || next < 1 || next > 100000) {
      setQuantity(String(item.quantity));
      return toast.error("Enter a quantity between 1 and 100,000.");
    }
    if (next !== item.quantity) void api.updateItem(item.id, { quantity: next });
  };

  return (
    <li className="grid gap-2 border-t border-border py-3 sm:grid-cols-[1fr_auto] sm:items-start">
      <div>
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-medium">{item.name_snapshot || "Medicine"}</span>
          <StatusChip line={line} />
        </div>
        {line.status === "unavailable" ? (
          <p className="mt-1 text-sm text-muted-foreground">{line.note}</p>
        ) : (
          <p className="mt-1 text-sm text-muted-foreground">
            {line.offer?.wholesaler?.name} · {formatGHS(line.unitPrice ?? 0)} each
            {line.quantity > 0 &&
              ` · ${formatGHS((line.unitPrice ?? 0) * line.quantity)} for ${line.quantity}`}
            {line.note && <span className="block text-xs text-warning">{line.note}</span>}
          </p>
        )}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <label className="sr-only" htmlFor={`qty-${item.id}`}>
          Quantity for {item.name_snapshot}
        </label>
        <Input
          id={`qty-${item.id}`}
          type="number"
          min={1}
          max={100000}
          className="w-24"
          value={quantity}
          disabled={!canEdit}
          onChange={(event) => setQuantity(event.target.value)}
          onBlur={commitQuantity}
          onKeyDown={(event) => event.key === "Enter" && (event.target as HTMLInputElement).blur()}
        />
        <label className="sr-only" htmlFor={`sup-${item.id}`}>
          Preferred supplier for {item.name_snapshot}
        </label>
        <select
          id={`sup-${item.id}`}
          className="h-10 rounded-md border border-input bg-background px-2 text-sm"
          value={item.preferred_wholesaler_id ?? ""}
          disabled={!canEdit}
          onChange={(event) =>
            void api.updateItem(item.id, { preferred_wholesaler_id: event.target.value || null })
          }
        >
          <option value="">Best price</option>
          {supplierOptions.map((supplier) => (
            <option key={supplier.id} value={supplier.id}>
              {supplier.name}
            </option>
          ))}
        </select>
        {canEdit && (
          <Button
            variant="ghost"
            size="icon"
            aria-label={`Remove ${item.name_snapshot} from the list`}
            onClick={() => void api.removeItem(item.id)}
          >
            <Trash2 className="h-4 w-4" aria-hidden="true" />
          </Button>
        )}
      </div>
    </li>
  );
}

function ListCard({
  list,
  offersByMaster,
  discounts,
  canEdit,
  canOrder,
  api,
  onAddLines,
}: {
  list: ReorderList;
  offersByMaster: Map<string, CatalogueOffer[]>;
  discounts: DiscountMap;
  canEdit: boolean;
  canOrder: boolean;
  api: ReorderListsApi;
  onAddLines: (lines: Array<{ offer: CatalogueOffer; quantity: number }>) => number;
}) {
  const [open, setOpen] = useState(false);

  const resolved = useMemo(
    () =>
      list.items.map((item) =>
        resolveLine(
          {
            masterProductId: item.master_product_id,
            name: item.name_snapshot,
            quantity: item.quantity,
            preferredWholesalerId: item.preferred_wholesaler_id,
          },
          offersByMaster,
          discounts,
        ),
      ),
    [list.items, offersByMaster, discounts],
  );
  const summary = summarizeResolved(resolved);

  const addAvailable = () => {
    const lines = resolved
      .filter((line) => line.status !== "unavailable" && line.offer)
      .map((line) => ({ offer: line.offer as CatalogueOffer, quantity: line.quantity }));
    const added = onAddLines(lines);
    toast.success(
      summary.unavailable > 0
        ? `Added ${added} of ${summary.total} medicines to your cart. ${summary.unavailable} unavailable.`
        : `Added ${added} medicine${added === 1 ? "" : "s"} to your cart.`,
    );
  };

  const remove = () => {
    if (window.confirm(`Delete the list "${list.name}"? This cannot be undone.`))
      void api.deleteList(list.id);
  };

  return (
    <Card className="p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <button
          type="button"
          className="flex items-center gap-2 text-left font-display text-lg font-bold"
          aria-expanded={open}
          onClick={() => setOpen((value) => !value)}
        >
          {open ? (
            <ChevronDown className="h-4 w-4" aria-hidden="true" />
          ) : (
            <ChevronRight className="h-4 w-4" aria-hidden="true" />
          )}
          {list.name}
          <span className="text-sm font-normal text-muted-foreground">
            {list.items.length} medicine{list.items.length === 1 ? "" : "s"}
          </span>
        </button>
        <div className="flex items-center gap-2">
          {summary.total > 0 && (
            <span className="hidden text-sm text-muted-foreground sm:inline">
              {summary.available} of {summary.total} available · about{" "}
              {formatGHS(summary.estimatedTotal)}
            </span>
          )}
          <Button
            variant="hero"
            size="sm"
            disabled={!canOrder || summary.available === 0}
            onClick={addAvailable}
          >
            <ShoppingCart className="mr-1 h-4 w-4" aria-hidden="true" />
            Add available to cart
          </Button>
          {canEdit && (
            <Button
              variant="ghost"
              size="icon"
              aria-label={`Delete list ${list.name}`}
              onClick={remove}
            >
              <Trash2 className="h-4 w-4" aria-hidden="true" />
            </Button>
          )}
        </div>
      </div>

      {open &&
        (list.items.length === 0 ? (
          <p className="mt-3 text-sm text-muted-foreground">
            This list is empty. Use “Add to list” on any medicine in the Catalog.
          </p>
        ) : (
          <ul className="mt-3">
            {list.items.map((item, index) => (
              <ItemRow
                key={item.id}
                item={item}
                line={resolved[index]}
                canEdit={canEdit}
                api={api}
                supplierOptions={(offersByMaster.get(item.master_product_id) ?? []).map(
                  (offer) => ({
                    id: offer.wholesaler_id,
                    name: offer.wholesaler?.name ?? "Supplier",
                  }),
                )}
              />
            ))}
          </ul>
        ))}
    </Card>
  );
}

/** The "Reorder lists" tab. Every line is re-resolved against today's catalogue on every render. */
export function ReorderListsView({
  api,
  products,
  discounts,
  canEdit,
  canOrder,
  onAddLines,
}: {
  api: ReorderListsApi;
  products: Array<CatalogueOffer & { master_product_id: string }>;
  discounts: DiscountMap;
  canEdit: boolean;
  canOrder: boolean;
  onAddLines: (lines: Array<{ offer: CatalogueOffer; quantity: number }>) => number;
}) {
  const [name, setName] = useState("");
  const offersByMaster = useMemo(
    () => groupOffersByMaster(products) as unknown as Map<string, CatalogueOffer[]>,
    [products],
  );

  const create = async (event: React.FormEvent) => {
    event.preventDefault();
    if (await api.createList(name)) setName("");
  };

  return (
    <div className="space-y-4">
      <div>
        <h2 className="font-display text-xl font-bold">Reorder lists</h2>
        <p className="text-sm text-muted-foreground">
          Save the medicines you buy regularly, then add everything that&apos;s available to your
          cart in one step. Prices and stock are checked fresh every time.
        </p>
      </div>

      {canEdit && (
        <form onSubmit={create} className="flex max-w-md gap-2">
          <Input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="New list, e.g. Monthly restock"
            maxLength={60}
            aria-label="New list name"
          />
          <Button type="submit" disabled={name.trim().length === 0}>
            Create list
          </Button>
        </form>
      )}

      {api.loading ? (
        <div className="space-y-2" role="status" aria-label="Loading lists">
          <Skeleton className="h-16 w-full" />
          <Skeleton className="h-16 w-full" />
        </div>
      ) : api.error ? (
        <div role="alert" className="rounded-xl border border-dashed border-border p-8 text-center">
          <p className="text-sm font-medium">We couldn&apos;t load your reorder lists.</p>
          <Button className="mt-3" variant="outline" size="sm" onClick={() => void api.reload()}>
            Try again
          </Button>
        </div>
      ) : api.lists.length === 0 ? (
        <Card className="p-10 text-center text-muted-foreground">
          <p className="font-medium text-foreground">No reorder lists yet</p>
          <p className="mt-1 text-sm">
            Create a list above, then add medicines from the Catalog with “Add to list”.
          </p>
        </Card>
      ) : (
        api.lists.map((list) => (
          <ListCard
            key={list.id}
            list={list}
            offersByMaster={offersByMaster}
            discounts={discounts}
            canEdit={canEdit}
            canOrder={canOrder}
            api={api}
            onAddLines={onAddLines}
          />
        ))
      )}
    </div>
  );
}
