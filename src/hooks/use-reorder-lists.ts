import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";

export type ReorderItem = {
  id: string;
  master_product_id: string;
  name_snapshot: string;
  quantity: number;
  preferred_wholesaler_id: string | null;
};

export type ReorderList = {
  id: string;
  name: string;
  updated_at: string;
  items: ReorderItem[];
};

type DbError = { code?: string; message?: string } | null;

/** Rule messages raised by the database (SQLSTATE P0001) are written for people; others are not. */
function friendly(error: DbError, fallback: string) {
  if (!error) return fallback;
  if (error.code === "23505")
    return "That is already on the list, or you already have a list with that name.";
  if (error.code === "P0001" && error.message) return error.message;
  if (error.code === "42501") return "You don't have permission to change reorder lists.";
  return fallback;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = () => supabase as any;

export function useReorderLists(pharmacyId: string | null) {
  const [lists, setLists] = useState<ReorderList[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  const reload = useCallback(async () => {
    if (!pharmacyId) return;
    setError(false);
    const { data, error: loadError } = await db()
      .from("reorder_lists")
      .select(
        "id,name,updated_at,reorder_list_items(id,master_product_id,name_snapshot,quantity,preferred_wholesaler_id)",
      )
      .eq("pharmacy_id", pharmacyId)
      .order("name");
    if (loadError) {
      setError(true);
      setLoading(false);
      return;
    }
    setLists(
      (data ?? []).map(
        (row: {
          id: string;
          name: string;
          updated_at: string;
          reorder_list_items: ReorderItem[];
        }) => ({
          id: row.id,
          name: row.name,
          updated_at: row.updated_at,
          items: [...(row.reorder_list_items ?? [])].sort((a, b) =>
            a.name_snapshot.localeCompare(b.name_snapshot),
          ),
        }),
      ),
    );
    setLoading(false);
  }, [pharmacyId]);

  useEffect(() => {
    void reload();
  }, [reload]);

  const createList = async (name: string): Promise<string | null> => {
    const trimmed = name.trim();
    if (!pharmacyId || trimmed.length === 0) return null;
    const { data: userData } = await supabase.auth.getUser();
    const { data, error: insertError } = await db()
      .from("reorder_lists")
      .insert({ pharmacy_id: pharmacyId, name: trimmed, created_by: userData.user?.id })
      .select("id")
      .single();
    if (insertError) {
      toast.error(friendly(insertError, "We couldn't create the list. Please try again."));
      return null;
    }
    await reload();
    return data.id as string;
  };

  const renameList = async (listId: string, name: string) => {
    const { error: updateError } = await db()
      .from("reorder_lists")
      .update({ name: name.trim() })
      .eq("id", listId);
    if (updateError) return toast.error(friendly(updateError, "We couldn't rename the list."));
    await reload();
  };

  const deleteList = async (listId: string) => {
    const { error: deleteError } = await db().from("reorder_lists").delete().eq("id", listId);
    if (deleteError) return toast.error(friendly(deleteError, "We couldn't delete the list."));
    await reload();
  };

  const addItem = async (
    listId: string,
    item: {
      masterProductId: string;
      name: string;
      quantity: number;
      preferredWholesalerId?: string | null;
    },
  ): Promise<boolean> => {
    const { error: insertError } = await db()
      .from("reorder_list_items")
      .insert({
        list_id: listId,
        master_product_id: item.masterProductId,
        name_snapshot: item.name.slice(0, 200),
        quantity: Math.max(1, Math.floor(item.quantity)),
        preferred_wholesaler_id: item.preferredWholesalerId ?? null,
      });
    if (insertError) {
      toast.error(friendly(insertError, "We couldn't add this medicine to the list."));
      return false;
    }
    await reload();
    return true;
  };

  const updateItem = async (
    itemId: string,
    patch: { quantity?: number; preferred_wholesaler_id?: string | null },
  ) => {
    const { error: updateError } = await db()
      .from("reorder_list_items")
      .update(patch)
      .eq("id", itemId);
    if (updateError) return toast.error(friendly(updateError, "We couldn't update this line."));
    await reload();
  };

  const removeItem = async (itemId: string) => {
    const { error: deleteError } = await db().from("reorder_list_items").delete().eq("id", itemId);
    if (deleteError) return toast.error(friendly(deleteError, "We couldn't remove this line."));
    await reload();
  };

  return {
    lists,
    loading,
    error,
    reload,
    createList,
    renameList,
    deleteList,
    addItem,
    updateItem,
    removeItem,
  };
}

export type ReorderListsApi = ReturnType<typeof useReorderLists>;
