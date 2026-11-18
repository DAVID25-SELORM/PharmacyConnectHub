import { useState } from "react";
import { Hospital, Loader2, Store } from "lucide-react";
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
import { isHospitalOrClinic } from "@/lib/business-kind";
import { setFacilityKind, type BusinessType } from "@/lib/business-type-change";

type Props = {
  businessId: string;
  businessName: string;
  currentType: BusinessType;
  facilityKind: "hospital_clinic" | null | undefined;
  onChanged: () => void | Promise<void>;
};

/**
 * Admin-only. Marks a pharmacy-type business as a hospital or clinic (or back to a plain
 * pharmacy). It is a label: the business keeps its orders, stock and approval as they are.
 */
export function FacilityKindButton({
  businessId,
  businessName,
  currentType,
  facilityKind,
  onChanged,
}: Props) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);

  if (currentType !== "pharmacy") {
    return null;
  }

  const isFacility = isHospitalOrClinic({ type: currentType, facility_kind: facilityKind });
  const target = isFacility ? null : "hospital_clinic";

  const confirm = async () => {
    setBusy(true);
    const { error } = await setFacilityKind(businessId, target);
    setBusy(false);

    if (error) {
      toast.error(error);
      return;
    }

    toast.success(
      target ? `${businessName} is now a hospital / clinic` : `${businessName} is now a pharmacy`,
    );
    setOpen(false);
    await onChanged();
  };

  return (
    <>
      <Button variant="ghost" size="sm" onClick={() => setOpen(true)}>
        {isFacility ? <Store className="h-4 w-4" /> : <Hospital className="h-4 w-4" />}
        {isFacility ? "Mark as pharmacy" : "Mark as hospital / clinic"}
      </Button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {isFacility ? "Mark as a pharmacy?" : "Mark as a hospital / clinic?"}
            </DialogTitle>
            <DialogDescription>
              {businessName} will be shown as a {isFacility ? "pharmacy" : "hospital / clinic"}. It
              keeps its approval, orders, stock and RFQs. Only the label changes.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={busy}>
              Cancel
            </Button>
            <Button variant="hero" onClick={confirm} disabled={busy}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />} Confirm
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
