import { supabase } from "@/integrations/supabase/client";

export type BusinessType = "pharmacy" | "wholesaler";

export type TypeChangeBlocker = {
  source_table: string;
  source_column: string;
  row_count: number;
};

// The functions are newer than the generated Supabase types.
const rpc = (name: string, args: Record<string, unknown>) =>
  (
    supabase as unknown as {
      rpc: (
        n: string,
        a: Record<string, unknown>,
      ) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
    }
  ).rpc(name, args);

export function otherBusinessType(type: BusinessType): BusinessType {
  return type === "pharmacy" ? "wholesaler" : "pharmacy";
}

export function businessTypeLabel(type: BusinessType) {
  return type === "pharmacy" ? "Pharmacy" : "Wholesaler";
}

/** "pharmacy_saved_carts" -> "pharmacy saved carts"; one entry per table, counts summed. */
export function describeBlockers(blockers: TypeChangeBlocker[]) {
  const byTable = new Map<string, number>();
  for (const blocker of blockers) {
    byTable.set(
      blocker.source_table,
      (byTable.get(blocker.source_table) ?? 0) + Number(blocker.row_count),
    );
  }
  return Array.from(byTable, ([table, count]) => ({
    label: table.replace(/_/g, " "),
    count,
    capped: count >= 1000,
  })).sort((a, b) => a.label.localeCompare(b.label));
}

export async function fetchTypeChangeBlockers(businessId: string) {
  const { data, error } = await rpc("admin_business_type_blockers", {
    p_business_id: businessId,
  });
  if (error) {
    return { blockers: null, error: error.message };
  }
  return { blockers: (data as TypeChangeBlocker[] | null) ?? [], error: null };
}

export async function changeBusinessType(
  businessId: string,
  newType: BusinessType,
  reason: string,
) {
  const { error } = await rpc("admin_change_business_type", {
    p_business_id: businessId,
    p_new_type: newType,
    p_reason: reason.trim() || null,
  });
  return { error: error?.message ?? null };
}
