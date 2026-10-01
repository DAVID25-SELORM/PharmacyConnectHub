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
    setError(null);
    void supabase
      .from("businesses")
      .select("id, name")
      .eq("type", "wholesaler")
      .eq("verification_status", "approved")
      .order("name")
      .then(({ data }) => setWholesalers((data as WholesalerOption[] | null) ?? []));
  }, [open]);

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
      wholesalerIds: selectedWholesalers,
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
      p_wholesaler_ids: selectedWholesalers,
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
            Ask specific suppliers to quote on a list of items. Only the suppliers you invite will
            see this request, and each supplier's quote stays private to you and them.
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
                    <Input
                      value={item.productName}
                      onChange={(e) => updateItem(index, { productName: e.target.value })}
                      placeholder="Product name"
                      aria-label="Product name"
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
            <Label>Invite suppliers</Label>
            {wholesalers.length === 0 ? (
              <p className="text-sm text-muted-foreground">No approved suppliers available yet.</p>
            ) : (
              <div className="grid max-h-48 grid-cols-1 gap-2 overflow-y-auto rounded-lg border border-border p-3 sm:grid-cols-2">
                {wholesalers.map((w) => (
                  <label key={w.id} className="flex items-center gap-2 text-sm">
                    <Checkbox
                      checked={selectedWholesalers.includes(w.id)}
                      onCheckedChange={(checked) => toggleWholesaler(w.id, checked === true)}
                    />
                    {w.name}
                  </label>
                ))}
              </div>
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
