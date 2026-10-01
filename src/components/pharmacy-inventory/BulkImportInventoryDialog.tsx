import { useState } from "react";
import { Download, Loader2, Upload } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import {
  parsePharmacyInventoryImportFile,
  parsePharmacyInventoryImportText,
  type InventoryImportResult,
} from "@/lib/product-import";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

type ImportPreview = {
  token: string;
  rows: {
    row: number;
    name: string;
    kind: "new" | "existing";
    stock_before: number | null;
    stock_after: number;
    cost_before: number | null;
    cost_after: number | null;
  }[];
  issues: { row: number; message: string }[];
  inserted_count?: number;
  updated_count?: number;
};

export function BulkImportInventoryDialog({
  pharmacyId,
  reload,
}: {
  pharmacyId: string;
  reload: () => Promise<void> | void;
}) {
  const [open, setOpen] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [pasteText, setPasteText] = useState("");
  const [sourceMode, setSourceMode] = useState<"file" | "paste">("file");
  const [mode, setMode] = useState<"replace" | "add" | "details">("add");
  const [parsed, setParsed] = useState<InventoryImportResult | null>(null);
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [requestId, setRequestId] = useState<string | null>(null);

  const invalidatePreview = () => {
    setPreview(null);
    setParsed(null);
    setRequestId(null);
  };

  const downloadTemplate = () => {
    const csvContent = `name,brand,category,form,pack_size,stock,unit_cost_ghs,reorder_level
Paracetamol 500mg,Generic,Analgesics & Pain Relief,Tablet,20s,100,4.50,20
Amoxicillin 500mg,Generic,Antibiotics,Capsule,10s,60,8.00,10`;
    const blob = new Blob([csvContent], { type: "text/csv" });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "pharmacy-inventory-template.csv";
    a.click();
    window.URL.revokeObjectURL(url);
  };

  const resetForm = () => {
    invalidatePreview();
    setMode("add");
    setFile(null);
    setPasteText("");
    setSourceMode("file");
  };

  const handleOpenChange = (nextOpen: boolean) => {
    if (uploading) return;
    setOpen(nextOpen);
    if (!nextOpen) resetForm();
  };

  const onUpload = async () => {
    if (sourceMode === "file" && !file) {
      toast.error("Select a file to import.");
      return;
    }
    if (sourceMode === "paste" && !pasteText.trim()) {
      toast.error("Paste an item table before importing.");
      return;
    }
    setUploading(true);
    try {
      const result = sourceMode === "file" && file ? await parsePharmacyInventoryImportFile(file) : parsePharmacyInventoryImportText(pasteText);
      setParsed(result);
      setRequestId(crypto.randomUUID());
      if (result.items.length === 0) {
        setPreview({ token: "", rows: [], issues: [] });
        return;
      }
      const { data, error } = await rpc("preview_pharmacy_inventory_import", {
        p_pharmacy_id: pharmacyId,
        p_items: result.items.map((i) => ({
          name: i.name,
          brand: i.brand,
          category: i.category,
          form: i.form,
          pack_size: i.pack_size,
          stock: i.stock,
          unitCostGhs: i.unitCostGhs,
          reorderLevel: i.reorderLevel,
          source_row: i.source_row,
        })),
        p_mode: mode,
      });
      if (error) throw error;
      setPreview(data as unknown as ImportPreview);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to import items.");
    } finally {
      setUploading(false);
    }
  };

  const confirmImport = async () => {
    if (!preview || !parsed || !requestId || uploading) return;
    setUploading(true);
    try {
      const { data, error } = await rpc("preview_pharmacy_inventory_import", {
        p_pharmacy_id: pharmacyId,
        p_items: parsed.items.map((i) => ({
          name: i.name,
          brand: i.brand,
          category: i.category,
          form: i.form,
          pack_size: i.pack_size,
          stock: i.stock,
          unitCostGhs: i.unitCostGhs,
          reorderLevel: i.reorderLevel,
          source_row: i.source_row,
        })),
        p_mode: mode,
        p_confirm_token: preview.token,
        p_request_id: requestId,
      });
      if (error) throw error;
      const result = data as unknown as ImportPreview;
      toast.success(`Imported: ${result.inserted_count ?? 0} new, ${result.updated_count ?? 0} updated.`);
      setOpen(false);
      resetForm();
      void reload();
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Import failed. You can retry confirmation safely.");
    } finally {
      setUploading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger asChild>
        <Button variant="outline">
          <Upload className="h-4 w-4" /> Bulk upload
        </Button>
      </DialogTrigger>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>Bulk upload inventory</DialogTitle>
          <DialogDescription>
            Import items from CSV, Excel, PDF, or a pasted table. No price or cost column is
            required -- just a name and, optionally, a stock count.
          </DialogDescription>
        </DialogHeader>
        <fieldset disabled={uploading} className="space-y-4 disabled:opacity-70">
          <div className="space-y-2">
            <Label>Stock import mode</Label>
            <Select value={mode} disabled={uploading} onValueChange={(value) => { setMode(value as typeof mode); invalidatePreview(); }}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="replace">Replace stock</SelectItem>
                <SelectItem value="add">Add to stock</SelectItem>
                <SelectItem value="details">Update details only</SelectItem>
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground">
              {mode === "replace"
                ? "Entered quantities replace the current stock count. Blank quantities leave stock unchanged; new items start at zero."
                : mode === "add"
                  ? "Entered quantities are added to current stock. Blank quantities leave stock unchanged."
                  : "Only names, brand, category, cost, etc. are updated. Stock is never touched, even if a quantity is included."}{" "}
              Maximum 5,000 items per import.
            </p>
          </div>

          <div className="rounded-xl border border-border bg-muted/30 p-4">
            <h4 className="mb-2 text-sm font-medium">Step 1: Download template</h4>
            <Button variant="outline" size="sm" onClick={downloadTemplate}>
              <Download className="h-4 w-4" /> Download template
            </Button>
          </div>

          <div className="rounded-xl border border-border bg-muted/30 p-4">
            <h4 className="mb-3 text-sm font-medium">Step 2: Import items</h4>
            <Tabs value={sourceMode} onValueChange={(value) => { setSourceMode(value as "file" | "paste"); invalidatePreview(); }}>
              <TabsList className="mb-4 grid w-full grid-cols-2">
                <TabsTrigger value="file">Upload file</TabsTrigger>
                <TabsTrigger value="paste">Paste table</TabsTrigger>
              </TabsList>
              <TabsContent value="file" className="space-y-3">
                <Input
                  type="file"
                  accept=".csv,.tsv,.txt,.xlsx,.xls,.pdf"
                  onChange={(e) => { setFile(e.target.files?.[0] || null); invalidatePreview(); }}
                />
                <p className="text-xs text-muted-foreground">Accepted: CSV, TSV, TXT, XLSX, XLS, PDF</p>
                {file && <p className="text-xs text-muted-foreground">Selected: {file.name} ({(file.size / 1024).toFixed(1)} KB)</p>}
              </TabsContent>
              <TabsContent value="paste" className="space-y-3">
                <Textarea
                  rows={8}
                  value={pasteText}
                  onChange={(e) => { setPasteText(e.target.value); invalidatePreview(); }}
                  placeholder={`name,stock,unit_cost_ghs\nParacetamol 500mg,100,4.50`}
                />
                <p className="text-xs text-muted-foreground">Paste rows copied from Excel, Google Sheets, or any table with headers.</p>
              </TabsContent>
            </Tabs>
          </div>
        </fieldset>

        {preview && parsed && (
          <section className="space-y-3" aria-label="Import preview">
            <h3 className="font-semibold">Import preview</h3>
            <p className="text-sm">
              {preview.rows.filter((r) => r.kind === "new").length} new items;{" "}
              {preview.rows.filter((r) => r.kind === "existing").length} existing items;{" "}
              {preview.rows.filter((r) => (r.stock_before ?? 0) !== r.stock_after).length} stock changes.
            </p>
            {parsed.invalidRows.length > 0 && (
              <p role="alert" className="text-sm text-destructive">
                Invalid rows: {parsed.invalidRows.join(", ")}. Each row needs a name and, if given, a
                non-negative whole stock quantity and cost.
              </p>
            )}
            {preview.issues.map((issue, index) => (
              <p role="alert" className="text-sm text-destructive" key={index}>
                Row {issue.row}: {issue.message}
              </p>
            ))}
            {preview.rows.length === 0 && <p>No valid items detected. Check the template headers and values.</p>}
            <div className="max-h-64 overflow-auto rounded border">
              <table className="w-full text-left text-sm">
                <thead>
                  <tr>
                    <th className="p-2">Row / item</th>
                    <th className="p-2">Match</th>
                    <th className="p-2">Stock</th>
                    <th className="p-2">Cost (GHS)</th>
                  </tr>
                </thead>
                <tbody>
                  {preview.rows.map((row) => (
                    <tr key={row.row} className="border-t">
                      <td className="p-2">{row.row}. {row.name}</td>
                      <td className="p-2">{row.kind}</td>
                      <td className="p-2">{row.stock_before ?? "New"} to {row.stock_after}</td>
                      <td className="p-2">{row.cost_after === null ? "—" : formatGHS(row.cost_after)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="text-xs text-muted-foreground">
              Nothing has been saved. Fix invalid or duplicate rows before confirming. If inventory
              changes, refresh the preview.
            </p>
          </section>
        )}

        <DialogFooter>
          <Button type="button" variant="outline" disabled={uploading} onClick={() => handleOpenChange(false)}>
            Cancel
          </Button>
          <Button
            type="button"
            variant="secondary"
            onClick={() => { invalidatePreview(); void onUpload(); }}
            disabled={uploading || (sourceMode === "file" ? !file : !pasteText.trim())}
          >
            {uploading && <Loader2 className="h-4 w-4 animate-spin" />} {preview ? "Refresh preview" : "Preview import"}
          </Button>
          {preview && (
            <Button
              type="button"
              onClick={() => void confirmImport()}
              disabled={uploading || !preview.token || preview.rows.length === 0 || preview.issues.length > 0 || !!parsed?.invalidRows.length}
            >
              Confirm import
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
