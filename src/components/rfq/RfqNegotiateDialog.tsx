import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";

const TERMS: Record<
  string,
  { label: string; help: string; type: string; min?: string; step?: string }
> = {
  price: {
    label: "Unit price",
    help: "The unit price in GHS you want.",
    type: "number",
    min: "0.01",
    step: "0.01",
  },
  quantity: {
    label: "Quantity",
    help: "The quantity you want.",
    type: "number",
    min: "1",
    step: "1",
  },
  delivery: {
    label: "Delivery date or fee",
    help: "The delivery date or fee you want.",
    type: "date",
  },
  credit: {
    label: "Payment terms",
    help: "The payment terms you want, in a few words.",
    type: "text",
  },
  substitution: {
    label: "Product substitution",
    help: "The substitution you are asking for, in a few words.",
    type: "text",
  },
};

/** Ask one supplier to revise a single commercial term on its quotation. */
export function RfqNegotiateDialog({
  supplier,
  busy,
  onSubmit,
  onClose,
}: {
  supplier: string;
  busy: boolean;
  onSubmit: (term: string, value: string) => Promise<boolean>;
  onClose: () => void;
}) {
  const [term, setTerm] = useState("price");
  const [value, setValue] = useState("");
  const spec = TERMS[term];
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Ask {supplier} for revised terms</DialogTitle>
          <DialogDescription>
            The supplier can accept, counter or reject. Nothing changes until it responds.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4">
          <label className="block space-y-1.5">
            <span className="text-sm font-medium">What should change?</span>
            <select
              aria-label="Negotiation term"
              className="h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm"
              value={term}
              onChange={(e) => {
                setTerm(e.target.value);
                setValue("");
              }}
            >
              {Object.entries(TERMS).map(([key, t]) => (
                <option key={key} value={key}>
                  {t.label}
                </option>
              ))}
            </select>
          </label>
          <label className="block space-y-1.5">
            <span className="text-sm font-medium">{spec.label}</span>
            <Input
              type={spec.type}
              min={spec.min}
              step={spec.step}
              value={value}
              onChange={(e) => setValue(e.target.value)}
            />
            <span className="block text-xs text-muted-foreground">{spec.help}</span>
          </label>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            type="button"
            disabled={busy || !value.trim()}
            onClick={async () => {
              if (await onSubmit(term, value.trim())) onClose();
            }}
          >
            Send request
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
