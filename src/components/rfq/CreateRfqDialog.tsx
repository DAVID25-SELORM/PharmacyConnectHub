import { rfqRows, rfqRowIssues } from "@/lib/rfq-bulk";
import { useSession } from "@/hooks/use-session";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { useEffect, useState } from "react";
import { Plus, Trash2 } from "lucide-react";
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
import { MedicationPicker } from "@/components/rfq/MedicationPicker";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { validateRfqDraft, type RfqItemDraft } from "@/lib/rfq";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

type WholesalerOption = { id: string; name: string };

const emptyItem = (): RfqItemDraft => ({ productName: "", quantity: "", notes: "" });

export function CreateRfqDialog({
  pharmacyId,
  open,
  onOpenChange,
  onCreated,
}: {
  pharmacyId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated: () => void;
}) {
  const [wholesalers, setWholesalers] = useState<WholesalerOption[]>([]);
  const [selectedWholesalers, setSelectedWholesalers] = useState<string[]>([]);
  const [sendMode, setSendMode] = useState<"selected" | "all">("selected");
  const { user } = useSession();
  const draftKey = `rfq-draft:${user?.id}:${pharmacyId}`;
  const [itemPage, setItemPage] = useState(0);
  const [itemQuery, setItemQuery] = useState("");
  const [supplierPage, setSupplierPage] = useState(0);
  const [supplierCount, setSupplierCount] = useState(0);
  const [totalSuppliers, setTotalSuppliers] = useState(0);
  const [selectedOnly, setSelectedOnly] = useState(false);
  const [supplierLoading, setSupplierLoading] = useState(false);
  const [supplierError, setSupplierError] = useState("");
  const [bulk, setBulk] = useState("");
  const [importing, setImporting] = useState(false);
  const [review, setReview] = useState(false);
  const [supplierQuery, setSupplierQuery] = useState("");
  const [title, setTitle] = useState("");
  const [notes, setNotes] = useState("");
  const [responseDeadline, setResponseDeadline] = useState("");
  const [items, setItems] = useState<RfqItemDraft[]>([emptyItem()]);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const search = useDebouncedValue(supplierQuery, 250);
  useEffect(() => {
    if (!open) return;
    setTitle("");
    setNotes("");
    setResponseDeadline("");
    setItems([emptyItem()]);
    setSelectedWholesalers([]);
    setSendMode("selected");
    setItemPage(0);
    setItemQuery("");
    setSupplierPage(0);
    setSupplierQuery("");
    setSelectedOnly(false);
    setError(null);
    setReview(false);
    setBulk("");
    try {
      const saved = JSON.parse(localStorage.getItem(draftKey) ?? "null");
      if (
        saved &&
        Array.isArray(saved.items) &&
        saved.items.every(
          (i: RfqItemDraft) =>
            typeof i.productName === "string" &&
            typeof i.quantity === "string" &&
            typeof i.notes === "string",
        )
      ) {
        setTitle(saved.title ?? "");
        setNotes(saved.notes ?? "");
        setResponseDeadline(saved.responseDeadline ?? "");
        setItems(saved.items.length ? saved.items : [emptyItem()]);
        setSelectedWholesalers(saved.selectedWholesalers ?? []);
        setSendMode(saved.sendMode === "all" ? "all" : "selected");
      }
    } catch {
      toast.error("The saved draft could not be restored.");
    }
  }, [open, draftKey]);
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setSupplierLoading(true);
    setSupplierError("");
    let query = supabase
      .from("businesses")
      .select("id,name", { count: "exact" })
      .eq("type", "wholesaler")
      .eq("verification_status", "approved");
    if (search.trim()) query = query.ilike("name", `%${search.trim().replace(/[%_\\]/g, "")}%`);
    if (selectedOnly)
      query = query.in(
        "id",
        selectedWholesalers.length ? selectedWholesalers : ["00000000-0000-0000-0000-000000000000"],
      );
    void Promise.all([
      query
        .order("name")
        .order("id")
        .range(supplierPage * 20, supplierPage * 20 + 19),
      supabase
        .from("businesses")
        .select("id", { count: "exact", head: true })
        .eq("type", "wholesaler")
        .eq("verification_status", "approved"),
    ]).then(([result, total]) => {
      if (cancelled) return;
      setSupplierLoading(false);
      if (result.error || total.error) {
        setSupplierError("Could not load suppliers. Reopen the editor to retry.");
        return;
      }
      setWholesalers(result.data ?? []);
      setSupplierCount(result.count ?? 0);
      setTotalSuppliers(total.count ?? 0);
    });
    return () => {
      cancelled = true;
    };
  }, [open, search, supplierPage, selectedOnly, selectedWholesalers]);
  const shownWholesalers = wholesalers;
  const indexedItems = items
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => item.productName.toLowerCase().includes(itemQuery.toLowerCase()));
  const currentItemPage = Math.min(itemPage, Math.max(0, Math.ceil(indexedItems.length / 25) - 1));
  const visibleItems = indexedItems.slice(currentItemPage * 25, currentItemPage * 25 + 25);
  const issues = rfqRowIssues(items);
  const saveDraft = () => {
    try {
      localStorage.setItem(
        draftKey,
        JSON.stringify({ title, notes, responseDeadline, items, selectedWholesalers, sendMode }),
      );
      toast.success("Draft saved on this device for this account and pharmacy.");
    } catch {
      toast.error("Could not save draft. Keep this editor open and try again.");
    }
  };
  const importRows = async (file?: File) => {
    setImporting(true);
    try {
      const XLSX = await import("xlsx");
      const workbook = file
        ? XLSX.read(await file.arrayBuffer(), { type: "array" })
        : XLSX.read(bulk, { type: "string" });
      const rows = rfqRows(
        XLSX.utils.sheet_to_json(workbook.Sheets[workbook.SheetNames[0]], {
          header: 1,
          defval: "",
          raw: false,
        }),
      );
      setItems((current) => [
        ...current.filter((i) => i.productName.trim() || i.quantity.trim() || i.notes.trim()),
        ...rows,
      ]);
      setItemQuery("");
      setItemPage(0);
      setBulk("");
      toast.success(`${rows.length} rows added. Review highlighted issues before sending.`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not import rows.");
    } finally {
      setImporting(false);
    }
  };

  const toggleWholesaler = (id: string, checked: boolean) => {
    setSelectedWholesalers((prev) => (checked ? [...prev, id] : prev.filter((w) => w !== id)));
  };

  const updateItem = (index: number, patch: Partial<RfqItemDraft>) => {
    setItems((prev) => prev.map((item, i) => (i === index ? { ...item, ...patch } : item)));
  };

  const removeItem = (index: number) => {
    setItems((prev) => prev.filter((_, i) => i !== index));
  };

  const submit = async () => {
    if (submitting || importing || supplierLoading || supplierError) return;
    if (issues.size) {
      setError("Fix the highlighted medicine rows before sending.");
      return;
    }
    let recipientIds = selectedWholesalers;
    if (!review) {
      const checked = validateRfqDraft({
        title,
        wholesalerIds: sendMode === "all" && totalSuppliers > 0 ? ["all"] : selectedWholesalers,
        items,
        responseDeadline,
      });
      if (checked.error) {
        setError(checked.error);
        return;
      }
      setError(null);
      setReview(true);
      return;
    }
    setSubmitting(true);
    if (sendMode === "all") {
      recipientIds = [];
      for (let offset = 0; ; offset += 500) {
        const result = await supabase
          .from("businesses")
          .select("id")
          .eq("type", "wholesaler")
          .eq("verification_status", "approved")
          .order("id")
          .range(offset, offset + 499);
        if (result.error) {
          setSubmitting(false);
          setError("Could not resolve all suppliers. Nothing was sent.");
          return;
        }
        recipientIds.push(...(result.data ?? []).map((w) => w.id));
        if ((result.data?.length ?? 0) < 500) break;
      }
      if (recipientIds.length !== totalSuppliers) {
        setTotalSuppliers(recipientIds.length);
        setSubmitting(false);
        setError("The eligible supplier count changed. Review the count and confirm again.");
        return;
      }
    }
    const { error: validationError, items: cleanItems } = validateRfqDraft({
      title,
      wholesalerIds: recipientIds,
      items,
      responseDeadline,
    });
    if (validationError || !cleanItems) {
      setSubmitting(false);
      setError(validationError);
      return;
    }
    setError(null);
    setSubmitting(true);
    const { error: rpcError } = await rpc("create_rfq", {
      p_pharmacy_id: pharmacyId,
      p_title: title.trim(),
      p_notes: notes.trim() || null,
      p_response_deadline: responseDeadline ? new Date(responseDeadline).toISOString() : null,
      p_wholesaler_ids: recipientIds,
      p_items: cleanItems.map((i) => ({
        productName: i.productName.trim(),
        quantity: Number(i.quantity),
        notes: i.notes.trim() || null,
      })),
    });
    setSubmitting(false);
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    try {
      localStorage.removeItem(draftKey);
    } catch {
      /* Request is already saved on the server. */
    }
    toast.success("Quote request sent");
    onOpenChange(false);
    onCreated();
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!submitting) onOpenChange(next);
      }}
    >
      <DialogContent className="h-[95dvh] w-[96vw] max-w-none sm:max-w-[96vw] flex flex-col">
        <DialogHeader>
          <DialogTitle>Request quotes</DialogTitle>
          <DialogDescription>
            Save your draft before closing to keep your work on this device. Ask suppliers to quote
            on a list of items — pick specific ones or send to everyone eligible. Only the suppliers
            you send this to will see it, and each supplier's quote stays private to you and them.
          </DialogDescription>
        </DialogHeader>

        <fieldset
          disabled={submitting || review || importing}
          className="space-y-4 overflow-y-auto flex-1 px-1"
        >
          <div className="space-y-1.5">
            <Label htmlFor="rfq-title">Title</Label>
            <Input
              id="rfq-title"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="e.g. Q1 antibiotics restock"
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="rfq-notes">Notes (optional)</Label>
            <Textarea
              id="rfq-notes"
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
              placeholder="Any context suppliers should know before quoting"
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="rfq-deadline">Response deadline (optional)</Label>
            <Input
              id="rfq-deadline"
              type="date"
              value={responseDeadline}
              onChange={(e) => setResponseDeadline(e.target.value)}
            />
          </div>

          <div className="space-y-2">
            <Label>Items ({items.length})</Label>
            <Input
              aria-label="Search request items"
              placeholder="Find a medicine in this request"
              value={itemQuery}
              onChange={(e) => {
                setItemQuery(e.target.value);
                setItemPage(0);
              }}
            />
            <details className="rounded border p-3">
              <summary>Import Excel/CSV or paste a table</summary>
              <p className="text-sm">
                Use Medicine, Quantity, Notes headers. Import adds rows; duplicates and invalid
                quantities must be resolved.
              </p>
              <Input
                aria-label="Import RFQ items"
                type="file"
                accept=".csv,.tsv,.xlsx,.xls"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) void importRows(file);
                  e.target.value = "";
                }}
              />
              <Textarea
                aria-label="Paste medicine table"
                placeholder={"Medicine\tQuantity\tNotes"}
                value={bulk}
                onChange={(e) => setBulk(e.target.value)}
              />
              <Button
                type="button"
                disabled={!bulk.trim() || importing}
                onClick={() => void importRows()}
              >
                Add pasted rows
              </Button>
            </details>
            {issues.size > 0 && (
              <p role="status" className="text-sm text-destructive">
                {issues.size} rows need attention. Search or page through the list to review them.
              </p>
            )}
            <div className="space-y-2">
              {visibleItems.map(({ item, index }) => (
                <div
                  key={index}
                  className="flex flex-wrap items-start gap-2 rounded-lg border border-border p-3"
                >
                  <span className="text-xs">{index + 1}</span>
                  {issues.has(index) && (
                    <p className="w-full text-xs text-destructive">{issues.get(index)}</p>
                  )}
                  <div className="min-w-[180px] flex-1 space-y-1">
                    <MedicationPicker
                      value={item.productName}
                      onChange={(productName) => updateItem(index, { productName })}
                    />
                  </div>
                  <div className="w-28 space-y-1">
                    <Input
                      type="number"
                      min={1}
                      value={item.quantity}
                      onChange={(e) => updateItem(index, { quantity: e.target.value })}
                      placeholder="Quantity"
                      aria-label="Quantity"
                    />
                  </div>
                  <div className="min-w-[160px] flex-1 space-y-1">
                    <Input
                      value={item.notes}
                      onChange={(e) => updateItem(index, { notes: e.target.value })}
                      placeholder="Notes (optional)"
                      aria-label="Item notes"
                    />
                  </div>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    disabled={items.length === 1}
                    onClick={() => removeItem(index)}
                    aria-label="Remove item"
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              ))}
            </div>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => {
                setItemQuery("");
                setItemPage(Math.floor(items.length / 25));
                setItems((prev) => [...prev, emptyItem()]);
              }}
            >
              <Plus className="mr-1 h-4 w-4" />
              Add item
            </Button>
            <div className="flex items-center gap-3">
              <Button
                type="button"
                variant="outline"
                disabled={currentItemPage === 0}
                onClick={() => setItemPage(currentItemPage - 1)}
              >
                Previous items
              </Button>
              <span>
                Page {currentItemPage + 1} of {Math.max(1, Math.ceil(indexedItems.length / 25))} ?{" "}
                {indexedItems.length} matching rows
              </span>
              <Button
                type="button"
                variant="outline"
                disabled={(currentItemPage + 1) * 25 >= indexedItems.length}
                onClick={() => setItemPage(currentItemPage + 1)}
              >
                Next items
              </Button>
            </div>
          </div>

          <div className="space-y-2">
            <Label>Send to</Label>
            <RadioGroup
              value={sendMode}
              onValueChange={(value) => setSendMode(value as "all" | "selected")}
              className="flex gap-4"
            >
              <label className="flex gap-2">
                <RadioGroupItem value="selected" />
                Select suppliers
              </label>
              <label className="flex gap-2">
                <RadioGroupItem value="all" />
                All eligible suppliers ({totalSuppliers})
              </label>
            </RadioGroup>
            {sendMode === "all" ? (
              <p>
                All {totalSuppliers} approved suppliers will receive this request. No individual
                selection is needed.
              </p>
            ) : (
              <>
                <div className="flex flex-wrap gap-2">
                  <Input
                    className="max-w-sm"
                    aria-label="Search suppliers"
                    placeholder="Search suppliers"
                    value={supplierQuery}
                    onChange={(e) => {
                      setSupplierQuery(e.target.value);
                      setSupplierPage(0);
                    }}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => {
                      setSelectedOnly(!selectedOnly);
                      setSupplierPage(0);
                      setSupplierQuery("");
                    }}
                  >
                    {selectedOnly
                      ? "Browse suppliers"
                      : `Review selected (${selectedWholesalers.length})`}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={supplierLoading || !!supplierError}
                    onClick={() =>
                      setSelectedWholesalers((prev) => [
                        ...new Set([...prev, ...shownWholesalers.map((w) => w.id)]),
                      ])
                    }
                  >
                    Select this page
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    onClick={() => {
                      setSelectedWholesalers([]);
                      setSupplierPage(0);
                    }}
                  >
                    Clear selection
                  </Button>
                </div>
                <p>{selectedWholesalers.length} suppliers selected</p>
                {supplierLoading ? (
                  <p role="status">Loading suppliers?</p>
                ) : supplierError ? (
                  <p role="alert">{supplierError}</p>
                ) : (
                  <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                    {shownWholesalers.map((w) => (
                      <label key={w.id} className="flex gap-2 rounded border p-2">
                        <Checkbox
                          checked={selectedWholesalers.includes(w.id)}
                          onCheckedChange={(checked) => toggleWholesaler(w.id, checked === true)}
                        />
                        {w.name}
                      </label>
                    ))}
                    {!shownWholesalers.length && <p>No suppliers match.</p>}
                  </div>
                )}
                <div className="flex gap-3 items-center">
                  <Button
                    type="button"
                    variant="outline"
                    disabled={supplierPage === 0 || supplierLoading}
                    onClick={() => setSupplierPage((p) => p - 1)}
                  >
                    Previous suppliers
                  </Button>
                  <span>
                    Page {supplierPage + 1} of {Math.max(1, Math.ceil(supplierCount / 20))}
                  </span>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={supplierLoading || (supplierPage + 1) * 20 >= supplierCount}
                    onClick={() => setSupplierPage((p) => p + 1)}
                  >
                    Next suppliers
                  </Button>
                </div>
              </>
            )}
          </div>

          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
        </fieldset>
        {review && (
          <div className="rounded border p-3" role="status">
            <strong>Review before sending: {title}</strong>
            <p>
              {items.length} medicines ? {items.reduce((sum, i) => sum + Number(i.quantity), 0)}{" "}
              total units ? {sendMode === "all" ? totalSuppliers : selectedWholesalers.length}{" "}
              suppliers ? Deadline: {responseDeadline || "None"}
            </p>
            <p>Sending shares this request with these suppliers.</p>
            <Button variant="outline" disabled={submitting} onClick={() => setReview(false)}>
              Back to edit
            </Button>
          </div>
        )}
        {review && error && (
          <p role="alert" className="text-destructive">
            {error}
          </p>
        )}
        <DialogFooter>
          <Button type="button" variant="outline" disabled={submitting} onClick={saveDraft}>
            Save draft on this device
          </Button>
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={submitting}
          >
            Cancel
          </Button>
          <Button
            type="button"
            onClick={() => void submit()}
            disabled={submitting || importing || supplierLoading || !!supplierError}
          >
            {submitting ? "Sending..." : review ? "Confirm and send request" : "Review request"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
