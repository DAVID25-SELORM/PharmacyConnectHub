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
import { Textarea } from "@/components/ui/textarea";

/** A dialog with one text box (a reason, a question, a reply). The caller decides what the text is for. */
export function TextDialog({
  title,
  description,
  label,
  submitLabel,
  required = false,
  busy,
  onClose,
  onSubmit,
}: {
  title: string;
  description: string;
  label: string;
  submitLabel: string;
  required?: boolean;
  busy: boolean;
  onClose: () => void;
  onSubmit: (text: string) => void | Promise<void>;
}) {
  const [text, setText] = useState("");
  const missing = required && text.trim().length < 3;
  return (
    <Dialog open onOpenChange={(next) => !next && !busy && onClose()}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>
        <label className="block text-sm font-medium">
          {label}
          <Textarea
            className="mt-1"
            rows={3}
            maxLength={500}
            value={text}
            onChange={(event) => setText(event.target.value)}
          />
        </label>
        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
            Cancel
          </Button>
          <Button
            type="button"
            variant="hero"
            disabled={busy || missing}
            onClick={() => void onSubmit(text.trim())}
          >
            {busy ? "Working…" : submitLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
