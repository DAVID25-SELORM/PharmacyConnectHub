import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { FileQuestion, Plus } from "lucide-react";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { DashboardHeader } from "@/components/DashboardShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { CreateRfqDialog } from "@/components/rfq/CreateRfqDialog";
import { PharmacyRfqDetail } from "@/components/rfq/PharmacyRfqDetail";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { formatReportDate } from "@/lib/reports";
import { RFQ_STATUS_LABELS, RFQ_STATUS_STYLES, type Rfq } from "@/lib/rfq";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export const Route = createFileRoute("/pharmacy_/rfqs")({
  head: () => ({ meta: [{ title: "RFQs - Drugxone" }] }),
  component: () => (
    <WorkspaceGate>
      <PharmacyRfqsPage />
    </WorkspaceGate>
  ),
});

function PharmacyRfqsPage() {
  const { business } = useSession();
  const [rfqs, setRfqs] = useState<Rfq[]>([]);
  const [quoteCounts, setQuoteCounts] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [createOpen, setCreateOpen] = useState(false);
  const [detailRfqId, setDetailRfqId] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!business) return;
    setLoading(true);
    const { data } = await db
      .from("rfqs")
      .select("*")
      .eq("pharmacy_id", business.id)
      .order("created_at", { ascending: false });
    const rows = (data as Rfq[] | null) ?? [];
    setRfqs(rows);
    if (rows.length > 0) {
      const { data: quoteRows } = await db
        .from("rfq_quotes")
        .select("rfq_id, status")
        .in("rfq_id", rows.map((r) => r.id))
        .neq("status", "withdrawn");
      const counts: Record<string, number> = {};
      for (const q of (quoteRows as Array<{ rfq_id: string }> | null) ?? []) {
        counts[q.rfq_id] = (counts[q.rfq_id] ?? 0) + 1;
      }
      setQuoteCounts(counts);
    } else {
      setQuoteCounts({});
    }
    setLoading(false);
  }, [business]);

  useEffect(() => {
    void load();
  }, [load]);

  if (!business) return null;

  const canCreate = business.staff_role === "owner" || business.staff_role === "manager" || business.staff_role === "cashier";
  const canAward = business.staff_role === "owner" || business.staff_role === "manager";

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="RFQs" showNav={true} />
      <main className="mx-auto max-w-5xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="font-display text-2xl font-bold">Requests for quotation</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Ask specific suppliers to quote on a list of items, then compare and accept the best
              offer.
            </p>
          </div>
          {canCreate && (
            <Button type="button" onClick={() => setCreateOpen(true)}>
              <Plus className="mr-1.5 h-4 w-4" />
              New RFQ
            </Button>
          )}
        </div>

        <div className="mt-6 space-y-3">
          {loading ? (
            <>
              <Skeleton className="h-20 w-full" />
              <Skeleton className="h-20 w-full" />
            </>
          ) : rfqs.length === 0 ? (
            <Card className="flex flex-col items-center gap-2 p-10 text-center text-muted-foreground">
              <FileQuestion className="h-8 w-8" />
              <p>No RFQs yet. Request a quote to get started.</p>
            </Card>
          ) : (
            rfqs.map((rfq) => (
              <Card
                key={rfq.id}
                className="cursor-pointer p-4 transition-colors hover:border-primary/40"
                onClick={() => setDetailRfqId(rfq.id)}
                role="button"
                tabIndex={0}
                onKeyDown={(e) => e.key === "Enter" && setDetailRfqId(rfq.id)}
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <span className="font-medium">{rfq.title}</span>
                    <Badge variant="secondary" className={`border ${RFQ_STATUS_STYLES[rfq.status]}`}>
                      {RFQ_STATUS_LABELS[rfq.status]}
                    </Badge>
                  </div>
                  <span className="text-sm text-muted-foreground">
                    {quoteCounts[rfq.id] ?? 0} quote{(quoteCounts[rfq.id] ?? 0) === 1 ? "" : "s"}
                  </span>
                </div>
                <div className="mt-1 text-sm text-muted-foreground">
                  {rfq.reference} · Requested {formatReportDate(rfq.created_at)}
                  {rfq.response_deadline ? ` · due ${formatReportDate(rfq.response_deadline)}` : ""}
                </div>
              </Card>
            ))
          )}
        </div>
      </main>

      <CreateRfqDialog
        pharmacyId={business.id}
        open={createOpen}
        onOpenChange={setCreateOpen}
        onCreated={() => void load()}
      />
      <PharmacyRfqDetail
        rfqId={detailRfqId}
        canAward={canAward}
        canCancel={canCreate}
        open={detailRfqId !== null}
        onOpenChange={(open) => !open && setDetailRfqId(null)}
        onChanged={() => void load()}
      />
    </div>
  );
}
