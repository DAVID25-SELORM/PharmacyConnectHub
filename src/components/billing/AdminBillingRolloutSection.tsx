import { useCallback, useEffect, useState } from "react";
import { CheckCircle2, CircleAlert, XCircle } from "lucide-react";
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
import { formatGHS } from "@/lib/format";
import { fetchAdminBillingOrganizations, type OrganizationRow } from "@/lib/billing";
import { dateFromInput, reasonError } from "@/lib/billing-controls";
import { dateText } from "@/lib/billing-invoices";
import {
  ACTIVATION_PHRASE,
  ENFORCEMENT_LABELS,
  NOTICE_EVENT_LABELS,
  NOTICE_LABELS,
  activatePlatform,
  blockers,
  canActivate,
  fetchReadiness,
  fetchRolloutStatus,
  goLiveBusiness,
  rolloutStage,
  setEnforcement,
  setGraceDays,
  setNotificationSettings,
  shadowSummary,
  type NotificationSettings,
  type Readiness,
  type RolloutStatus,
} from "@/lib/billing-rollout";

import { PlatformModeCard } from "./PlatformModeCard";

const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

const stageTone = {
  live: "border-success/30 bg-success/15 text-success",
  scheduled: "border-primary/30 bg-primary/10 text-primary",
  held: "border-warning/30 bg-warning/15 text-warning-foreground",
  off: "border-border bg-muted text-muted-foreground",
  ended: "border-border bg-muted text-muted-foreground",
} as const;

function Stat({
  label,
  value,
  hint,
  tone,
}: {
  label: string;
  value: string;
  hint?: string;
  tone?: string;
}) {
  return (
    <Card className={`p-4 ${tone ?? ""}`}>
      <div className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </div>
      <div className="mt-1 font-display text-xl font-bold">{value}</div>
      {hint && <div className="mt-0.5 text-xs text-muted-foreground">{hint}</div>}
    </Card>
  );
}

/** Going live: where the rollout stands, the checklist before real billing is switched on, putting businesses live one by one, and the policies that apply once it is. */
export function AdminBillingRolloutSection() {
  const [status, setStatus] = useState<RolloutStatus | null>(null);
  const [readiness, setReadiness] = useState<Readiness | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [s, r] = await Promise.all([fetchRolloutStatus(), fetchReadiness()]);
      setStatus(s);
      setReadiness(r);
      setError(null);
    } catch (e) {
      setError(errText(e, "Could not load the rollout."));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  if (error)
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  if (!status || !readiness) return <Skeleton className="h-60" />;
  const active = status.platform.mode === "active";

  return (
    <div className="space-y-6" data-testid="billing-rollout">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stat
          label="Real billing"
          value={active ? "On" : status.platform.mode === "shadow" ? "Shadow only" : "Off"}
          hint={active ? "Businesses are live one at a time" : "Nothing is charged"}
          tone={active ? "border-success/30" : ""}
        />
        <Stat
          label="Scheduled run"
          value={status.run.last_run_at ? `${status.run.minutes_since} min ago` : "Never run"}
          hint={status.run.stale ? "It has stopped: check the schedule" : `${status.run.runs} runs`}
          tone={status.run.stale ? "border-destructive/40" : ""}
        />
        <Stat
          label="Businesses live"
          value={`${status.counts.live}`}
          hint={`${status.counts.held_back} held back in shadow · ${status.counts.disabled} off`}
        />
        <Stat
          label="Unpaid invoices"
          value={formatGHS(status.counts.overdue_amount)}
          hint={`${status.counts.overdue_invoices} overdue · ${status.counts.past_due + status.counts.grace_period} past due · ${status.counts.suspended} suspended`}
        />
      </div>

      <PlatformModeCard status={status} onChanged={load} />
      {!active && <ActivationCard readiness={readiness} onDone={load} />}
      {active && <PilotTable onChanged={load} />}
      <PolicyCard status={status} onChanged={load} />
      <NoticesCard status={status} onChanged={load} />

      {status.recent_notices.length > 0 && (
        <Card className="space-y-2 p-4" data-testid="recent-notices">
          <h3 className="font-semibold">Recent notices</h3>
          <ul className="divide-y text-sm">
            {status.recent_notices.map((n, i) => (
              <li key={`${n.sent_at}-${i}`} className="flex flex-wrap justify-between gap-2 py-1.5">
                <span>
                  {NOTICE_EVENT_LABELS[n.event_type] ?? n.event_type}
                  {n.business_name ? ` · ${n.business_name}` : ""}
                </span>
                <span className="text-muted-foreground">
                  {n.recipients} {n.recipients === 1 ? "person" : "people"} · {dateText(n.sent_at)}
                </span>
              </li>
            ))}
          </ul>
        </Card>
      )}
    </div>
  );
}

function ActivationCard({ readiness, onDone }: { readiness: Readiness; onDone: () => void }) {
  const [holdBack, setHoldBack] = useState(true);
  const [phrase, setPhrase] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const stuck = blockers(readiness);

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await activatePlatform(holdBack, phrase, reason.trim());
      toast.success(
        `Real billing is on. ${r.held_back} businesses held back in shadow, ${r.live} live.`,
      );
      onDone();
    } catch (e) {
      setError(errText(e, "Could not switch real billing on."));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card className="space-y-4 p-4" data-testid="activation-card">
      <div>
        <h3 className="font-semibold">Before real billing is switched on</h3>
        <p className="text-xs text-muted-foreground">
          Items marked "must" stop the switch until they pass. The rest are advice.
        </p>
      </div>
      <ul className="space-y-2 text-sm">
        {readiness.checks.map((c) => (
          <li key={c.key} className="flex items-start gap-2" data-testid="readiness-check">
            {c.ok ? (
              <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" aria-label="ok" />
            ) : c.blocking ? (
              <XCircle
                className="mt-0.5 h-4 w-4 shrink-0 text-destructive"
                aria-label="not ready"
              />
            ) : (
              <CircleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-label="advice" />
            )}
            <div>
              <span className="font-medium">{c.label}</span>
              {c.blocking && <span className="ml-2 text-xs text-muted-foreground">must</span>}
              {c.detail && <div className="text-xs text-muted-foreground">{c.detail}</div>}
            </div>
          </li>
        ))}
      </ul>
      <p className="text-sm text-muted-foreground" data-testid="shadow-summary">
        {shadowSummary(readiness.shadow)}
        {readiness.shadow.since
          ? ` Estimated fees and subscriptions: ${formatGHS(readiness.shadow.estimated_revenue)} (not charged).`
          : ""}
      </p>
      <div className="space-y-3 rounded-md border p-3">
        <label className="flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            checked={holdBack}
            onChange={(e) => setHoldBack(e.target.checked)}
            className="mt-1"
          />
          <span>
            <span className="font-medium">Hold every business back in shadow (recommended)</span>
            <span className="block text-xs text-muted-foreground">
              Real billing is switched on, but nobody is charged until you put businesses live one
              by one. Without this every subscribed business goes live now.
            </span>
          </span>
        </label>
        <div className="grid gap-1">
          <Label htmlFor="act-phrase">Type {ACTIVATION_PHRASE} to confirm</Label>
          <Input
            id="act-phrase"
            value={phrase}
            onChange={(e) => setPhrase(e.target.value)}
            autoComplete="off"
          />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="act-why">Reason (kept in the audit trail)</Label>
          <Textarea
            id="act-why"
            rows={2}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </div>
        {stuck.length > 0 && (
          <p className="text-sm text-destructive" data-testid="activation-blockers">
            Not ready yet: {stuck.join("; ")}.
          </p>
        )}
        {error && (
          <p className="text-sm text-destructive" role="alert" data-testid="activation-error">
            {error}
          </p>
        )}
        <Button
          onClick={() => void submit()}
          disabled={busy || !canActivate({ ready: readiness.ready, phrase, reason })}
          data-testid="activate-billing"
        >
          {busy ? "Switching on…" : "Switch real billing on"}
        </Button>
      </div>
    </Card>
  );
}

function PilotTable({ onChanged }: { onChanged: () => void }) {
  const [rows, setRows] = useState<OrganizationRow[] | null>(null);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [going, setGoing] = useState<OrganizationRow | null>(null);

  const load = useCallback(async () => {
    try {
      const r = await fetchAdminBillingOrganizations({
        flavor: "real",
        search: query,
        limit: 100,
        offset: 0,
      });
      setRows(r.rows);
      setError(null);
    } catch (e) {
      setError(errText(e, "Could not load the businesses."));
    }
  }, [query]);
  useEffect(() => {
    void load();
  }, [load]);

  return (
    <Card className="space-y-3 p-4" data-testid="pilot-table">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h3 className="font-semibold">Put businesses live</h3>
          <p className="max-w-2xl text-xs text-muted-foreground">
            Real billing never looks back: a business's first real bill starts the moment it goes
            live, its free trial restarts then, and no earlier order is ever charged. Start with a
            pilot group.
          </p>
        </div>
        <form
          className="flex items-end gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            setQuery(search);
          }}
        >
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search a business"
            className="w-52"
            aria-label="Search a business"
          />
          <Button type="submit" variant="outline">
            Search
          </Button>
        </form>
      </div>
      {error && <p className="text-sm text-destructive">{error}</p>}
      {!rows && !error && <Skeleton className="h-24" />}
      {rows && (
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Business</TableHead>
                <TableHead>Plan</TableHead>
                <TableHead>Stage</TableHead>
                <TableHead>Status</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r) => {
                const stage = rolloutStage(r);
                const canGo = !r.activated_at && stage.tone === "held";
                return (
                  <TableRow key={r.business_id} data-testid="pilot-row">
                    <TableCell className="font-medium">
                      {r.name}
                      <span className="block text-xs font-normal capitalize text-muted-foreground">
                        {r.type}
                      </span>
                    </TableCell>
                    <TableCell>{r.plan_name ?? r.plan_code ?? "–"}</TableCell>
                    <TableCell>
                      <Badge variant="outline" className={stageTone[stage.tone]}>
                        {stage.label}
                      </Badge>
                      {r.activated_at && (
                        <span className="block text-xs text-muted-foreground">
                          {dateText(r.activated_at)}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="capitalize">{r.status.replace(/_/g, " ")}</TableCell>
                    <TableCell className="text-right">
                      {canGo && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setGoing(r)}
                          data-testid="go-live"
                        >
                          Go live
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}
      <GoLiveDialog
        row={going}
        onClose={() => setGoing(null)}
        onDone={() => {
          setGoing(null);
          void load();
          onChanged();
        }}
      />
    </Card>
  );
}

function GoLiveDialog({
  row,
  onClose,
  onDone,
}: {
  row: OrganizationRow | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [date, setDate] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setDate("");
    setReason("");
    setError(null);
  }, [row?.business_id]);
  if (!row) return null;
  const submit = async () => {
    const problem = reasonError(reason);
    if (problem) return setError(problem);
    setBusy(true);
    try {
      const r = await goLiveBusiness(
        row.business_id,
        date ? dateFromInput(date) : null,
        reason.trim(),
      );
      toast.success(
        `${row.name} is live${r.trial_end ? `; its free trial runs to ${dateText(r.trial_end)}` : ""}.`,
      );
      onDone();
    } catch (e) {
      setError(errText(e, "Could not put this business live."));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog open onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Put {row.name} live?</DialogTitle>
          <DialogDescription>
            Its real bill starts at that moment. Orders delivered before it are never charged, and
            its free trial restarts from it. Its billing cycle starts then too.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          <div className="grid gap-1">
            <Label htmlFor="gl-date">
              Starts on (optional; empty means now; up to 90 days ahead)
            </Label>
            <Input
              id="gl-date"
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="gl-reason">Reason (kept in the audit trail)</Label>
            <Textarea
              id="gl-reason"
              rows={2}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
            />
          </div>
          {error && (
            <p className="text-sm text-destructive" role="alert" data-testid="golive-error">
              {error}
            </p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void submit()} disabled={busy} data-testid="golive-submit">
            {busy ? "Working…" : "Go live"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function PolicyCard({ status, onChanged }: { status: RolloutStatus; onChanged: () => void }) {
  const [grace, setGrace] = useState(String(status.platform.grace_days));
  const [policy, setPolicy] = useState<"none" | "block_new_orders">(status.platform.enforcement);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setGrace(String(status.platform.grace_days));
    setPolicy(status.platform.enforcement);
  }, [status.platform.grace_days, status.platform.enforcement]);

  const save = async () => {
    const problem = reasonError(reason);
    if (problem) return setError(problem);
    const days = Number(grace);
    if (!/^\d+$/.test(grace.trim()) || days > 90)
      return setError("The grace period is a whole number of days from 0 to 90.");
    setBusy(true);
    setError(null);
    try {
      if (days !== status.platform.grace_days) await setGraceDays(days, reason.trim());
      if (policy !== status.platform.enforcement) await setEnforcement(policy, reason.trim());
      toast.success("Saved.");
      setReason("");
      onChanged();
    } catch (e) {
      setError(errText(e, "Could not save."));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card className="space-y-3 p-4" data-testid="policy-card">
      <div>
        <h3 className="font-semibold">When an invoice is not paid</h3>
        <p className="text-xs text-muted-foreground">
          An unpaid invoice makes the account past due, then suspended once the grace period ends;
          paying restores it. A business keeps working through the grace period.
        </p>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="grid gap-1">
          <Label htmlFor="pol-grace">Grace period after the due date (days)</Label>
          <Input
            id="pol-grace"
            inputMode="numeric"
            value={grace}
            onChange={(e) => setGrace(e.target.value)}
          />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="pol-policy">After the grace period</Label>
          <Select value={policy} onValueChange={(v) => setPolicy(v as "none" | "block_new_orders")}>
            <SelectTrigger id="pol-policy">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {(Object.keys(ENFORCEMENT_LABELS) as (keyof typeof ENFORCEMENT_LABELS)[]).map((k) => (
                <SelectItem key={k} value={k}>
                  {ENFORCEMENT_LABELS[k].label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>
      <p className="text-xs text-muted-foreground">{ENFORCEMENT_LABELS[policy].help}</p>
      <div className="grid gap-1">
        <Label htmlFor="pol-reason">Reason for the change (kept in the audit trail)</Label>
        <Input id="pol-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
      </div>
      {error && (
        <p className="text-sm text-destructive" role="alert" data-testid="policy-error">
          {error}
        </p>
      )}
      <Button onClick={() => void save()} disabled={busy} data-testid="policy-save">
        {busy ? "Saving…" : "Save"}
      </Button>
    </Card>
  );
}

function NoticesCard({ status, onChanged }: { status: RolloutStatus; onChanged: () => void }) {
  const n = status.platform.notifications;
  const [cfg, setCfg] = useState<NotificationSettings>(n);
  const [trialDays, setTrialDays] = useState(n.trial_days_before.join(", "));
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setCfg(status.platform.notifications);
    setTrialDays(status.platform.notifications.trial_days_before.join(", "));
  }, [status.platform.notifications]);

  const save = async () => {
    const problem = reasonError(reason);
    if (problem) return setError(problem);
    const days = trialDays
      .split(",")
      .map((x) => x.trim())
      .filter(Boolean);
    if (days.length === 0 || days.some((d) => !/^\d+$/.test(d)))
      return setError("Give the days before the trial ends as numbers, for example 7, 1.");
    setBusy(true);
    setError(null);
    try {
      await setNotificationSettings({ ...cfg, trial_days_before: days.map(Number) }, reason.trim());
      toast.success("Notice settings saved.");
      setReason("");
      onChanged();
    } catch (e) {
      setError(errText(e, "Could not save."));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card className="space-y-3 p-4" data-testid="notices-card">
      <div>
        <h3 className="font-semibold">Notices</h3>
        <p className="text-xs text-muted-foreground">
          Shown in the notification bell of the business's owner, managers and finance staff, once
          per event. Nothing is emailed. Switching a notice off does not send a backlog when it is
          switched back on.
        </p>
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        {NOTICE_LABELS.map((x) => (
          <label key={x.key} className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={Boolean(cfg[x.key])}
              onChange={(e) => setCfg({ ...cfg, [x.key]: e.target.checked })}
            />
            {x.label}
          </label>
        ))}
      </div>
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="grid gap-1">
          <Label htmlFor="nt-trial">Warn this many days before a trial ends</Label>
          <Input
            id="nt-trial"
            value={trialDays}
            onChange={(e) => setTrialDays(e.target.value)}
            placeholder="7, 1"
          />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="nt-grace">…before a grace period ends</Label>
          <Input
            id="nt-grace"
            inputMode="numeric"
            value={String(cfg.grace_days_before)}
            onChange={(e) => setCfg({ ...cfg, grace_days_before: Number(e.target.value) || 0 })}
          />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="nt-free">Warn when this many free orders are left</Label>
          <Input
            id="nt-free"
            inputMode="numeric"
            value={String(cfg.free_orders_threshold)}
            onChange={(e) => setCfg({ ...cfg, free_orders_threshold: Number(e.target.value) || 0 })}
          />
        </div>
      </div>
      <div className="grid gap-1">
        <Label htmlFor="nt-reason">Reason for the change (kept in the audit trail)</Label>
        <Input id="nt-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
      </div>
      {error && (
        <p className="text-sm text-destructive" role="alert" data-testid="notices-error">
          {error}
        </p>
      )}
      <Button onClick={() => void save()} disabled={busy} data-testid="notices-save">
        {busy ? "Saving…" : "Save notice settings"}
      </Button>
    </Card>
  );
}
