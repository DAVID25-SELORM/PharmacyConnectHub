import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";

export type SavedCartItem = {
  id: string;
  product_id: string;
  name_snapshot: string;
  quantity: number;
};

export type SavedCart = {
  id: string;
  name: string;
  updated_at: string;
  items: SavedCartItem[];
};

type DbError = { code?: string; message?: string } | null;

function friendly(error: DbError, fallback: string) {
  if (!error) return fallback;
  if (error.code === "23505") return "You already have a saved cart with that name.";
  if (error.code === "P0001" && error.message) return error.message;
  if (error.code === "42501") return "You don't have permission to save carts for this pharmacy.";
  return fallback;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = () => supabase as any;

/**
 * Named saved carts (the "Save cart as..." feature). The pharmacy's single unnamed draft cart is
 * handled separately in the pharmacy page itself, since it is tied directly to the live cart state.
 */
export function useSavedCarts(pharmacyId: string | null) {
  const [carts, setCarts] = useState<SavedCart[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  const reload = useCallback(async () => {
    if (!pharmacyId) return;
    setError(false);
    const { data, error: loadError } = await db()
      .from("pharmacy_saved_carts")
      .select("id,name,updated_at,pharmacy_saved_cart_items(id,product_id,name_snapshot,quantity)")
      .eq("pharmacy_id", pharmacyId)
      .not("name", "is", null)
      .order("updated_at", { ascending: false });
    if (loadError) {
      setError(true);
      setLoading(false);
      return;
    }
    setCarts(
      (data ?? []).map(
        (row: {
          id: string;
          name: string;
          updated_at: string;
          pharmacy_saved_cart_items: SavedCartItem[];
        }) => ({
          id: row.id,
          name: row.name,
          updated_at: row.updated_at,
          items: row.pharmacy_saved_cart_items ?? [],
        }),
      ),
    );
    setLoading(false);
  }, [pharmacyId]);

  useEffect(() => {
    void reload();
  }, [reload]);

  const createFromCart = async (
    name: string,
    items: Array<{ productId: string; quantity: number; name: string }>,
  ): Promise<boolean> => {
    const trimmed = name.trim();
    if (!pharmacyId || trimmed.length === 0) return false;
    const { error: rpcError } = await db().rpc("create_saved_cart", {
      p_pharmacy_id: pharmacyId,
      p_name: trimmed,
      p_items: items.map((item) => ({
        productId: item.productId,
        quantity: item.quantity,
        name: item.name,
      })),
    });
    if (rpcError) {
      toast.error(friendly(rpcError, "We couldn't save this cart."));
      return false;
    }
    await reload();
    return true;
  };

  const deleteCart = async (cartId: string) => {
    const { error: deleteError } = await db()
      .from("pharmacy_saved_carts")
      .delete()
      .eq("id", cartId);
    if (deleteError)
      return toast.error(friendly(deleteError, "We couldn't delete this saved cart."));
    await reload();
  };

  return { carts, loading, error, reload, createFromCart, deleteCart };
}

export type SavedCartsApi = ReturnType<typeof useSavedCarts>;
