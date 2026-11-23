import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { AdminNav } from "@/components/admin/AdminNav";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Textarea } from "@/components/ui/textarea";
import { confirmAction } from "@/lib/confirm-action";
import {
  REQUEST_KIND_LABEL,
  REQUEST_STATUS_LABEL,
  adminAnonymiseUser,
  adminListDataRequests,
  adminResolveDataRequest,
  daysUntilDue,
  type AdminDataRequest,
} from "@/lib/privacy";

export const Route = createFileRoute("/admin/privacy")({
  head: () => ({ meta: [{ title: "Privacy requests - Drugxone" }] }),
  component: AdminPrivacyPage,
});

function AdminPrivacyPage() {
  const [requests, setRequests] = useState<AdminDataRequest[] | null>(null);

  const load = useCallback(async () => setRequests(await adminListDataRequests()), []);
  useEffect(() => {
    void load();
  }, [load]);

  const open = (requests ?? []).filter((r) => r.status === "open" || r.status === "in_progress");
  const closed = (requests ?? []).filter(
    (r) => r.status === "completed" || r.status === "declined",
  );

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Privacy requests" isAdmin={true} />
      <AdminNav />
      <main className="mx-auto max-w-4xl space-y-6 px-4 py-8 sm:px-6 lg:px-8">
        <div>
          <h1 className="font-display text-2xl font-bold">Privacy requests</h1>
          <p className="text-sm text-muted-foreground">
            People asking for their data to be deleted or corrected. Each needs a reply within 30
            days. Removing a person deletes their sign-in and personal details; orders, invoices and
            the audit trail stay under the name "Deleted user".
          </p>
        </div>

        {requests === null ? (
          <p className="text-sm text-muted-foreground">Loading...</p>
        ) : (
          <>
            <section className="space-y-3" aria-label="Open requests">
              <h2 className="font-semibold">Open ({open.length})</h2>
              {open.length === 0 && (
                <p className="text-sm text-muted-foreground">No open requests.</p>
              )}
              {open.map((request) => (
                <RequestCard key={request.id} request={request} onChanged={load} />
              ))}
            </section>
            {closed.length > 0 && (
              <section className="space-y-3" aria-label="Closed requests">
                <h2 className="font-semibold">Closed</h2>
                {closed.map((request) => (
                  <RequestCard key={request.id} request={request} onChanged={load} />
                ))}
              </section>
            )}
          </>
        )}
      </main>
    </div>
  );
}

function RequestCard({
  request,
  onChanged,
}: {
  request: AdminDataRequest;
  onChanged: () => Promise<void>;
}) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const isOpen = request.status === "open" || request.status === "in_progress";
  const days = daysUntilDue(request.due_at);
  const blockedByBusiness = request.owned_businesses.length > 0;

  const run = async (work: () => Promise<string | null>, success: string) => {
    setBusy(true);
    const message = await work();
    setBusy(false);
    if (message) {
      toast.error(message);
      return;
    }
    toast.success(success);
    setNote("");
    await onChanged();
  };

  const remove = async () => {
    if (!request.user_id) return;
    const ok = await confirmAction(
      `Remove ${request.email ?? "this person"}? Their sign-in and personal details are deleted and this cannot be undone. Business records stay under "Deleted user".`,
    );
    if (!ok) return;
    await run(
      () => adminAnonymiseUser(request.user_id as string, request.id, note),
      "Person removed and the request closed.",
    );
  };

  return (
    <Card className="space-y-3 p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="font-medium">{request.email ?? "Removed person"}</p>
          <p className="text-sm text-muted-foreground">
            {REQUEST_KIND_LABEL[request.kind]} · sent{" "}
            {new Date(request.created_at).toLocaleDateString()}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {isOpen && (
            <Badge variant={days < 0 ? "destructive" : days <= 7 ? "secondary" : "outline"}>
              {days < 0 ? `${-days} days late` : `${days} days left`}
            </Badge>
          )}
          <Badge variant="outline">{REQUEST_STATUS_LABEL[request.status]}</Badge>
        </div>
      </div>

      {request.reason && <p className="rounded bg-muted px-3 py-2 text-sm">{request.reason}</p>}
      {request.resolution_note && (
        <p className="text-sm">
          <span className="text-muted-foreground">Reply: </span>
          {request.resolution_note}
        </p>
      )}

      {isOpen && (
        <div className="space-y-2">
          {blockedByBusiness && (
            <p className="text-sm text-amber-700">
              Owns {request.owned_businesses.join(", ")}. The business must be handed over or closed
              before this person can be removed.
            </p>
          )}
          {request.is_admin && (
            <p className="text-sm text-amber-700">
              This person is a platform admin. Remove their platform access first.
            </p>
          )}
          <Textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Note to the person (required to decline)"
            rows={2}
            maxLength={1000}
            aria-label="Note to the person"
          />
          <div className="flex flex-wrap gap-2">
            {request.status === "open" && (
              <Button
                variant="outline"
                size="sm"
                disabled={busy}
                onClick={() =>
                  void run(
                    () => adminResolveDataRequest(request.id, "in_progress", note),
                    "Marked as being handled.",
                  )
                }
              >
                Start handling
              </Button>
            )}
            {request.kind === "deletion" ? (
              <Button
                variant="destructive"
                size="sm"
                disabled={busy || blockedByBusiness || request.is_admin || !request.user_id}
                onClick={() => void remove()}
              >
                Remove this person
              </Button>
            ) : (
              <Button
                variant="outline"
                size="sm"
                disabled={busy}
                onClick={() =>
                  void run(
                    () => adminResolveDataRequest(request.id, "completed", note),
                    "Request closed.",
                  )
                }
              >
                Mark done
              </Button>
            )}
            <Button
              variant="ghost"
              size="sm"
              disabled={busy || !note.trim()}
              onClick={() =>
                void run(
                  () => adminResolveDataRequest(request.id, "declined", note),
                  "Request declined.",
                )
              }
            >
              Decline with reason
            </Button>
          </div>
        </div>
      )}
    </Card>
  );
}
