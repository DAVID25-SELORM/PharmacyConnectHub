import { useState, type ReactNode } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { RFQ_PAGE_SIZES, pageOf } from "@/lib/rfq-lines";
import { TablePager } from "./TablePager";

export type PagedRow = {
  id: string;
  /** What a search looks at. */
  text: string;
  left: ReactNode;
  right: ReactNode;
};

/** A plain two-column list that gains search and paging once it is longer than one page. */
export function PagedList({ rows, label }: { rows: PagedRow[]; label: string }) {
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [size, setSize] = useState<number>(RFQ_PAGE_SIZES[0]);
  const term = search.trim().toLowerCase();
  const shown = rows
    .map((_, i) => i)
    .filter((i) => !term || rows[i].text.toLowerCase().includes(term));
  const paged = pageOf(shown, page, size);
  const long = rows.length > RFQ_PAGE_SIZES[0];
  return (
    <div className="overflow-hidden rounded-xl border border-border">
      {long && (
        <div className="border-b bg-muted/30 p-2">
          <div className="relative max-w-xs">
            <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
            <Input
              aria-label={label}
              placeholder={label}
              className="pl-8"
              value={search}
              onChange={(e) => {
                setSearch(e.target.value);
                setPage(0);
              }}
            />
          </div>
        </div>
      )}
      <ul className="divide-y divide-border text-sm">
        {paged.rows.length === 0 ? (
          <li className="p-4 text-center text-muted-foreground">Nothing matches.</li>
        ) : (
          paged.rows.map((i) => (
            <li key={rows[i].id} className="flex items-center justify-between gap-3 p-3">
              <span className="min-w-0">{rows[i].left}</span>
              <span className="shrink-0 text-right text-muted-foreground">{rows[i].right}</span>
            </li>
          ))
        )}
      </ul>
      {(shown.length > RFQ_PAGE_SIZES[0] || size !== RFQ_PAGE_SIZES[0]) && (
        <TablePager paged={paged} size={size} onSize={setSize} onPage={setPage} />
      )}
    </div>
  );
}
