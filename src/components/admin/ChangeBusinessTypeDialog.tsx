import { useEffect, useState } from "react";
import { ArrowLeftRight, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  OTHER_REASON,
  TYPE_CHANGE_REASONS,
  businessTypeLabel,
  changeBusinessType,
  describeBlockers,
  fetchTypeChangeBlockers,
  otherBusinessType,
  resolveTypeChangeReason,
  type BusinessType,
  type TypeChangeBlocker,
} from "@/lib/business-type-change";

type Props = {
  businessId: string;
  businessName: string;
  currentType: BusinessType;
  verificationStatus: "pending" | "approved" | "rejected";
  onChanged: () => void | Promise<void>;
};

/**
 * Admin-only correction for a business that registered as the wrong type. A business that
 * already has any data cannot be switched (enforced in the database); a business that needs to
 * be both should register a second business of the other type under the same login.
 */
export function ChangeBusinessTypeDialog({
  businessId,
  businessName,
  currentType,
  verificationStatus,
  onChanged,
}: Props) {
  const [open, setOpen] = useState(false);
  const [blockers, setBlockers] = useState<TypeChangeBlocker[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reasonChoice, setReasonChoice] = useState<string>(TYPE_CHANGE_REASONS[0].value);
  const [otherReason, setOtherReason] = useState("");
  const [busy, setBusy] = useState(false);
  const reason = resolveTypeChangeReason(reasonChoice, otherReason);
  const newType = otherBusinessType(currentType);

  useEffect(() => {
    if (!open) {
      return;
    }

    let cancelled = false;
    setBlockers(null);
    setLoadError(null);
    setReasonChoice(TYPE_CHANGE_REASONS[0].value);
    setOtherReason("");

    void fetchTypeChangeBlockers(businessId).then((result) => {
      if (cancelled) {
        return;
      }
      setBlockers(result.blockers);
      setLoadError(result.error);
    });

    return () => {
      cancelled = true;
    };
  }, [open, businessId]);

  const confirm = async () => {
    if (!reason) {
      toast.error("Write the reason for this change");
      return;
    }

    setBusy(true);
    const { error } = await changeBusinessType(businessId, newType, reason);
    setBusy(false);

    if (error) {
      toast.error(error);
      return;
    }

    toast.success(`${businessName} is now a ${businessTypeLabel(newType).toLowerCase()}`);
    setOpen(false);
    await onChanged();
  };

  const blocked = describeBlockers(blockers ?? []);
  const loading = blockers === null && loadError === null;

  return (
    <>
      <Button variant="ghost" size="sm" onClick={() => setOpen(true)}>
        <ArrowLeftRight className="h-4 w-4" /> Change type
      </Button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Change type of {businessName}</DialogTitle>
            <DialogDescription>
              Switch this business from {businessTypeLabel(currentType).toLowerCase()} to{" "}
              {businessTypeLabel(newType).toLowerCase()}. Use this only to fix a business that
              signed up as the wrong type.
            </DialogDescription>
          </DialogHeader>

          {loading ? (
            <p role="status" className="text-sm text-muted-foreground">
              Checking whether this business has any data...
            </p>
          ) : loadError ? (
            <p role="alert" className="text-sm text-destructive">
              Could not check this business: {loadError}
            </p>
          ) : blocked.length > 0 ? (
            <div role="alert" className="space-y-2 text-sm">
              <p className="text-destructive">
                This business already has data, so its type cannot be changed.
              </p>
              <ul className="list-disc pl-5 text-muted-foreground">
                {blocked.map((item) => (
                  <li key={item.label}>
                    {item.label}: {item.count.toLocaleString("en-GB")}
                    {item.capped ? "+" : ""}
                  </li>
                ))}
              </ul>
              <p className="text-muted-foreground">
                If this business needs to be both, register a second business of the other type
                under the same login instead.
              </p>
            </div>
          ) : (
            <div className="space-y-3">
              {verificationStatus === "approved" && (
                <p className="rounded-md border border-warning/40 p-3 text-sm">
                  This business is approved. After the switch it goes back to pending, because the
                  required documents differ for a {businessTypeLabel(newType).toLowerCase()}. You
                  can approve it again once its documents are in order.
                </p>
              )}
              <div className="space-y-2">
                <Label htmlFor={`type-change-reason-${businessId}`}>Reason</Label>
                <Select value={reasonChoice} onValueChange={setReasonChoice}>
                  <SelectTrigger id={`type-change-reason-${businessId}`}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {TYPE_CHANGE_REASONS.map((option) => (
                      <SelectItem key={option.value} value={option.value}>
                        {option.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {reasonChoice === OTHER_REASON && (
                  <Textarea
                    aria-label="Other reason"
                    value={otherReason}
                    onChange={(event) => setOtherReason(event.target.value)}
                    placeholder="Tell us why this business is being switched"
                    maxLength={500}
                  />
                )}
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>
              Cancel
            </Button>
            <Button
              variant="hero"
              onClick={confirm}
              disabled={busy || loading || Boolean(loadError) || blocked.length > 0 || !reason}
            >
              {busy && <Loader2 className="h-4 w-4 animate-spin" />} Change to{" "}
              {businessTypeLabel(newType)}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
