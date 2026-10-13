import { useState } from "react";
import { Download, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import { downloadCsv, rowsToCsv } from "@/lib/reports";

const fields = ["id", "name", "brand", "category", "form", "pack_size", "price_ghs", "stock", "active", "warehouse", "zone", "rack", "shelf", "bin"] as const;

export function ExportProductsButton({ businessId }: { businessId: string }) {
  const [busy, setBusy] = useState(false);
  async function exportProducts() {
    setBusy(true);
    try {
      const rows: Array<Array<string | number>> = [];
      const pageSize = 500;
      for (let offset = 0; ; offset += pageSize) {
        const { data, error } = await supabase.from("products")
          .select("id,name,brand,category,form,pack_size,price_ghs,stock,active,warehouse,zone,rack,shelf,bin")
          .eq("wholesaler_id", businessId).order("id")
          .range(offset, offset + pageSize - 1);
        if (error) throw error;
        for (const product of data ?? []) {
          rows.push(fields.map((field) => {
            const value = product[field];
            return typeof value === "boolean" ? String(value) : value ?? "";
          }));
        }
        if (!data || data.length < pageSize) break;
      }
      if (!rows.length) { toast.info("No products to export."); return; }
      downloadCsv(`drugxone-products-${businessId}-${new Date().toISOString().slice(0, 10)}.csv`, "\uFEFF" + rowsToCsv([...fields], rows));
      toast.success(`Exported ${rows.length} products.`);
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Could not export products. Please try again.");
    } finally {
      setBusy(false);
    }
  }
  return <Button variant="outline" disabled={busy} onClick={() => void exportProducts()} title="Download all products, including inactive products, as CSV">
    {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
    {busy ? "Exporting…" : "Export all products"}
  </Button>;
}
