import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { formatGHS } from "@/lib/format";
import { summarizeResolved, type ResolvedLine } from "@/lib/reorder";

/** Shows what a reorder would actually add today, before anything touches the cart. */
export function ReorderReviewDialog({
  title,
  lines,
  onClose,
  onConfirm,
  canOrder,
}: {
  title: string;
  lines: ResolvedLine[] | null;
  onClose: () => void;
  onConfirm: (lines: ResolvedLine[]) => void;
  canOrder: boolean;
}) {
  const summary = lines ? summarizeResolved(lines) : null;

  return (
    <Dialog open={Boolean(lines)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>
            Prices, suppliers and stock are checked against today&apos;s catalogue, not the old
            order.
          </DialogDescription>
        </DialogHeader>

        {lines && summary && (
          <>
            <p className="text-sm font-medium" aria-live="polite">
              {summary.available} of {summary.total} product{summary.total === 1 ? "" : "s"}{" "}
              available
              {summary.unavailable > 0 && ` · ${summary.unavailable} can't be supplied right now`}
              {summary.available > 0 && ` · about ${formatGHS(summary.estimatedTotal)}`}
            </p>
            <ul className="divide-y divide-border rounded-xl border border-border">
              {lines.map((line, index) => (
                <li key={index} className="p-3 text-sm">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{line.wanted.name}</span>
                    {line.status === "unavailable" ? (
                      <Badge variant="destructive">Unavailable</Badge>
                    ) : line.status === "adjusted" ? (
                      <Badge variant="secondary">Adjusted</Badge>
                    ) : (
                      <Badge variant="outline">Ready</Badge>
                    )}
                  </div>
                  {line.status === "unavailable" ? (
                    <p className="mt-1 text-muted-foreground">{line.note}</p>
                  ) : (
                    <p className="mt-1 text-muted-foreground">
                      {line.quantity} × {formatGHS(line.unitPrice ?? 0)} from{" "}
                      {line.offer?.wholesaler?.name}
                      {line.note && <span className="block text-xs text-warning">{line.note}</span>}
                    </p>
                  )}
                </li>
              ))}
            </ul>
          </>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            variant="hero"
            disabled={!canOrder || !summary || summary.available === 0}
            onClick={() => lines && onConfirm(lines)}
          >
            Add available to cart
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
