import { useEffect, useMemo, useState } from "react";
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
import { Textarea } from "@/components/ui/textarea";
import { fetchPlans, type PlanRow } from "@/lib/billing";
import { dateFromInput, reasonError } from "@/lib/billing-controls";
import {
  SUBSCRIPTION_MODE_LABELS,
  fetchUnsubscribedBusinesses,
  plansFor,
  startSubscription,
  type SubscriptionModeChoice,
  type UnsubscribedBusiness,
} from "@/lib/billing-plans";

const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

/** Puts an approved business that has no subscription on a plan, in shadow, off, or following the platform setting. */
export function StartSubscriptionDialog({
  open,
  onClose,
  onDone,
}: {
  open: boolean;
  onClose: () => void;
  onDone: () => void;
}) {
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<UnsubscribedBusiness[] | null>(null);
  const [business, setBusiness] = useState<UnsubscribedBusiness | null>(null);
  const [plans, setPlans] = useState<PlanRow[]>([]);
  const [planCode, setPlanCode] = useState("");
  const [mode, setMode] = useState<SubscriptionModeChoice>("shadow");
  const [date, setDate] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [listError, setListError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setSearch("");
    setQuery("");
    setBusiness(null);
    setPlanCode("");
    setMode("shadow");
    setDate("");
    setReason("");
    setError(null);
    fetchPlans()
      .then(setPlans)
      .catch(() => setPlans([]));
  }, [open]);

  useEffect(() => {
    const t = window.setTimeout(() => setQuery(search.trim()), 300);
    return () => window.clearTimeout(t);
  }, [search]);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setFound(null);
    setListError(null);
    fetchUnsubscribedBusinesses(query)
      .then((r) => {
        if (!cancelled) setFound(r);
      })
      .catch((e) => {
        if (!cancelled) {
          setFound([]);
          setListError(errText(e, "Could not load the businesses."));
        }
      });
    return () => {
      cancelled = true;
    };
  }, [open, query]);

  const choices = useMemo(
    () => (business ? plansFor(plans, business.type) : []),
    [plans, business],
  );

  const submit = async () => {
    if (!business) return setError("Choose the business.");
    if (!planCode) return setError("Choose the plan.");
    const problem = reasonError(reason);
    if (problem) return setError(problem);
    let startsAt: Date | null = null;
    if (date) {
      startsAt = dateFromInput(date);
      if (!startsAt) return setError("Choose a valid start date.");
    }
    setBusy(true);
    setError(null);
    try {
      const r = await startSubscription({
        businessId: business.id,
        planCode,
        startsAt,
        mode,
        reason: reason.trim(),
      });
      toast.success(
        `${business.name} is on ${planCode}${
          r.launch_grant === "granted" ? " with its launch free orders" : ""
        }.`,
      );
      onDone();
    } catch (e) {
      setError(errText(e, "Could not start the subscription."));
    } finally {
      setBusy(false);
    }
  };

  if (!open) return null;
  return (
    <Dialog open onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Start a subscription</DialogTitle>
          <DialogDescription>
            Puts an approved business on a plan. Start it in shadow to record what it would be
            charged without charging anything; real billing begins only when you put it live.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          <div className="grid gap-1">
            <Label htmlFor="ss-search">Business (approved, not on a plan yet)</Label>
            {business ? (
              <div className="flex items-center justify-between gap-2 rounded-md border px-3 py-2 text-sm">
                <span>
                  <span className="font-medium">{business.name}</span>{" "}
                  <span className="capitalize text-muted-foreground">{business.type}</span>
                </span>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setBusiness(null);
                    setPlanCode("");
                  }}
                >
                  Change
                </Button>
              </div>
            ) : (
              <>
                <Input
                  id="ss-search"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Search by name…"
                />
                <div
                  className="max-h-48 overflow-y-auto rounded-md border"
                  data-testid="subscription-candidates"
                >
                  {!found && <Skeleton className="h-16" />}
                  {listError && (
                    <p
                      className="p-3 text-sm text-destructive"
                      role="alert"
                      data-testid="candidates-error"
                    >
                      {listError}
                    </p>
                  )}
                  {found && found.length === 0 && !listError && (
                    <p className="p-3 text-sm text-muted-foreground">
                      No approved business without a plan matches.
                    </p>
                  )}
                  {found?.map((b) => (
                    <button
                      key={b.id}
                      type="button"
                      className="flex w-full items-center justify-between gap-2 border-b px-3 py-2 text-left text-sm last:border-b-0 hover:bg-muted/50"
                      onClick={() => {
                        setBusiness(b);
                        setPlanCode("");
                        setError(null);
                      }}
                    >
                      <span className="font-medium">{b.name}</span>
                      <span className="capitalize text-muted-foreground">{b.type}</span>
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
          <div className="grid gap-1">
            <Label htmlFor="ss-plan">Plan</Label>
            <Select value={planCode} onValueChange={setPlanCode} disabled={!business}>
              <SelectTrigger id="ss-plan">
                <SelectValue placeholder={business ? "Choose…" : "Choose the business first"} />
              </SelectTrigger>
              <SelectContent>
                {choices.map((p) => (
                  <SelectItem key={p.code} value={p.code}>
                    {p.name} ({p.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {business && choices.length === 0 && (
              <p className="text-xs text-muted-foreground">
                No plan for {business.type}s is switched on with a published version. Set one up
                under Plans first.
              </p>
            )}
          </div>
          <div className="grid gap-1">
            <Label htmlFor="ss-mode">Billing mode</Label>
            <Select value={mode} onValueChange={(v) => setMode(v as SubscriptionModeChoice)}>
              <SelectTrigger id="ss-mode">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {(Object.keys(SUBSCRIPTION_MODE_LABELS) as SubscriptionModeChoice[]).map((m) => (
                  <SelectItem key={m} value={m}>
                    {SUBSCRIPTION_MODE_LABELS[m]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="grid gap-1">
            <Label htmlFor="ss-date">Billing starts on (optional; empty means now)</Label>
            <Input
              id="ss-date"
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="ss-reason">Reason (kept in the audit trail)</Label>
            <Textarea
              id="ss-reason"
              rows={2}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
            />
          </div>
          {error && (
            <p className="text-sm text-destructive" role="alert" data-testid="subscription-error">
              {error}
            </p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void submit()} disabled={busy} data-testid="subscription-submit">
            {busy ? "Working…" : "Start subscription"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
