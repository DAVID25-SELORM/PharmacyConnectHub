import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { validateInventoryItemDraft, type PharmacyInventoryItem } from "@/lib/pharmacy-inventory";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

/** Create a new item, or edit an existing one's details (metadata only -- stock is changed via
 * AdjustStockDialog instead, never here, matching the backend's own separation). */
export function InventoryItemFormDialog({
  pharmacyId,
  item,
  open,
  onOpenChange,
  onSaved,
}: {
  pharmacyId: string;
  item: PharmacyInventoryItem | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const isEdit = item !== null;
  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [category, setCategory] = useState("");
  const [form, setForm] = useState("");
  const [packSize, setPackSize] = useState("");
  const [stock, setStock] = useState("0");
  const [reorderLevel, setReorderLevel] = useState("");
  const [unitCostGhs, setUnitCostGhs] = useState("");
  const [active, setActive] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) return;
    setName(item?.name ?? "");
    setBrand(item?.brand ?? "");
    setCategory(item?.category ?? "");
    setForm(item?.form ?? "");
    setPackSize(item?.pack_size ?? "");
    setStock("0");
    setReorderLevel(item?.reorder_level != null ? String(item.reorder_level) : "");
    setUnitCostGhs(item?.unit_cost_ghs != null ? String(item.unit_cost_ghs) : "");
    setActive(item?.active ?? true);
    setError(null);
  }, [open, item]);

  const submit = async () => {
    const { error: validationError } = validateInventoryItemDraft({
      name,
      stock: isEdit ? undefined : stock,
      reorderLevel,
      unitCostGhs,
    });
    if (validationError) {
      setError(validationError);
      return;
    }
    setError(null);
    setSubmitting(true);
    const { error: rpcError } = isEdit
      ? await rpc("update_pharmacy_inventory_item_details", {
          p_item_id: item.id,
          p_name: name.trim(),
          p_brand: brand.trim() || null,
          p_category: category.trim() || null,
          p_form: form.trim() || null,
          p_pack_size: packSize.trim() || null,
          p_reorder_level: reorderLevel.trim() ? Number(reorderLevel) : null,
          p_unit_cost_ghs: unitCostGhs.trim() ? Number(unitCostGhs) : null,
          p_active: active,
        })
      : await rpc("create_pharmacy_inventory_item", {
          p_pharmacy_id: pharmacyId,
          p_name: name.trim(),
          p_brand: brand.trim() || null,
          p_category: category.trim() || null,
          p_form: form.trim() || null,
          p_pack_size: packSize.trim() || null,
          p_stock: Number(stock),
          p_reorder_level: reorderLevel.trim() ? Number(reorderLevel) : null,
          p_unit_cost_ghs: unitCostGhs.trim() ? Number(unitCostGhs) : null,
        });
    setSubmitting(false);
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    toast.success(isEdit ? "Item updated" : "Item added");
    onOpenChange(false);
    onSaved();
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{isEdit ? "Edit item" : "Add inventory item"}</DialogTitle>
          <DialogDescription>
            {isEdit
              ? "Update this item's details. To change its stock count, use Receive / Adjust / Write off instead."
              : "Track a new item in your pharmacy's stock."}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="item-name">Name</Label>
            <Input id="item-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Paracetamol 500mg" />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="item-brand">Brand (optional)</Label>
              <Input id="item-brand" value={brand} onChange={(e) => setBrand(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="item-category">Category (optional)</Label>
              <Input id="item-category" value={category} onChange={(e) => setCategory(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="item-form">Form (optional)</Label>
              <Input id="item-form" value={form} onChange={(e) => setForm(e.target.value)} placeholder="Tablet, Capsule..." />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="item-pack">Pack size (optional)</Label>
              <Input id="item-pack" value={packSize} onChange={(e) => setPackSize(e.target.value)} placeholder="20s, 100ml..." />
            </div>
            {!isEdit && (
              <div className="space-y-1.5">
                <Label htmlFor="item-stock">Starting stock</Label>
                <Input id="item-stock" type="number" min={0} value={stock} onChange={(e) => setStock(e.target.value)} />
              </div>
            )}
            <div className="space-y-1.5">
              <Label htmlFor="item-reorder">Reorder level (optional)</Label>
              <Input id="item-reorder" type="number" min={0} value={reorderLevel} onChange={(e) => setReorderLevel(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="item-cost">Unit cost GHS (optional)</Label>
              <Input id="item-cost" type="number" min={0} step="0.01" value={unitCostGhs} onChange={(e) => setUnitCostGhs(e.target.value)} />
            </div>
          </div>
          {isEdit && (
            <label className="flex items-center gap-2 text-sm">
              <Checkbox checked={active} onCheckedChange={(c) => setActive(c === true)} />
              Active (shown in the inventory list by default)
            </label>
          )}
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={submitting}>
            Cancel
          </Button>
          <Button type="button" onClick={() => void submit()} disabled={submitting}>
            {submitting ? "Saving..." : isEdit ? "Save changes" : "Add item"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
