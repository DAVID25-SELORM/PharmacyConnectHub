import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { RFQ_PAGE_SIZES, type Paged } from "@/lib/rfq-lines";

/** Footer for a paged RFQ list: position, rows per page and page navigation with a jump box. */
export function TablePager({
  paged,
  size,
  onSize,
  onPage,
  showSize = true,
}: {
  paged: Paged;
  size: number;
  onSize: (size: number) => void;
  onPage: (page: number) => void;
  /** A list the server pages at a fixed size has no rows-per-page choice. */
  showSize?: boolean;
}) {
  return (
    <div className="flex flex-wrap items-center gap-3 border-t bg-muted/30 px-3 py-2 text-sm">
      <span className="tabular-nums text-muted-foreground">
        {paged.total ? `Showing ${paged.from}–${paged.to} of ${paged.total}` : "Nothing to show"}
      </span>
      {showSize ? (
        <label className="ml-auto flex items-center gap-2 text-xs text-muted-foreground">
          Rows per page
          <select
            aria-label="Rows per page"
            className="h-8 w-20 rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            value={size}
            onChange={(e) => {
              onSize(Number(e.target.value));
              onPage(0);
            }}
          >
            {RFQ_PAGE_SIZES.map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
        </label>
      ) : (
        <span className="ml-auto" />
      )}
      <div className="flex items-center gap-1">
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="h-8 w-8"
          aria-label="Previous page"
          disabled={paged.page === 0}
          onClick={() => onPage(paged.page - 1)}
        >
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <span className="flex items-center gap-1 px-1 text-xs tabular-nums">
          Page
          <Input
            aria-label="Go to page"
            type="number"
            min="1"
            max={paged.pageCount}
            className="h-8 w-14 px-2 text-center"
            value={paged.page + 1}
            onChange={(e) => {
              const n = Number(e.target.value);
              if (Number.isFinite(n)) onPage(Math.min(Math.max(1, n), paged.pageCount) - 1);
            }}
          />
          of {paged.pageCount}
        </span>
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="h-8 w-8"
          aria-label="Next page"
          disabled={paged.page >= paged.pageCount - 1}
          onClick={() => onPage(paged.page + 1)}
        >
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>
    </div>
  );
}
