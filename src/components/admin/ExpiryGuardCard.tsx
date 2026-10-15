import { useCallback, useEffect, useState } from "react";
import { CheckCircle2, CircleAlert, ShieldCheck } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ActionDialog, type Action } from "@/components/billing/BillingControls";
import {
  ENTRY_LABELS,
  MODE_DESCRIPTIONS,
  MODE_LABELS,
  fetchGuardStatus,
  guardAdvice,
  setGuardMode,
  type GuardMode,
  type GuardStatus,
} from "@/lib/expiry-guard";

const when = (iso: string) =>
  new Date(iso).toLocaleString("en-GB", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "UTC",
  }) + " UTC";

function Stat({ label, value, alert }: { label: string; value: number; alert?: boolean }) {
  return (
    <div className={`rounded-lg border p-3 ${alert ? "border-warning/40" : ""}`}>
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="text-xl font-semibold tabular-nums">{value.toLocaleString("en-GB")}</div>
    </div>
  );
}

/** Whether expired stock can be sold, what the guard would have refused, and the switch (off, observing, enforced). Every change needs a reason and is audited. */
export function ExpiryGuardCard() {
  const [status, setStatus] = useState<GuardStatus | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [action, setAction] = useState<Action | null>(null);

  const load = useCallback(async () => {
    try {
      setStatus(await fetchGuardStatus(20));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load the expiry guard.");
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  const choose = (current: GuardMode): Action => ({
    id: "expiry-guard-mode",
    label: "Expiry guard mode",
    description:
      "Observing records what would be refused and blocks nothing. Enforced refuses sales that need expired units. You can go back at any time.",
    fields: [
      {
        key: "mode",
        label: "Mode",
        type: "select",
        initial: current,
        options: (Object.keys(MODE_LABELS) as GuardMode[]).map((m) => ({
          value: m,
          label: MODE_LABELS[m],
        })),
        help: "Off: nothing is checked. Observing: records what would be refused and blocks nothing. Enforced: refuses sales that need expired units.",
      },
    ],
    submit: "Change mode",
    run: async (v) => {
      const next = v.mode as GuardMode;
      if (!next) throw new Error("Choose the mode.");
      if (next === current) throw new Error("That is already the mode.");
      await setGuardMode(next, v.reason.trim());
      return `Expiry guard: ${MODE_LABELS[next].toLowerCase()}.`;
    },
  });

  if (error)
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  if (status === undefined) return <Skeleton className="h-32" />;
  if (status === null)
    return (
      <Card className="space-y-1 p-4" data-testid="expiry-guard-missing">
        <h2 className="flex items-center gap-2 font-display text-xl font-bold">
          <ShieldCheck className="h-5 w-5 text-primary" aria-hidden="true" /> Expired stock
        </h2>
        <p className="text-sm text-muted-foreground">
          The expiry guard has not been added to the database yet. Until it is, expired units can be
          sold.
        </p>
      </Card>
    );

  const advice = guardAdvice(status);
  return (
    <Card className="space-y-4 p-4" data-testid="expiry-guard">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-1">
          <h2 className="flex items-center gap-2 font-display text-xl font-bold">
            <ShieldCheck className="h-5 w-5 text-primary" aria-hidden="true" /> Expired stock
          </h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            Units in a batch past its expiry date should not be sold. The guard works out what can
            still be sold at checkout, on request awards and on back-order shipments.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Badge variant="outline" data-testid="guard-mode">
            {MODE_LABELS[status.mode]}
          </Badge>
          <Button
            size="sm"
            variant="outline"
            onClick={() => setAction(choose(status.mode))}
            data-testid="guard-change"
          >
            Change mode
          </Button>
        </div>
      </div>

      <p className="text-sm" data-testid="guard-mode-text">
        {MODE_DESCRIPTIONS[status.mode]}
      </p>

      <div
        className="flex items-start gap-2 rounded-md border p-3 text-sm"
        data-testid="guard-advice"
      >
        {advice.tone === "good" ? (
          <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" aria-hidden="true" />
        ) : (
          <CircleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
        )}
        <div>
          <div className="font-medium">{advice.headline}</div>
          <ul className="mt-1 list-disc space-y-0.5 pl-5 text-muted-foreground">
            {advice.points.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        </div>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <Stat label="Products holding expired units" value={status.products_with_expired_units} />
        <Stat label="Expired units on hand" value={status.expired_units} />
        <Stat
          label="Still orderable with expired units"
          value={status.orderable_products_with_expired_units}
          alert={status.orderable_products_with_expired_units > 0}
        />
        <Stat
          label="Batches exceed stock"
          value={status.products_where_batches_exceed_stock}
          alert={status.products_where_batches_exceed_stock > 0}
        />
        <Stat
          label={status.mode === "enforce" ? "Refused in 7 days" : "Would be refused in 7 days"}
          value={status.would_have_blocked_7_days}
        />
      </div>

      <div className="space-y-2">
        <h3 className="text-sm font-semibold">Sales the guard would have refused</h3>
        {status.events.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="guard-no-events">
            None recorded.
            {status.mode === "enforce"
              ? " In enforced mode a refused sale is not recorded: the buyer sees the reason instead."
              : ""}
          </p>
        ) : (
          <div className="overflow-x-auto rounded-md border" data-testid="guard-events">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>When</TableHead>
                  <TableHead>Where</TableHead>
                  <TableHead>Product</TableHead>
                  <TableHead>Wholesaler</TableHead>
                  <TableHead className="text-right">Ordered</TableHead>
                  <TableHead className="text-right">In stock</TableHead>
                  <TableHead className="text-right">Expired</TableHead>
                  <TableHead className="text-right">Sellable</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {status.events.map((e, i) => (
                  <TableRow key={`${e.created_at}-${i}`}>
                    <TableCell className="whitespace-nowrap text-xs">
                      {when(e.created_at)}
                    </TableCell>
                    <TableCell className="text-xs">{ENTRY_LABELS[e.entry_point]}</TableCell>
                    <TableCell className="font-medium">{e.product_name}</TableCell>
                    <TableCell>{e.wholesaler_name ?? "–"}</TableCell>
                    <TableCell className="text-right tabular-nums">{e.quantity}</TableCell>
                    <TableCell className="text-right tabular-nums">{e.stock}</TableCell>
                    <TableCell className="text-right tabular-nums text-destructive">
                      {e.expired_units}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{e.sellable}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </div>

      <ActionDialog
        action={action}
        onClose={() => setAction(null)}
        onDone={() => {
          setAction(null);
          void load();
        }}
      />
    </Card>
  );
}
