import { useEffect, useState } from "react";
import { ChevronDown, ChevronUp, Plus, Trash2 } from "lucide-react";
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
  const [showAllList, setShowAllList] = useState(false);
  const [supplierQuery, setSupplierQuery] = useState("");
  const [title, setTitle] = useState("");
  const [notes, setNotes] = useState("");
  const [responseDeadline, setResponseDeadline] = useState("");
  const [items, setItems] = useState<RfqItemDraft[]>([emptyItem()]);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) return;
    setTitle("");
    setNotes("");
    setResponseDeadline("");
    setItems([emptyItem()]);
    setSelectedWholesalers([]);
    setSendMode("selected");
    setShowAllList(false);
    setSupplierQuery("");
    setError(null);
    void supabase
      .from("businesses")
      .select("id, name")
      .eq("type", "wholesaler")
      .eq("verification_status", "approved")
      .order("name")
      .then(({ data }) => setWholesalers((data as WholesalerOption[] | null) ?? []));
  }, [open]);

  // "All eligible wholesalers" currently means every approved wholesaler account -- the same
  // gate create_rfq itself enforces. There's no active/suspended flag or coverage-area/
  // categories-supplied concept in the schema yet, so no further filtering is applied here; the
  // brief's own eligibility list is explicit that each extra criterion only applies "where data is
  // available" / "if such rules exist".
  const recipientIds = sendMode === "all" ? wholesalers.map((w) => w.id) : selectedWholesalers;
  const shownWholesalers = wholesalers.filter((w) =>
    w.name.toLowerCase().includes(supplierQuery.trim().toLowerCase()),
  );

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
    const { error: validationError, items: cleanItems } = validateRfqDraft({
      title,
      wholesalerIds: recipientIds,
      items,
      responseDeadline,
    });
    if (validationError || !cleanItems) {
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
    toast.success("Quote request sent");
    onOpenChange(false);
    onCreated();
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Request quotes</DialogTitle>
          <DialogDescription>
            Ask suppliers to quote on a list of items — pick specific ones or send to everyone
            eligible. Only the suppliers you send this to will see it, and each supplier's quote
            stays private to you and them.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
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
            <Label>Items</Label>
            <div className="space-y-2">
              {items.map((item, index) => (
                <div key={index} className="flex flex-wrap items-start gap-2 rounded-lg border border-border p-3">
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
            <Button type="button" variant="outline" size="sm" onClick={() => setItems((prev) => [...prev, emptyItem()])}>
              <Plus className="mr-1 h-4 w-4" />
              Add item
            </Button>
          </div>

          <div className="space-y-2">
            <Label>Send to</Label>
            {wholesalers.length === 0 ? (
              <p className="text-sm text-muted-foreground">No approved suppliers available yet.</p>
            ) : (
              <>
                <RadioGroup
                  value={sendMode}
                  onValueChange={(value) => setSendMode(value as "selected" | "all")}
                  className="flex flex-col gap-2 sm:flex-row sm:gap-4"
                >
                  <label className="flex items-center gap-2 text-sm">
                    <RadioGroupItem value="selected" />
                    Select specific suppliers
                  </label>
                  <label className="flex items-center gap-2 text-sm">
                    <RadioGroupItem value="all" />
                    All eligible suppliers
                  </label>
                </RadioGroup>

                {sendMode === "selected" ? (
                  <div className="space-y-2">
                    <div className="flex flex-wrap items-center gap-2">
                      <Input
                        value={supplierQuery}
                        onChange={(e) => setSupplierQuery(e.target.value)}
                        placeholder="Search suppliers"
                        aria-label="Search suppliers"
                        className="max-w-xs"
                      />
                      <span className="text-xs text-muted-foreground">
                        {selectedWholesalers.length} of {wholesalers.length} selected
                      </span>
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        onClick={() =>
                          setSelectedWholesalers((prev) => [
                            ...new Set([...prev, ...shownWholesalers.map((w) => w.id)]),
                          ])
                        }
                      >
                        Select shown
                      </Button>
                      <Button type="button" variant="ghost" size="sm" onClick={() => setSelectedWholesalers([])}>
                        Clear
                      </Button>
                    </div>
                    <div className="grid max-h-48 grid-cols-1 gap-2 overflow-y-auto rounded-lg border border-border p-3 sm:grid-cols-2">
                      {shownWholesalers.length === 0 && (
                        <p className="text-sm text-muted-foreground">No suppliers match your search.</p>
                      )}
                      {shownWholesalers.map((w) => (
                        <label key={w.id} className="flex items-center gap-2 text-sm">
                          <Checkbox
                            checked={selectedWholesalers.includes(w.id)}
                            onCheckedChange={(checked) => toggleWholesaler(w.id, checked === true)}
                          />
                          {w.name}
                        </label>
                      ))}
                    </div>
                  </div>
                ) : (
                  <div className="rounded-lg border border-border p-3">
                    <div className="flex items-center justify-between gap-2">
                      <p className="text-sm">
                        Send to <span className="font-medium">{wholesalers.length}</span> eligible
                        wholesaler{wholesalers.length === 1 ? "" : "s"}
                        {" "}— every approved supplier account on Drugxone right now.
                      </p>
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        onClick={() => setShowAllList((v) => !v)}
                      >
                        {showAllList ? "Hide list" : "View list"}
                        {showAllList ? <ChevronUp className="ml-1 h-3.5 w-3.5" /> : <ChevronDown className="ml-1 h-3.5 w-3.5" />}
                      </Button>
                    </div>
                    {showAllList && (
                      <ul className="mt-2 grid max-h-40 grid-cols-1 gap-1 overflow-y-auto border-t border-border pt-2 text-sm text-muted-foreground sm:grid-cols-2">
                        {wholesalers.map((w) => (
                          <li key={w.id}>{w.name}</li>
                        ))}
                      </ul>
                    )}
                  </div>
                )}
              </>
            )}
          </div>

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
            {submitting ? "Sending..." : "Send request"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
