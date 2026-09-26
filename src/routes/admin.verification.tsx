import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { ChevronLeft, ChevronRight, ExternalLink, Search } from "lucide-react";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { AdminNav } from "@/components/admin/AdminNav";
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
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { supabase } from "@/integrations/supabase/client";
import { formatReportDate } from "@/lib/reports";
import {
  QUEUE_SORTS,
  QUEUE_STATUS_FILTERS,
  documentsComplete,
  waitingLabel,
  waitingTone,
  type QueueRow,
} from "@/lib/verification-queue";

export const Route = createFileRoute("/admin/verification")({
  head: () => ({ meta: [{ title: "Verification queue - Drugxone" }] }),
  component: VerificationQueuePage,
});

const PAGE_SIZE = 25;
type DocRow = { id: string; doc_type: string; storage_path: string; uploaded_at: string };

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

function ReviewDialog({
  row,
  onClose,
  onDone,
}: {
  row: QueueRow | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setReason("");
    setDocs([]);
    if (!row) return;
    let cancelled = false;
    void supabase
      .from("license_documents")
      .select("*")
      .eq("business_id", row.business_id)
      .order("uploaded_at", { ascending: false })
      .then(({ data }) => {
        if (!cancelled) setDocs((data as DocRow[]) ?? []);
      });
    return () => {
      cancelled = true;
    };
  }, [row]);

  const openDoc = async (path: string) => {
    const { data, error } = await supabase.storage.from("licenses").createSignedUrl(path, 300);
    if (error) return toast.error(error.message);
    window.open(data.signedUrl, "_blank");
  };

  const approve = async () => {
    if (!row) return;
    if (
      !documentsComplete(row) &&
      !window.confirm(
        `${row.business_name} has only ${row.docs_uploaded} of ${row.docs_required} required documents. Approve anyway?`,
      )
    )
      return;
    setBusy(true);
    const { error } = await supabase
      .from("businesses")
      .update({
        verification_status: "approved",
        verified_at: new Date().toISOString(),
        rejection_reason: null,
      })
      .eq("id", row.business_id);
    setBusy(false);
    if (error) return toast.error(error.message);
    toast.success(`${row.business_name} approved`);
    onDone();
    onClose();
  };

  const requestCorrection = async () => {
    if (!row) return;
    if (!reason.trim()) return toast.error("Tell the owner what needs correcting.");
    setBusy(true);
    const { error } = await supabase
      .from("businesses")
      .update({ verification_status: "rejected", rejection_reason: reason.trim() })
      .eq("id", row.business_id);
    setBusy(false);
    if (error) return toast.error(error.message);
    toast.success(`Correction requested from ${row.business_name}`);
    onDone();
    onClose();
  };

  return (
    <Dialog open={Boolean(row)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{row?.business_name}</DialogTitle>
          <DialogDescription>
            {row?.business_type} ·{" "}
            {[row?.city, row?.region].filter(Boolean).join(", ") || "Location not set"} · Licence{" "}
            {row?.license_number || "—"}
          </DialogDescription>
        </DialogHeader>

        {row && (
          <>
            <div className="text-sm">
              <div className="font-medium">
                Documents: {row.docs_uploaded} of {row.docs_required} required
              </div>
              {docs.length === 0 ? (
                <p className="mt-1 text-muted-foreground">No documents uploaded.</p>
              ) : (
                <ul className="mt-2 divide-y divide-border rounded-xl border border-border">
                  {docs.map((doc) => (
                    <li key={doc.id} className="flex items-center justify-between gap-2 p-2">
                      <span>{doc.doc_type.replace(/_/g, " ")}</span>
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => void openDoc(doc.storage_path)}
                      >
                        <ExternalLink className="mr-1 h-4 w-4" aria-hidden="true" />
                        Open
                      </Button>
                    </li>
                  ))}
                </ul>
              )}
              {row.rejection_reason && (
                <p className="mt-3 text-destructive">
                  Last correction request: {row.rejection_reason}
                </p>
              )}
            </div>

            <label className="block text-sm">
              <span className="mb-1 block text-muted-foreground">
                What needs correcting (required to request a correction)
              </span>
              <Textarea
                value={reason}
                maxLength={500}
                onChange={(event) => setReason(event.target.value)}
              />
            </label>
            <p className="text-xs text-muted-foreground">
              A correction request tells the owner what to fix; they can then upload new documents
              and resubmit for review. Use the business record on the Dashboard to edit details.
            </p>
          </>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Close
          </Button>
          <Button variant="outline" disabled={busy} onClick={() => void requestCorrection()}>
            Request correction
          </Button>
          <Button variant="hero" disabled={busy} onClick={() => void approve()}>
            Approve
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function VerificationQueuePage() {
  const [status, setStatus] = useState("pending");
  const [type, setType] = useState("");
  const [sort, setSort] = useState("oldest");
  const [search, setSearch] = useState("");
  const debounced = useDebouncedValue(search.trim(), 300);
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<QueueRow[]>([]);
  const [summary, setSummary] = useState<QueueRow | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [reviewing, setReviewing] = useState<QueueRow | null>(null);

  useEffect(() => setPage(0), [debounced]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await rpc("admin_verification_queue", {
      p_status: status,
      p_type: type || null,
      p_search: debounced || null,
      p_sort: sort,
      p_limit: PAGE_SIZE,
      p_offset: page * PAGE_SIZE,
    });
    if (rpcError) setError(true);
    else {
      const list = Array.isArray(data) ? (data as QueueRow[]) : [];
      setRows(list);
      if (list[0]) setSummary(list[0]);
    }
    setLoading(false);
  }, [status, type, debounced, sort, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const total = rows[0]?.total_count ?? 0;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const kpis = summary
    ? [
        ["Waiting for review", summary.summary_pending],
        ["New", summary.summary_new],
        ["Resubmitted", summary.summary_resubmitted],
        ["Correction requested", summary.summary_rejected],
        ["Longest wait", waitingLabel(summary.summary_longest_wait_days)],
      ]
    : [];

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Admin console" />
      <AdminNav />
      <main className="mx-auto max-w-7xl space-y-4 px-4 py-8 sm:px-6 lg:px-8">
        <div>
          <h1 className="font-display text-3xl font-bold">Verification queue</h1>
          <p className="mt-1 text-muted-foreground">
            Businesses waiting for a decision, oldest first. Resubmissions count from the day they
            were resubmitted.
          </p>
        </div>

        {kpis.length > 0 && (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
            {kpis.map(([label, value]) => (
              <Card key={label as string} className="p-4">
                <div className="text-xs uppercase tracking-wider text-muted-foreground">
                  {label}
                </div>
                <div className="mt-1 font-display text-xl font-bold tabular-nums">{value}</div>
              </Card>
            ))}
          </div>
        )}

        <div className="flex flex-col gap-3 lg:flex-row lg:items-center">
          <div className="relative flex-1">
            <Search
              className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
              aria-hidden="true"
            />
            <Input
              aria-label="Search businesses"
              className="pl-9"
              placeholder="Search business name or licence number..."
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </div>
          <select
            aria-label="Business type"
            className="h-10 rounded-md border border-input bg-background px-2 text-sm"
            value={type}
            onChange={(event) => {
              setType(event.target.value);
              setPage(0);
            }}
          >
            <option value="">Pharmacies and wholesalers</option>
            <option value="pharmacy">Pharmacies</option>
            <option value="wholesaler">Wholesalers</option>
          </select>
          <select
            aria-label="Sort order"
            className="h-10 rounded-md border border-input bg-background px-2 text-sm"
            value={sort}
            onChange={(event) => {
              setSort(event.target.value);
              setPage(0);
            }}
          >
            {QUEUE_SORTS.map((item) => (
              <option key={item.value} value={item.value}>
                {item.label}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-wrap gap-2" role="group" aria-label="Queue status filter">
          {QUEUE_STATUS_FILTERS.map((item) => (
            <Button
              key={item.value}
              size="sm"
              variant={status === item.value ? "secondary" : "ghost"}
              onClick={() => {
                setStatus(item.value);
                setPage(0);
              }}
            >
              {item.label}
            </Button>
          ))}
        </div>

        {loading ? (
          <div className="space-y-2" role="status" aria-label="Loading queue">
            <Skeleton className="h-14 w-full" />
            <Skeleton className="h-14 w-full" />
            <Skeleton className="h-14 w-full" />
          </div>
        ) : error ? (
          <div
            role="alert"
            className="rounded-xl border border-dashed border-border p-8 text-center"
          >
            <p className="text-sm font-medium">We couldn&apos;t load the verification queue.</p>
            <Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>
              Try again
            </Button>
          </div>
        ) : rows.length === 0 ? (
          <Card className="p-10 text-center text-muted-foreground">
            <p className="font-medium text-foreground">
              {debounced || type || status !== "pending"
                ? "Nothing matches."
                : "The queue is empty"}
            </p>
            <p className="mt-1 text-sm">
              {debounced || type || status !== "pending"
                ? "Try different filters."
                : "No businesses are waiting for review."}
            </p>
          </Card>
        ) : (
          <Card className="relative overflow-x-auto">
            <table className="w-full min-w-[820px] text-left text-sm">
              <thead className="bg-muted/40 text-xs uppercase tracking-wider text-muted-foreground">
                <tr>
                  <th scope="col" className="p-3">
                    Business
                  </th>
                  <th scope="col" className="p-3">
                    Type
                  </th>
                  <th scope="col" className="p-3">
                    Submitted
                  </th>
                  <th scope="col" className="p-3">
                    Waiting
                  </th>
                  <th scope="col" className="p-3">
                    Documents
                  </th>
                  <th scope="col" className="p-3">
                    Status
                  </th>
                  <th scope="col" className="p-3">
                    <span className="sr-only">Action</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => {
                  const tone = waitingTone(row.waiting_days);
                  return (
                    <tr key={row.business_id} className="border-t align-top">
                      <td className="p-3">
                        <div className="font-medium">{row.business_name}</div>
                        <div className="text-xs text-muted-foreground">
                          {[row.city, row.region].filter(Boolean).join(", ")}
                          {row.license_number ? ` · ${row.license_number}` : ""}
                        </div>
                      </td>
                      <td className="p-3 capitalize">{row.business_type}</td>
                      <td className="p-3 whitespace-nowrap">
                        {formatReportDate(row.submitted_at)}
                      </td>
                      <td
                        className={`p-3 whitespace-nowrap ${tone === "urgent" ? "font-semibold text-destructive" : tone === "warning" ? "font-medium text-warning" : ""}`}
                      >
                        {waitingLabel(row.waiting_days)}
                      </td>
                      <td className="p-3">
                        <Badge variant={documentsComplete(row) ? "outline" : "secondary"}>
                          {row.docs_uploaded}/{row.docs_required}
                        </Badge>
                      </td>
                      <td className="p-3">
                        {row.status === "rejected" ? (
                          <Badge variant="destructive">Correction requested</Badge>
                        ) : row.is_resubmitted ? (
                          <Badge variant="secondary">Resubmitted</Badge>
                        ) : (
                          <Badge variant="outline">New</Badge>
                        )}
                      </td>
                      <td className="p-3 text-right">
                        <Button size="sm" variant="hero" onClick={() => setReviewing(row)}>
                          Review
                        </Button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </Card>
        )}

        {!loading && !error && total > PAGE_SIZE && (
          <div className="flex items-center justify-between text-sm text-muted-foreground">
            <span>
              Page {page + 1} of {pageCount} · {total} businesses
            </span>
            <div className="flex gap-2">
              <Button
                size="sm"
                variant="outline"
                disabled={page === 0}
                onClick={() => setPage((value) => value - 1)}
              >
                <ChevronLeft className="h-4 w-4" aria-hidden="true" />
                Previous
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={page + 1 >= pageCount}
                onClick={() => setPage((value) => value + 1)}
              >
                Next
                <ChevronRight className="h-4 w-4" aria-hidden="true" />
              </Button>
            </div>
          </div>
        )}

        <ReviewDialog
          row={reviewing}
          onClose={() => setReviewing(null)}
          onDone={() => void load()}
        />
      </main>
    </div>
  );
}
