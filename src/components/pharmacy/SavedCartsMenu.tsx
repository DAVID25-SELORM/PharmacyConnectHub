import { useState } from "react";
import { FolderOpen, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import type { SavedCartsApi } from "@/hooks/use-saved-carts";

/** Save the current cart under a name, or resume/delete a previously saved one. */
export function SavedCartsMenu({
  savedCarts,
  cartItems,
  canSave,
  onResume,
}: {
  savedCarts: SavedCartsApi;
  cartItems: Array<{ productId: string; quantity: number; name: string }>;
  canSave: boolean;
  onResume: (items: Array<{ productId: string; quantity: number }>, label: string) => void;
}) {
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);

  const save = async () => {
    if (cartItems.length === 0) return toast.error("Your cart is empty.");
    setSaving(true);
    const ok = await savedCarts.createFromCart(name, cartItems);
    setSaving(false);
    if (ok) {
      toast.success(`Saved "${name.trim()}".`);
      setName("");
    }
  };

  const resume = (cart: (typeof savedCarts.carts)[number]) => {
    onResume(
      cart.items.map((item) => ({ productId: item.product_id, quantity: item.quantity })),
      cart.name,
    );
  };

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="outline" size="sm">
          <FolderOpen className="mr-1 h-4 w-4" aria-hidden="true" />
          Saved carts
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-72">
        <DropdownMenuLabel>Your saved carts</DropdownMenuLabel>
        {savedCarts.loading ? (
          <div className="px-2 py-1.5 text-sm text-muted-foreground">Loading...</div>
        ) : savedCarts.carts.length === 0 ? (
          <div className="px-2 py-1.5 text-sm text-muted-foreground">No saved carts yet.</div>
        ) : (
          savedCarts.carts.map((cart) => (
            <DropdownMenuItem
              key={cart.id}
              onSelect={(event) => {
                event.preventDefault();
                resume(cart);
              }}
            >
              <span className="flex-1 truncate">{cart.name}</span>
              <span className="mr-2 text-xs text-muted-foreground">{cart.items.length}</span>
              <button
                type="button"
                aria-label={`Delete saved cart ${cart.name}`}
                className="text-muted-foreground hover:text-destructive"
                onClick={(event) => {
                  event.stopPropagation();
                  void savedCarts.deleteCart(cart.id);
                }}
              >
                <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
              </button>
            </DropdownMenuItem>
          ))
        )}
        {canSave && (
          <>
            <DropdownMenuSeparator />
            <form
              className="flex gap-2 p-2"
              onSubmit={(event) => {
                event.preventDefault();
                void save();
              }}
              onKeyDown={(event) => event.stopPropagation()}
            >
              <Input
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="Save cart as..."
                maxLength={60}
                aria-label="Name for this cart"
              />
              <Button type="submit" size="sm" disabled={saving || name.trim().length === 0}>
                Save
              </Button>
            </form>
          </>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
