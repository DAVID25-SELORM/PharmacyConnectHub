import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { describeRun, runBillingNow, setPlatformMode } from "@/lib/billing-plans";
import type { RolloutStatus } from "@/lib/billing-rollout";
import { ActionDialog, type Action } from "./BillingControls";

const MODE_TEXT = {
  disabled: "Off: nothing is assessed or charged.",
  shadow: "Shadow: what would be charged is recorded, and nothing is charged.",
  active: "On: businesses that have been put live are charged.",
} as const;

/** Switching the platform to shadow or off, as a reason dialog. `mode` is where the platform is now, which decides how the consequences are worded. */
export function platformSwitchAction(
  mode: "disabled" | "shadow" | "active",
  next: "disabled" | "shadow",
): Action {
  return {
    id: `mode-${next}`,
    label: next === "shadow" ? "Switch to shadow" : "Switch billing off",
    description:
      next === "shadow"
        ? "Starts recording what each business would be charged, without charging anything. Use this before going live."
        : mode === "active"
          ? "Stops assessing orders and issuing bills for everyone. Nothing already billed is changed, and billing catches up on the orders it missed when it is switched on again."
          : "Stops recording shadow figures. Nothing is charged either way.",
    fields: [],
    submit: next === "shadow" ? "Switch to shadow" : "Switch off",
    destructive: next === "disabled" && mode === "active",
    run: async (v) => {
      await setPlatformMode(next, v.reason.trim());
      return next === "shadow" ? "Billing is in shadow." : "Billing is off.";
    },
  };
}

/** Running the scheduled billing job now, as a reason dialog. */
export function runNowAction(): Action {
  return {
    id: "run-now",
    label: "Run billing now",
    description:
      "Runs the same job the schedule runs every 15 minutes: assesses delivered orders, opens periods, issues invoices and updates account statuses. It is safe to run at any time; it does nothing twice.",
    fields: [],
    submit: "Run now",
    run: async (v) => `Billing run finished. ${describeRun(await runBillingNow(v.reason.trim()))}`,
  };
}

/** The platform billing mode (never to "on": that goes through the checklist) and a manual run of the scheduled billing job. */
export function PlatformModeCard({
  status,
  onChanged,
}: {
  status: RolloutStatus;
  onChanged: () => void;
}) {
  const [action, setAction] = useState<Action | null>(null);
  const mode = status.platform.mode;

  const switchTo = (next: "disabled" | "shadow") => platformSwitchAction(mode, next);
  const runNow = runNowAction();

  return (
    <Card className="space-y-3 p-4" data-testid="platform-mode">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="font-semibold">Billing mode and scheduled run</h3>
          <p className="text-sm text-muted-foreground" data-testid="platform-mode-text">
            {MODE_TEXT[mode]}
          </p>
          <p className="text-xs text-muted-foreground">
            {status.run.last_run_at
              ? `Last run ${status.run.minutes_since} minutes ago. ${describeRun(status.run.last_result)}`
              : "The scheduled run has never run."}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {mode === "disabled" && (
            <Button
              size="sm"
              variant="outline"
              onClick={() => setAction(switchTo("shadow"))}
              data-testid="to-shadow"
            >
              Switch to shadow
            </Button>
          )}
          {mode !== "disabled" && (
            <Button
              size="sm"
              variant="outline"
              onClick={() => setAction(switchTo("disabled"))}
              data-testid="to-off"
            >
              Switch billing off
            </Button>
          )}
          <Button size="sm" onClick={() => setAction(runNow)} data-testid="run-now">
            Run billing now
          </Button>
        </div>
      </div>
      <ActionDialog
        action={action}
        onClose={() => setAction(null)}
        onDone={() => {
          setAction(null);
          onChanged();
        }}
      />
    </Card>
  );
}
