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
import { Textarea } from "@/components/ui/textarea";

/** Asks for one piece of text (a reason, a response or a date) before an action goes ahead. */
export function RfqReasonDialog({
  title,
  description,
  label,
  placeholder,
  confirmLabel,
  destructive = false,
  inputType = "textarea",
  minLength = 1,
  busy,
  onSubmit,
  onClose,
}: {
  title: string;
  description?: string;
  label: string;
  placeholder?: string;
  confirmLabel: string;
  destructive?: boolean;
  inputType?: "textarea" | "datetime-local";
  /** The shortest text accepted, for reasons that are recorded and must say something specific. */
  minLength?: number;
  busy: boolean;
  onSubmit: (value: string) => Promise<boolean>;
  onClose: () => void;
}) {
  const [value, setValue] = useState("");
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          {description && <DialogDescription>{description}</DialogDescription>}
        </DialogHeader>
        <label className="block space-y-1.5">
          <span className="text-sm font-medium">{label}</span>
          {inputType === "datetime-local" ? (
            <Input type="datetime-local" value={value} onChange={(e) => setValue(e.target.value)} />
          ) : (
            <Textarea
              rows={3}
              placeholder={placeholder}
              value={value}
              onChange={(e) => setValue(e.target.value)}
            />
          )}
          {minLength > 1 && (
            <span className="block text-xs text-muted-foreground tabular-nums">
              {value.trim().length} of at least {minLength} characters
            </span>
          )}
        </label>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            type="button"
            variant={destructive ? "destructive" : "default"}
            disabled={busy || value.trim().length < minLength}
            onClick={async () => {
              if (await onSubmit(value.trim())) onClose();
            }}
          >
            {confirmLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
