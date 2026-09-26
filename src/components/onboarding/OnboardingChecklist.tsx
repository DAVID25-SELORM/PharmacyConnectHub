import { AlertTriangle, Check, Circle, Clock } from "lucide-react";
import { Card } from "@/components/ui/card";
import { checklistProgress, type ChecklistStep } from "@/lib/onboarding-checklist";

function StepIcon({ state }: { state: ChecklistStep["state"] }) {
  if (state === "done")
    return (
      <span className="flex h-6 w-6 items-center justify-center rounded-full bg-success/15 text-success">
        <Check className="h-4 w-4" aria-hidden="true" />
      </span>
    );
  if (state === "current")
    return (
      <span className="flex h-6 w-6 items-center justify-center rounded-full bg-primary/15 text-primary">
        <Clock className="h-4 w-4" aria-hidden="true" />
      </span>
    );
  if (state === "attention")
    return (
      <span className="flex h-6 w-6 items-center justify-center rounded-full bg-destructive/15 text-destructive">
        <AlertTriangle className="h-4 w-4" aria-hidden="true" />
      </span>
    );
  return (
    <span className="flex h-6 w-6 items-center justify-center rounded-full bg-muted text-muted-foreground">
      <Circle className="h-3 w-3" aria-hidden="true" />
    </span>
  );
}

const STATE_TEXT: Record<ChecklistStep["state"], string> = {
  done: "Done",
  current: "In progress",
  attention: "Needs attention",
  todo: "To do",
};

/** The owner's verification steps, each with a clear status. */
export function OnboardingChecklist({ steps }: { steps: ChecklistStep[] }) {
  const progress = checklistProgress(steps);
  return (
    <Card className="mt-6 p-6" aria-labelledby="verification-checklist-heading">
      <div className="flex items-center justify-between gap-3">
        <h2 id="verification-checklist-heading" className="font-display text-xl font-bold">
          Verification checklist
        </h2>
        <span className="text-sm text-muted-foreground">
          {progress.done} of {progress.total} steps
        </span>
      </div>
      <ol className="mt-4 space-y-3">
        {steps.map((step) => (
          <li key={step.key} className="flex items-start gap-3">
            <StepIcon state={step.state} />
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2 text-sm font-medium">
                {step.label}
                <span className="sr-only">{STATE_TEXT[step.state]}</span>
              </div>
              {step.detail && (
                <div
                  className={`text-xs ${step.state === "attention" ? "text-destructive" : "text-muted-foreground"}`}
                >
                  {step.detail}
                </div>
              )}
            </div>
          </li>
        ))}
      </ol>
    </Card>
  );
}
