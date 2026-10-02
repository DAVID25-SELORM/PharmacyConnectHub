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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import {
  ITEM_TYPE_FIELDS,
  ITEM_TYPE_OPTIONS,
  validateInventoryItemDraft,
  type PharmacyInventoryItem,
  type PharmacyItemType,
} from "@/lib/pharmacy-inventory";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

/** Create a new item, or edit an existing one's details (metadata only -- stock is changed via
 * AdjustStockDialog instead, never here, matching the backend's own separation). Which fields are
 * shown depends on the selected item type (see ITEM_TYPE_FIELDS) -- a consumable never asks for a
 * dosage form, equipment never asks for an expiry date, and so on. */
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
  const [itemType, setItemType] = useState<PharmacyItemType>("medicine");
  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [category, setCategory] = useState("");
  const [form, setForm] = useState("");
  const [packSize, setPackSize] = useState("");
  const [genericName, setGenericName] = useState("");
  const [strength, setStrength] = useState("");
  const [manufacturer, setManufacturer] = useState("");
  const [barcode, setBarcode] = useState("");
  const [batchNumber, setBatchNumber] = useState("");
  const [expiryDate, setExpiryDate] = useState("");
  const [unitOfMeasure, setUnitOfMeasure] = useState("");
  const [model, setModel] = useState("");
  const [serialNumber, setSerialNumber] = useState("");
  const [warrantyInfo, setWarrantyInfo] = useState("");
  const [supplier, setSupplier] = useState("");
  const [stock, setStock] = useState("0");
  const [reorderLevel, setReorderLevel] = useState("");
  const [unitCostGhs, setUnitCostGhs] = useState("");
  const [sellingPriceGhs, setSellingPriceGhs] = useState("");
  const [active, setActive] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) return;
    setItemType(item?.item_type ?? "medicine");
    setName(item?.name ?? "");
    setBrand(item?.brand ?? "");
    setCategory(item?.category ?? "");
    setForm(item?.form ?? "");
    setPackSize(item?.pack_size ?? "");
    setGenericName(item?.generic_name ?? "");
    setStrength(item?.strength ?? "");
    setManufacturer(item?.manufacturer ?? "");
    setBarcode(item?.barcode ?? "");
    setBatchNumber(item?.batch_number ?? "");
    setExpiryDate(item?.expiry_date ?? "");
    setUnitOfMeasure(item?.unit_of_measure ?? "");
    setModel(item?.model ?? "");
    setSerialNumber(item?.serial_number ?? "");
    setWarrantyInfo(item?.warranty_info ?? "");
    setSupplier(item?.supplier ?? "");
    setStock("0");
    setReorderLevel(item?.reorder_level != null ? String(item.reorder_level) : "");
    setUnitCostGhs(item?.unit_cost_ghs != null ? String(item.unit_cost_ghs) : "");
    setSellingPriceGhs(item?.selling_price_ghs != null ? String(item.selling_price_ghs) : "");
    setActive(item?.active ?? true);
    setError(null);
  }, [open, item]);

  const fields = ITEM_TYPE_FIELDS[itemType];

  const submit = async () => {
    const { error: validationError } = validateInventoryItemDraft({
      name,
      stock: isEdit ? undefined : stock,
      reorderLevel,
      unitCostGhs,
      sellingPriceGhs,
    });
    if (validationError) {
      setError(validationError);
      return;
    }
    setError(null);
    setSubmitting(true);
    const common = {
      p_brand: brand.trim() || null,
      p_category: category.trim() || null,
      p_form: fields.form ? form.trim() || null : null,
      p_pack_size: fields.packSize ? packSize.trim() || null : null,
      p_reorder_level: reorderLevel.trim() ? Number(reorderLevel) : null,
      p_unit_cost_ghs: unitCostGhs.trim() ? Number(unitCostGhs) : null,
      p_item_type: itemType,
      p_generic_name: fields.genericName ? genericName.trim() || null : null,
      p_strength: fields.strength ? strength.trim() || null : null,
      p_manufacturer: fields.manufacturer ? manufacturer.trim() || null : null,
      p_barcode: fields.barcode ? barcode.trim() || null : null,
      p_batch_number: fields.batch ? batchNumber.trim() || null : null,
      p_expiry_date: fields.expiry ? expiryDate || null : null,
      p_selling_price_ghs: sellingPriceGhs.trim() ? Number(sellingPriceGhs) : null,
      p_supplier: supplier.trim() || null,
      p_unit_of_measure: fields.unitOfMeasure ? unitOfMeasure.trim() || null : null,
      p_model: fields.model ? model.trim() || null : null,
      p_serial_number: fields.serialNumber ? serialNumber.trim() || null : null,
      p_warranty_info: fields.warranty ? warrantyInfo.trim() || null : null,
    };
    const { error: rpcError } = isEdit
      ? await rpc("update_pharmacy_inventory_item_details", {
          p_item_id: item.id,
          p_name: name.trim(),
          p_active: active,
          ...common,
        })
      : await rpc("create_pharmacy_inventory_item", {
          p_pharmacy_id: pharmacyId,
          p_name: name.trim(),
          p_stock: Number(stock),
          ...common,
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
            <Label htmlFor="item-type">Item type</Label>
            <Select value={itemType} onValueChange={(v) => setItemType(v as PharmacyItemType)}>
              <SelectTrigger id="item-type">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {ITEM_TYPE_OPTIONS.map((opt) => (
                  <SelectItem key={opt.value} value={opt.value}>
                    {opt.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

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

            {fields.genericName && (
              <div className="space-y-1.5">
                <Label htmlFor="item-generic">Generic name (optional)</Label>
                <Input id="item-generic" value={genericName} onChange={(e) => setGenericName(e.target.value)} />
              </div>
            )}
            {fields.strength && (
              <div className="space-y-1.5">
                <Label htmlFor="item-strength">Strength (optional)</Label>
                <Input id="item-strength" value={strength} onChange={(e) => setStrength(e.target.value)} placeholder="500mg" />
              </div>
            )}
            {fields.form && (
              <div className="space-y-1.5">
                <Label htmlFor="item-form">Dosage form (optional)</Label>
                <Input id="item-form" value={form} onChange={(e) => setForm(e.target.value)} placeholder="Tablet, Capsule..." />
              </div>
            )}
            {fields.packSize && (
              <div className="space-y-1.5">
                <Label htmlFor="item-pack">Pack size (optional)</Label>
                <Input id="item-pack" value={packSize} onChange={(e) => setPackSize(e.target.value)} placeholder="20s, 100ml..." />
              </div>
            )}
            {fields.manufacturer && (
              <div className="space-y-1.5">
                <Label htmlFor="item-manufacturer">Manufacturer (optional)</Label>
                <Input id="item-manufacturer" value={manufacturer} onChange={(e) => setManufacturer(e.target.value)} />
              </div>
            )}
            {fields.unitOfMeasure && (
              <div className="space-y-1.5">
                <Label htmlFor="item-unit">Unit of measure (optional)</Label>
                <Input id="item-unit" value={unitOfMeasure} onChange={(e) => setUnitOfMeasure(e.target.value)} placeholder="box, bottle, pack..." />
              </div>
            )}
            {fields.barcode && (
              <div className="space-y-1.5">
                <Label htmlFor="item-barcode">Barcode / SKU (optional)</Label>
                <Input id="item-barcode" value={barcode} onChange={(e) => setBarcode(e.target.value)} />
              </div>
            )}
            {fields.batch && (
              <div className="space-y-1.5">
                <Label htmlFor="item-batch">Batch / lot number (optional)</Label>
                <Input id="item-batch" value={batchNumber} onChange={(e) => setBatchNumber(e.target.value)} />
              </div>
            )}
            {fields.expiry && (
              <div className="space-y-1.5">
                <Label htmlFor="item-expiry">Expiry date (optional)</Label>
                <Input id="item-expiry" type="date" value={expiryDate} onChange={(e) => setExpiryDate(e.target.value)} />
              </div>
            )}
            {fields.model && (
              <div className="space-y-1.5">
                <Label htmlFor="item-model">Model (optional)</Label>
                <Input id="item-model" value={model} onChange={(e) => setModel(e.target.value)} />
              </div>
            )}
            {fields.serialNumber && (
              <div className="space-y-1.5">
                <Label htmlFor="item-serial">Serial number (optional)</Label>
                <Input id="item-serial" value={serialNumber} onChange={(e) => setSerialNumber(e.target.value)} />
              </div>
            )}
            {fields.warranty && (
              <div className="space-y-1.5">
                <Label htmlFor="item-warranty">Warranty information (optional)</Label>
                <Input id="item-warranty" value={warrantyInfo} onChange={(e) => setWarrantyInfo(e.target.value)} placeholder="2 years" />
              </div>
            )}

            <div className="space-y-1.5">
              <Label htmlFor="item-supplier">Supplier (optional)</Label>
              <Input id="item-supplier" value={supplier} onChange={(e) => setSupplier(e.target.value)} />
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
              <Label htmlFor="item-cost">Cost price GHS (optional)</Label>
              <Input id="item-cost" type="number" min={0} step="0.01" value={unitCostGhs} onChange={(e) => setUnitCostGhs(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="item-selling-price">Selling price GHS (optional)</Label>
              <Input
                id="item-selling-price"
                type="number"
                min={0}
                step="0.01"
                value={sellingPriceGhs}
                onChange={(e) => setSellingPriceGhs(e.target.value)}
              />
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
