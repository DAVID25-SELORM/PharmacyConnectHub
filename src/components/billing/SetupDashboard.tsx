import { CheckCircle2, Circle, CircleAlert, XCircle } from "lucide-react";
import { Card } from "@/components/ui/card";
import type {
  ItemStatus,
  SetupStage,
  SetupStatus,
  StageKey,
  StageStatus,
} from "@/lib/billing-setup";

export const STAGE_STATUS_TEXT: Record<StageStatus, string> = {
  complete: "Complete",
  current: "In progress",
  attention: "Needs attention",
  upcoming: "Pending",
};
export const STAGE_STATUS_TONE: Record<StageStatus, string> = {
  complete: "border-success/30 bg-success/15 text-success",
  current: "border-primary/30 bg-primary/10 text-primary",
  attention: "border-destructive/30 bg-destructive/10 text-destructive",
  upcoming: "border-border bg-muted text-muted-foreground",
};

export function ItemIcon({ status }: { status: ItemStatus }) {
  if (status === "done")
    return <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" aria-label="done" />;
  if (status === "problem")
    return <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" aria-label="problem" />;
  if (status === "advice")
    return <CircleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-label="advice" />;
  return <Circle className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" aria-label="pending" />;
}

/** One picture of where billing setup stands: what is complete, what is pending, and exactly what prevents activation. */
export function SetupDashboard({
  status,
  platformMode,
  onOpenStage,
}: {
  status: SetupStatus;
  platformMode: "disabled" | "shadow" | "active";
  onOpenStage: (key: StageKey) => void;
}) {
  const active = platformMode === "active";
  const headline = active
    ? "Real billing is on"
    : status.canActivate
      ? "Ready to activate pilot businesses"
      : status.blockers.length === 1
        ? "1 thing stops activation"
        : `${status.blockers.length} things stop activation`;
  const tone = active
    ? "border-success/30"
    : status.canActivate
      ? "border-success/30"
      : "border-warning/40";
  return (
    <Card className={`space-y-4 p-4 ${tone}`} data-testid="setup-dashboard">
      <div className="space-y-2">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h3 className="text-lg font-semibold" data-testid="setup-headline">
            {headline}
          </h3>
          <span className="text-sm text-muted-foreground tabular-nums">
            {status.percent}% ready
          </span>
        </div>
        <div
          className="h-2 overflow-hidden rounded-full bg-muted"
          role="progressbar"
          aria-valuenow={status.percent}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-label="Setup progress"
        >
          <div className="h-full rounded-full bg-primary" style={{ width: `${status.percent}%` }} />
        </div>
        <p className="text-sm text-muted-foreground">
          {active
            ? "Put each pilot business live one at a time in stage 4. Nobody is charged until you do."
            : status.canActivate
              ? "Everything required is done. Nobody is charged until you switch real billing on and put a business live."
              : "Billing stays off until every item below is done. Nothing is charged while it is off or in shadow."}
        </p>
      </div>

      {!active && status.blockers.length > 0 && (
        <div data-testid="setup-blockers">
          <div className="text-sm font-medium">What prevents activation</div>
          <ul className="mt-1 list-disc space-y-0.5 pl-5 text-sm text-muted-foreground">
            {status.blockers.map((b) => (
              <li key={b}>{b}</li>
            ))}
          </ul>
        </div>
      )}

      <ol className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {status.stages.map((s) => (
          <StageTile key={s.key} stage={s} onOpen={() => onOpenStage(s.key)} />
        ))}
      </ol>
    </Card>
  );
}

function StageTile({ stage, onOpen }: { stage: SetupStage; onOpen: () => void }) {
  return (
    <li>
      <button
        type="button"
        onClick={onOpen}
        className="flex h-full w-full flex-col gap-1 rounded-lg border p-3 text-left transition-colors hover:bg-muted/50"
        data-testid={`stage-tile-${stage.key}`}
      >
        <span className="flex items-center gap-2 text-xs text-muted-foreground">
          <span className="flex h-5 w-5 items-center justify-center rounded-full border text-[11px] font-semibold">
            {stage.number}
          </span>
          <span
            className={`rounded-full border px-2 py-0.5 text-[11px] font-medium ${STAGE_STATUS_TONE[stage.status]}`}
            data-testid={`stage-status-${stage.key}`}
          >
            {STAGE_STATUS_TEXT[stage.status]}
          </span>
        </span>
        <span className="text-sm font-semibold">{stage.title}</span>
        <span className="text-xs text-muted-foreground tabular-nums">
          {stage.done} of {stage.total} done
        </span>
      </button>
    </li>
  );
}
