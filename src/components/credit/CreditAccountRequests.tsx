import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { toast } from "sonner";
import { formatGHS } from "@/lib/format";
import { validateCreditForm } from "@/lib/credit-terms";

// These tables/RPCs are introduced by 20261017130000; regenerate database types after deployment.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;
type Request = {
  id: string;
  pharmacy_id: string;
  requested_limit: number;
  status: string;
  expires_at: string;
  reason: string | null;
  approved_limit: number | null;
  approved_days: number | null;
  pharmacy?: { name: string };
};

export function CreditRequestEligibility({ pharmacyId }: { pharmacyId: string }) {
  const [enabled, setEnabled] = useState(false);
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let alive = true;
    setReady(false);
    void db
      .from("credit_request_eligibility")
      .select("enabled")
      .eq("pharmacy_id", pharmacyId)
      .maybeSingle()
      .then(({ data, error }: { data: { enabled: boolean } | null; error: unknown }) => {
        if (alive && !error) {
          setEnabled(data?.enabled ?? false);
          setReady(true);
        }
      });
    return () => {
      alive = false;
    };
  }, [pharmacyId]);
  const change = async () => {
    setBusy(true);
    const { error } = await db.rpc("set_credit_request_eligibility", {
      p_pharmacy_id: pharmacyId,
      p_enabled: !enabled,
    });
    setBusy(false);
    if (error) return toast.error(error.message);
    setEnabled(!enabled);
    toast.success("Credit request eligibility updated.");
  };
  return (
    <div className="mt-3 space-y-2 text-sm">
      <p>
        Credit requests:{" "}
        {ready ? (enabled ? "Enabled" : "Disabled") : "Unavailable (check migration deployment)"}.
        Suppliers still approve limits and terms.
      </p>
      <Button variant="outline" size="sm" disabled={!ready || busy} onClick={() => void change()}>
        {enabled ? "Disable credit requests" : "Enable credit requests"}
      </Button>
    </div>
  );
}

export function PharmacyCreditRequest({
  pharmacyId,
  wholesalerId,
  amount,
  restricted,
  onApproved,
}: {
  pharmacyId: string;
  wholesalerId: string;
  amount: number;
  restricted: boolean;
  onApproved: () => void;
}) {
  const [enabled, setEnabled] = useState(false);
  const [request, setRequest] = useState<Request | null>(null);
  const [limit, setLimit] = useState(String(Math.ceil(amount)));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const load = useCallback(async () => {
    const [eligibility, result] = await Promise.all([
      db
        .from("credit_request_eligibility")
        .select("enabled")
        .eq("pharmacy_id", pharmacyId)
        .maybeSingle(),
      db
        .from("credit_account_requests")
        .select("*")
        .eq("pharmacy_id", pharmacyId)
        .eq("wholesaler_id", wholesalerId)
        .order("created_at", { ascending: false })
        .limit(1),
    ]);
    if (eligibility.error || result.error) {
      setError("Credit requests could not be loaded.");
      return;
    }
    setError("");
    setEnabled(eligibility.data?.enabled ?? false);
    setRequest(result.data?.[0] ?? null);
  }, [pharmacyId, wholesalerId]);
  useEffect(() => {
    void load();
  }, [load]);
  const submit = async () => {
    const parsed = validateCreditForm({ limit, days: "30" });
    if (parsed.error) return toast.error(parsed.error);
    setBusy(true);
    const { error: failure } = await db.rpc("request_credit_account", {
      p_pharmacy_id: pharmacyId,
      p_wholesaler_id: wholesalerId,
      p_limit: parsed.limit,
    });
    setBusy(false);
    if (failure) return toast.error(failure.message);
    toast.success("Credit account request sent to supplier.");
    void load();
  };
  if (error)
    return (
      <p role="alert">
        {error}{" "}
        <button className="underline" onClick={() => void load()}>
          Retry
        </button>
      </p>
    );
  if (!enabled && !request) return null;
  const pending =
    request?.status === "pending" && new Date(request.expires_at).getTime() > Date.now();
  return (
    <div className="mt-2 space-y-2 rounded-md border p-3">
      <p className="font-medium">Request an ongoing credit account</p>
      <p>
        Supplier approval is required. This requests an account, not an order. Your cart is not
        reserved or charged. After approval, refresh credit and place your order.
      </p>
      {request && (
        <p role="status">
          Latest request: {request.status === "pending" && !pending ? "expired" : request.status}
          {request.reason ? ` ? ${request.reason}` : ""}
          {request.status === "approved"
            ? ` ? ${formatGHS(request.approved_limit ?? 0)}, ${request.approved_days} days`
            : ""}
        </p>
      )}
      <Button
        size="sm"
        variant="outline"
        disabled={busy}
        onClick={() => {
          void load();
          onApproved();
        }}
      >
        Refresh credit status
      </Button>
      {enabled && !pending && !restricted && (
        <>
          <label className="block">
            Requested total credit limit (GHS)
            <Input
              type="number"
              min="0.01"
              max="10000000"
              step="0.01"
              value={limit}
              onChange={(e) => setLimit(e.target.value)}
            />
          </label>
          <Button size="sm" disabled={busy} onClick={() => void submit()}>
            {busy ? "Sending?" : "Request credit / limit increase"}
          </Button>
        </>
      )}
      {pending && (
        <p>
          Awaiting supplier approval. Expires {new Date(request!.expires_at).toLocaleDateString()}.
        </p>
      )}
      {restricted && <p>This supplier has restricted your credit. Contact them directly.</p>}
    </div>
  );
}

export function WholesalerCreditRequests({
  wholesalerId,
  onReviewed,
}: {
  wholesalerId: string;
  onReviewed: () => void;
}) {
  const [requests, setRequests] = useState<Request[]>([]);
  const [error, setError] = useState("");
  const load = useCallback(async () => {
    const { data, error: failure } = await db
      .from("credit_account_requests")
      .select("*,pharmacy:businesses!credit_account_requests_pharmacy_id_fkey(name)")
      .eq("wholesaler_id", wholesalerId)
      .eq("status", "pending")
      .order("created_at");
    if (failure) {
      setError("Credit requests could not be loaded. Check migration deployment or retry.");
      return;
    }
    setError("");
    setRequests(data ?? []);
  }, [wholesalerId]);
  useEffect(() => {
    void load();
  }, [load]);
  return (
    <Card className="p-5 space-y-3">
      <h2 className="text-xl font-bold">Credit account requests</h2>
      <Button size="sm" variant="outline" onClick={() => void load()}>
        Refresh requests
      </Button>
      {error ? (
        <p role="alert">{error}</p>
      ) : requests.length === 0 ? (
        <p>No pending requests.</p>
      ) : (
        requests.map((request) => (
          <ReviewRequest
            key={request.id}
            request={request}
            onDone={() => {
              void load();
              onReviewed();
            }}
          />
        ))
      )}
    </Card>
  );
}
function ReviewRequest({ request, onDone }: { request: Request; onDone: () => void }) {
  const [limit, setLimit] = useState(String(request.requested_limit));
  const [days, setDays] = useState("30");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const review = async (accept: boolean) => {
    if (accept) {
      const parsed = validateCreditForm({ limit, days });
      if (parsed.error) return toast.error(parsed.error);
    }
    setBusy(true);
    const { error } = await db.rpc("review_credit_account_request", {
      p_request_id: request.id,
      p_accept: accept,
      p_limit: accept ? Number(limit) : null,
      p_days: accept ? Number(days) : null,
      p_reason: reason.trim(),
    });
    setBusy(false);
    if (error) return toast.error(error.message);
    toast.success(accept ? "Ongoing credit account approved." : "Credit request rejected.");
    onDone();
  };
  const expired = new Date(request.expires_at).getTime() <= Date.now();
  return (
    <div className="rounded-md border p-3 space-y-3">
      <h3 className="font-semibold">{request.pharmacy?.name ?? "Pharmacy"}</h3>
      <p>
        Requested limit: {formatGHS(request.requested_limit)}.{" "}
        {expired
          ? "Expired ? reject to close."
          : "Acceptance creates or updates an ongoing account; it does not place an order."}
      </p>
      <p className="text-sm">
        Review this pharmacy?s outstanding balance and payment history below before approving. The
        new limit replaces any existing limit.
      </p>
      <label className="block">
        Approved total limit (GHS)
        <Input type="number" value={limit} onChange={(e) => setLimit(e.target.value)} />
      </label>
      <label className="block">
        Payment terms (days)
        <Input
          type="number"
          min="1"
          max="365"
          value={days}
          onChange={(e) => setDays(e.target.value)}
        />
      </label>
      <label className="block">
        Decision reason (shared with pharmacy)
        <Input maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
      </label>
      <div className="flex gap-2">
        <Button
          disabled={busy || expired || reason.trim().length < 5}
          onClick={() => void review(true)}
        >
          Approve ongoing account
        </Button>
        <Button
          variant="outline"
          disabled={busy || reason.trim().length < 5}
          onClick={() => void review(false)}
        >
          Reject request
        </Button>
      </div>
    </div>
  );
}
