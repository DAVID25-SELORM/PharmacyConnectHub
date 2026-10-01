import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { FileQuestion } from "lucide-react";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { DashboardHeader } from "@/components/DashboardShell";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { WholesalerRfqDetail } from "@/components/rfq/WholesalerRfqDetail";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { formatReportDate } from "@/lib/reports";
import {
  RFQ_QUOTE_STATUS_LABELS,
  RFQ_QUOTE_STATUS_STYLES,
  RFQ_STATUS_LABELS,
  RFQ_STATUS_STYLES,
  type Rfq,
  type RfqQuote,
} from "@/lib/rfq";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export const Route = createFileRoute("/wholesaler_/rfqs")({
  head: () => ({ meta: [{ title: "RFQs - Drugxone" }] }),
  component: () => (
    <WorkspaceGate>
      <WholesalerRfqsPage />
    </WorkspaceGate>
  ),
});

type PharmacyName = { id: string; name: string };

function WholesalerRfqsPage() {
  const { business } = useSession();
  const [rfqs, setRfqs] = useState<Rfq[]>([]);
  const [myQuotes, setMyQuotes] = useState<Record<string, RfqQuote>>({});
  const [pharmacies, setPharmacies] = useState<Record<string, PharmacyName>>({});
  const [loading, setLoading] = useState(true);
  const [detailRfqId, setDetailRfqId] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!business) return;
    setLoading(true);
    const { data: inviteeRows } = await db
      .from("rfq_invitees")
      .select("rfq_id")
      .eq("wholesaler_id", business.id);
    const rfqIds = ((inviteeRows as Array<{ rfq_id: string }> | null) ?? []).map((r) => r.rfq_id);
    if (rfqIds.length === 0) {
      setRfqs([]);
      setMyQuotes({});
      setLoading(false);
      return;
    }
    const [{ data: rfqData }, { data: quoteData }] = await Promise.all([
      db.from("rfqs").select("*").in("id", rfqIds).order("created_at", { ascending: false }),
      db.from("rfq_quotes").select("*").in("rfq_id", rfqIds).eq("wholesaler_id", business.id),
    ]);
    const rows = (rfqData as Rfq[] | null) ?? [];
    setRfqs(rows);
    const quoteMap: Record<string, RfqQuote> = {};
    for (const q of (quoteData as RfqQuote[] | null) ?? []) quoteMap[q.rfq_id] = q;
    setMyQuotes(quoteMap);

    const pharmacyIds = [...new Set(rows.map((r) => r.pharmacy_id))];
    if (pharmacyIds.length > 0) {
      const { data: bizData } = await supabase.from("businesses").select("id, name").in("id", pharmacyIds);
      const map: Record<string, PharmacyName> = {};
      for (const b of (bizData as PharmacyName[] | null) ?? []) map[b.id] = b;
      setPharmacies(map);
    }
    setLoading(false);
  }, [business]);

  useEffect(() => {
    void load();
  }, [load]);

  if (!business) return null;

  const canQuote =
    business.staff_role === "owner" ||
    business.staff_role === "manager" ||
    business.staff_role === "cashier" ||
    business.staff_role === "warehouse";

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="RFQs" showNav={true} />
      <main className="mx-auto max-w-5xl px-4 py-8 sm:px-6 lg:px-8">
        <h1 className="font-display text-2xl font-bold">Requests for quotation</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Pharmacies that invite you to quote appear here. Your quote stays private to you and the
          requesting pharmacy.
        </p>

        <div className="mt-6 space-y-3">
          {loading ? (
            <>
              <Skeleton className="h-20 w-full" />
              <Skeleton className="h-20 w-full" />
            </>
          ) : rfqs.length === 0 ? (
            <Card className="flex flex-col items-center gap-2 p-10 text-center text-muted-foreground">
              <FileQuestion className="h-8 w-8" />
              <p>No quote requests yet.</p>
            </Card>
          ) : (
            rfqs.map((rfq) => {
              const myQuote = myQuotes[rfq.id];
              return (
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
                      {myQuote && (
                        <Badge variant="secondary" className={`border ${RFQ_QUOTE_STATUS_STYLES[myQuote.status]}`}>
                          {RFQ_QUOTE_STATUS_LABELS[myQuote.status]}
                        </Badge>
                      )}
                    </div>
                  </div>
                  <div className="mt-1 text-sm text-muted-foreground">
                    {pharmacies[rfq.pharmacy_id]?.name ?? "Pharmacy"} · {rfq.reference}
                    {rfq.response_deadline ? ` · due ${formatReportDate(rfq.response_deadline)}` : ""}
                  </div>
                </Card>
              );
            })
          )}
        </div>
      </main>

      <WholesalerRfqDetail
        rfqId={detailRfqId}
        wholesalerId={business.id}
        canQuote={canQuote}
        open={detailRfqId !== null}
        onOpenChange={(open) => !open && setDetailRfqId(null)}
        onChanged={() => void load()}
      />
    </div>
  );
}
