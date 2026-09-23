import { Download, Printer, RotateCcw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { REPORT_RANGES, type ReportRangeState } from "@/lib/reports";

const selectClass =
  "h-10 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring";

/**
 * Shared header for every Reports page: title, subtitle, date range and the common actions
 * (Apply, Reset, Export CSV, Print). The range is only applied on "Apply" so a custom-range edit
 * in progress doesn't fire a request per keystroke.
 */
export function ReportsHeader({
  title,
  subtitle,
  draft,
  onDraftChange,
  onApply,
  onReset,
  onExportCsv,
  exporting = false,
  exportDisabled = false,
}: {
  title: string;
  subtitle: string;
  draft: ReportRangeState;
  onDraftChange: (next: ReportRangeState) => void;
  onApply: () => void;
  onReset: () => void;
  onExportCsv: () => void;
  exporting?: boolean;
  exportDisabled?: boolean;
}) {
  return (
    <div className="print:hidden">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="font-display text-3xl font-bold">{title}</h1>
          <p className="mt-1 text-muted-foreground">{subtitle}</p>
        </div>
      </div>

      <form
        aria-label="Report date range"
        className="mt-4 flex flex-wrap items-end gap-2 rounded-xl border border-border bg-muted/20 p-3"
        onSubmit={(event) => {
          event.preventDefault();
          onApply();
        }}
      >
        <div>
          <Label htmlFor="report-range" className="text-xs text-muted-foreground">
            Date range
          </Label>
          <select
            id="report-range"
            className={selectClass}
            value={draft.range}
            onChange={(event) =>
              onDraftChange({ ...draft, range: event.target.value as ReportRangeState["range"] })
            }
          >
            {REPORT_RANGES.map((item) => (
              <option key={item.value} value={item.value}>
                {item.label}
              </option>
            ))}
          </select>
        </div>

        {draft.range === "custom" && (
          <>
            <div>
              <Label htmlFor="report-from" className="text-xs text-muted-foreground">
                From
              </Label>
              <Input
                id="report-from"
                type="date"
                value={draft.from}
                onChange={(event) => onDraftChange({ ...draft, from: event.target.value })}
              />
            </div>
            <div>
              <Label htmlFor="report-to" className="text-xs text-muted-foreground">
                To
              </Label>
              <Input
                id="report-to"
                type="date"
                value={draft.to}
                onChange={(event) => onDraftChange({ ...draft, to: event.target.value })}
              />
            </div>
          </>
        )}

        <Button type="submit" variant="hero" size="sm">
          Apply
        </Button>
        <Button type="button" variant="outline" size="sm" onClick={onReset}>
          <RotateCcw className="mr-1 h-4 w-4" aria-hidden="true" />
          Reset
        </Button>

        <div className="ml-auto flex gap-2">
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={onExportCsv}
            disabled={exporting || exportDisabled}
          >
            <Download className="mr-1 h-4 w-4" aria-hidden="true" />
            {exporting ? "Exporting..." : "Export CSV"}
          </Button>
          <Button type="button" variant="outline" size="sm" onClick={() => window.print()}>
            <Printer className="mr-1 h-4 w-4" aria-hidden="true" />
            Print
          </Button>
        </div>
      </form>
    </div>
  );
}
