import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
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
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import {
  PROMOTION_STATUS_LABELS,
  benefitsFromForm,
  createPromotion,
  dateFromInput,
  describeBenefits,
  fetchPromotions,
  reasonError,
  setPromotionActive,
  type PromotionRow,
  type PromotionStatus,
} from "@/lib/billing-controls";
import { dateText } from "@/lib/billing-invoices";

const tone: Record<PromotionStatus, string> = {
  running: "border-success/30 bg-success/15 text-success",
  off: "border-border bg-muted text-muted-foreground",
  not_started: "border-primary/30 bg-primary/10 text-primary",
  ended: "border-border bg-muted text-muted-foreground",
  full: "border-warning/30 bg-warning/15 text-warning-foreground",
};

const BENEFIT_FIELDS: { key: string; label: string; wholesalerOnly?: boolean }[] = [
  { key: "free_trial_days", label: "Extra free trial (days)" },
  { key: "free_orders", label: "Extra free orders", wholesalerOnly: true },
  { key: "subscription_discount_percent", label: "Subscription discount (%)" },
  { key: "discount_days", label: "…for how many days" },
  { key: "fee_percentage", label: "Lower platform fee (%)", wholesalerOnly: true },
  { key: "fee_days", label: "…for how many days", wholesalerOnly: true },
  { key: "fee_waiver_days", label: "No platform fee (days)", wholesalerOnly: true },
];

/** Promotions: bundles of benefits that an administrator gives to a business, once. Created here, applied from a business's page. */
export function AdminBillingPromotionsSection() {
  const [rows, setRows] = useState<PromotionRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [switching, setSwitching] = useState<PromotionRow | null>(null);

  const load = useCallback(async () => {
    try {
      setRows(await fetchPromotions());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load promotions.");
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="space-y-4" data-testid="admin-promotions">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="max-w-2xl text-sm text-muted-foreground">
          A promotion is a named bundle of benefits (extra trial days, free orders, a subscription
          discount, a lower or no platform fee for a while). It cannot be edited once created:
          switch it off and create another. Each business, owner and licence number can receive a
          promotion once. Apply one from a business's page under Organizations.
        </p>
        <Button onClick={() => setCreating(true)} data-testid="new-promotion">
          New promotion
        </Button>
      </div>
      {error && (
        <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
          {error}
        </Card>
      )}
      {!rows && !error && <Skeleton className="h-32" />}
      {rows && (
        <Card className="overflow-x-auto p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Code</TableHead>
                <TableHead>For</TableHead>
                <TableHead>Gives</TableHead>
                <TableHead>Valid</TableHead>
                <TableHead className="text-right">Given</TableHead>
                <TableHead>Status</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.length === 0 && (
                <TableRow>
                  <TableCell colSpan={7} className="py-8 text-center text-muted-foreground">
                    No promotions yet.
                  </TableCell>
                </TableRow>
              )}
              {rows.map((p) => (
                <TableRow key={p.id} data-testid="promotion-row">
                  <TableCell className="whitespace-nowrap font-medium">
                    {p.code}
                    <span className="block text-xs font-normal text-muted-foreground">
                      {p.name}
                    </span>
                  </TableCell>
                  <TableCell>
                    {p.business_type === "wholesaler" ? "Wholesalers" : "Pharmacies"}
                  </TableCell>
                  <TableCell className="text-sm">
                    {describeBenefits(p.benefits).join("; ")}
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-sm">
                    {dateText(p.valid_from)} – {p.valid_until ? dateText(p.valid_until) : "no end"}
                  </TableCell>
                  <TableCell className="text-right">
                    {p.redeemed}
                    {p.max_redemptions !== null ? ` / ${p.max_redemptions}` : ""}
                  </TableCell>
                  <TableCell>
                    <Badge variant="outline" className={tone[p.status]}>
                      {PROMOTION_STATUS_LABELS[p.status]}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-right">
                    <Button variant="outline" size="sm" onClick={() => setSwitching(p)}>
                      {p.active ? "Switch off" : "Switch on"}
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Card>
      )}
      <CreateDialog
        open={creating}
        onClose={() => setCreating(false)}
        onDone={() => {
          setCreating(false);
          void load();
        }}
      />
      <SwitchDialog
        promotion={switching}
        onClose={() => setSwitching(null)}
        onDone={() => {
          setSwitching(null);
          void load();
        }}
      />
    </div>
  );
}

function CreateDialog({
  open,
  onClose,
  onDone,
}: {
  open: boolean;
  onClose: () => void;
  onDone: () => void;
}) {
  const [v, setV] = useState<Record<string, string>>({ type: "wholesaler" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (open) {
      setV({ type: "wholesaler" });
      setError(null);
    }
  }, [open]);
  const set = (k: string, x: string) => setV((s) => ({ ...s, [k]: x }));

  const submit = async () => {
    const reasonProblem = reasonError(v.reason ?? "");
    if (reasonProblem) return setError(reasonProblem);
    const { benefits, error: bErr } = benefitsFromForm(v);
    if (bErr) return setError(bErr);
    const max = (v.max ?? "").trim();
    if (max !== "" && !/^\d+$/.test(max))
      return setError("The limit must be a whole number, or empty for no limit.");
    setBusy(true);
    setError(null);
    try {
      await createPromotion({
        code: v.code ?? "",
        name: v.name ?? "",
        description: v.description ?? "",
        businessType: v.type as "pharmacy" | "wholesaler",
        benefits,
        validFrom: v.from ? dateFromInput(v.from) : null,
        validUntil: v.until ? dateFromInput(v.until) : null,
        maxRedemptions: max === "" ? null : Number(max),
        reason: (v.reason ?? "").trim(),
      });
      toast.success("Promotion created.");
      onDone();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not create the promotion.");
    } finally {
      setBusy(false);
    }
  };

  const fields = BENEFIT_FIELDS.filter((f) => v.type === "wholesaler" || !f.wholesalerOnly);
  return (
    <Dialog open={open} onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>New promotion</DialogTitle>
          <DialogDescription>
            Choose what it gives. Leave a benefit empty to leave it out. It cannot be changed
            afterwards.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          <div className="grid gap-1">
            <Label htmlFor="pr-code">Code</Label>
            <Input
              id="pr-code"
              value={v.code ?? ""}
              onChange={(e) => set("code", e.target.value)}
              placeholder="DRUGXONE-LAUNCH"
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pr-name">Name</Label>
            <Input
              id="pr-name"
              value={v.name ?? ""}
              onChange={(e) => set("name", e.target.value)}
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pr-type">For</Label>
            <Select value={v.type} onValueChange={(x) => set("type", x)}>
              <SelectTrigger id="pr-type">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="wholesaler">Wholesalers</SelectItem>
                <SelectItem value="pharmacy">Pharmacies</SelectItem>
              </SelectContent>
            </Select>
          </div>
          {fields.map((f) => (
            <div key={f.key} className="grid gap-1">
              <Label htmlFor={`pr-${f.key}`}>{f.label}</Label>
              <Input
                id={`pr-${f.key}`}
                inputMode="decimal"
                value={v[f.key] ?? ""}
                onChange={(e) => set(f.key, e.target.value)}
              />
            </div>
          ))}
          <div className="grid grid-cols-2 gap-3">
            <div className="grid gap-1">
              <Label htmlFor="pr-from">Valid from (optional)</Label>
              <Input
                id="pr-from"
                type="date"
                value={v.from ?? ""}
                onChange={(e) => set("from", e.target.value)}
              />
            </div>
            <div className="grid gap-1">
              <Label htmlFor="pr-until">Valid until (optional)</Label>
              <Input
                id="pr-until"
                type="date"
                value={v.until ?? ""}
                onChange={(e) => set("until", e.target.value)}
              />
            </div>
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pr-max">Most businesses that may receive it (optional)</Label>
            <Input
              id="pr-max"
              inputMode="numeric"
              value={v.max ?? ""}
              onChange={(e) => set("max", e.target.value)}
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pr-desc">Description (optional)</Label>
            <Input
              id="pr-desc"
              value={v.description ?? ""}
              onChange={(e) => set("description", e.target.value)}
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pr-reason">Reason (kept in the audit trail)</Label>
            <Textarea
              id="pr-reason"
              rows={2}
              value={v.reason ?? ""}
              onChange={(e) => set("reason", e.target.value)}
            />
          </div>
          {error && (
            <p className="text-sm text-destructive" role="alert" data-testid="promotion-error">
              {error}
            </p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void submit()} disabled={busy} data-testid="promotion-create">
            {busy ? "Creating…" : "Create promotion"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function SwitchDialog({
  promotion,
  onClose,
  onDone,
}: {
  promotion: PromotionRow | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setReason("");
    setError(null);
  }, [promotion?.id]);
  if (!promotion) return null;
  const submit = async () => {
    const problem = reasonError(reason);
    if (problem) return setError(problem);
    setBusy(true);
    try {
      await setPromotionActive(promotion.id, !promotion.active, reason.trim());
      toast.success(promotion.active ? "Promotion switched off." : "Promotion switched on.");
      onDone();
    } catch (e) {
      setError(e instanceof Error ? e.message : "That could not be done.");
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog open onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {promotion.active ? "Switch off" : "Switch on"} {promotion.code}?
          </DialogTitle>
          <DialogDescription>
            {promotion.active
              ? "No business can receive it while it is off. Businesses that already have it keep it."
              : "Businesses can receive it again, within its dates and limit."}
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-1">
          <Label htmlFor="sw-reason">Reason (kept in the audit trail)</Label>
          <Textarea
            id="sw-reason"
            rows={2}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </div>
        {error && (
          <p className="text-sm text-destructive" role="alert">
            {error}
          </p>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void submit()} disabled={busy}>
            {busy ? "Working…" : promotion.active ? "Switch off" : "Switch on"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
