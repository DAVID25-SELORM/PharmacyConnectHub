import { FileText } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { EnterpriseRfq } from "@/lib/enterprise-rfq";
import { deadlineHint, rfqDate } from "@/lib/rfq-format";
import { TablePager } from "./TablePager";
import { RfqStatusBadge } from "./RfqStatusBadge";

export const RFQ_LIST_PAGE = 25;

/** The requests list: one row per RFQ, with status, quotation count and how the deadline stands. */
export function RfqListTable({
  rows,
  loading,
  count,
  page,
  onPage,
  onOpen,
}: {
  rows: EnterpriseRfq[];
  loading: boolean;
  count: number;
  page: number;
  onPage: (page: number) => void;
  onOpen: (rfq: EnterpriseRfq) => void;
}) {
  const from = count === 0 ? 0 : page * RFQ_LIST_PAGE + 1;
  const paged = {
    rows: [],
    page,
    pageCount: Math.max(1, Math.ceil(count / RFQ_LIST_PAGE)),
    from,
    to: Math.min(count, page * RFQ_LIST_PAGE + rows.length),
    total: count,
  };
  return (
    <div className="overflow-hidden rounded-lg border bg-card">
      <div className="overflow-x-auto">
        <Table className="min-w-[760px]">
          <TableHeader>
            <TableRow className="bg-muted/40 hover:bg-muted/40">
              <TableHead className="w-36">Reference</TableHead>
              <TableHead>Request</TableHead>
              <TableHead className="w-40">Status</TableHead>
              <TableHead className="w-28 text-right">Quotations</TableHead>
              <TableHead className="w-56">Deadline</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {loading && rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={5} className="py-12 text-center text-sm text-muted-foreground">
                  <span role="status">Loading requests…</span>
                </TableCell>
              </TableRow>
            ) : rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={5} className="py-14 text-center">
                  <FileText className="mx-auto mb-2 h-6 w-6 text-muted-foreground" />
                  <p className="font-medium">No matching requests</p>
                  <p className="text-sm text-muted-foreground">
                    Change the filters, or start a new request.
                  </p>
                </TableCell>
              </TableRow>
            ) : (
              rows.map((r) => (
                <TableRow
                  key={r.id}
                  tabIndex={0}
                  role="link"
                  aria-label={`Open ${r.reference}: ${r.title}`}
                  className="cursor-pointer focus-visible:bg-muted/50 focus-visible:outline-none"
                  onClick={() => onOpen(r)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      onOpen(r);
                    }
                  }}
                >
                  <TableCell className="font-mono text-xs text-muted-foreground">
                    {r.reference}
                  </TableCell>
                  <TableCell>
                    <div className="font-medium">{r.title}</div>
                    <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                      <span>Created {rfqDate(r.created_at)}</span>
                      {!r.enterprise && (
                        <Badge variant="outline" className="px-1.5 py-0 text-[10px] font-medium">
                          Legacy RFQ
                        </Badge>
                      )}
                    </div>
                  </TableCell>
                  <TableCell>
                    <RfqStatusBadge value={r.display_status ?? r.status} />
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{r.quote_count ?? 0}</TableCell>
                  <TableCell className="text-sm">
                    <div>{r.response_deadline ? rfqDate(r.response_deadline) : "No deadline"}</div>
                    {r.response_deadline && ["open", "evaluation"].includes(r.status) && (
                      <div className="text-xs text-muted-foreground">
                        {deadlineHint(r.response_deadline)}
                      </div>
                    )}
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>
      <TablePager
        paged={paged}
        size={RFQ_LIST_PAGE}
        onSize={() => {}}
        onPage={onPage}
        showSize={false}
      />
    </div>
  );
}
