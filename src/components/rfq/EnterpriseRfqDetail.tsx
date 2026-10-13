import { exportRfqDocument } from "@/lib/enterprise-rfq-documents";
import { RfqAttachments } from "./RfqAttachments";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { formatGHS } from "@/lib/format";
import {
  rfqCall,
  rfqDb,
  label,
  remainingRequirement,
  type EnterpriseRfq,
  type Requirement,
  type QuoteVersion,
  type AwardGroup,
  type Allocation,
} from "@/lib/enterprise-rfq";
import { EnterpriseQuoteEditor } from "./EnterpriseQuoteEditor";
import { RfqEvaluation } from "./RfqEvaluation";
import { RfqItemsTable } from "./RfqItemsTable";
import type { CreditInfo } from "./RfqQuoteOverview";
import { RfqSubmittedQuote } from "./RfqSubmittedQuote";
type Negotiation = {
  id: string;
  wholesaler_id: string;
  status: string;
  proposal: Record<string, string>;
  response: string | null;
};
export function EnterpriseRfqDetail({
  id,
  businessId,
  canManage,
  canProcess,
  onClose,
  onEdit,
  onChanged,
}: {
  id: string;
  businessId: string;
  canManage: boolean;
  canProcess: boolean;
  onClose: () => void;
  onEdit: (r: EnterpriseRfq, repeat: boolean) => void;
  onChanged: () => void;
}) {
  const [r, setR] = useState<EnterpriseRfq | null>(null);
  const [items, setItems] = useState<Requirement[]>([]);
  const [versions, setVersions] = useState<QuoteVersion[]>([]);
  const [groups, setGroups] = useState<AwardGroup[]>([]);
  const [allocations, setAllocations] = useState<Allocation[]>([]);
  const [negotiations, setNegotiations] = useState<Negotiation[]>([]);
  const [names, setNames] = useState<Record<string, string>>({});
  const [invites, setInvites] = useState<
    { wholesaler_id: string; response_status: string; viewed_at: string | null }[]
  >([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadCount, setLoadCount] = useState(0);
  const [quoteEdit, setQuoteEdit] = useState(false);
  const [credit, setCredit] = useState<CreditInfo[]>([]);
  const [reason, setReason] = useState("");
  const [deadline, setDeadline] = useState("");
  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const results = await Promise.all([
        rfqDb.from("rfqs").select("*").eq("id", id).single(),
        rfqDb.from("rfq_items").select("*").eq("rfq_id", id),
        rfqDb
          .from("rfq_quote_versions")
          .select("*")
          .eq("rfq_id", id)
          .order("version", { ascending: false }),
        rfqDb.from("rfq_confirmation_groups").select("*").eq("rfq_id", id),
        rfqDb.from("rfq_negotiations").select("*").eq("rfq_id", id),
        rfqDb.from("rfq_invitees").select("*").eq("rfq_id", id),
      ]);
      for (const result of results) if (result.error) throw new Error(result.error.message);
      setR(results[0].data);
      setItems(results[1].data);
      setVersions(results[2].data);
      setGroups(results[3].data);
      setNegotiations(results[4].data);
      setInvites(results[5].data);
      const gids = results[3].data.map((g: AwardGroup) => g.id);
      if (gids.length) {
        const a = await rfqDb.from("rfq_allocations").select("*").in("group_id", gids);
        if (a.error) throw new Error(a.error.message);
        setAllocations(a.data);
      } else setAllocations([]);
      const ids = [
        ...new Set<string>(results[5].data.map((i: { wholesaler_id: string }) => i.wholesaler_id)),
      ];
      if (ids.length) {
        const b = await rfqDb.from("businesses").select("id,name").in("id", ids);
        if (b.error) throw new Error(b.error.message);
        setNames(
          Object.fromEntries(b.data.map((b: { id: string; name: string }) => [b.id, b.name])),
        );
      }
      setLoadCount((n) => n + 1);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [id]);
  useEffect(() => {
    void load();
  }, [load]);
  const act = async (name: string, args: Record<string, unknown>) => {
    setBusy(true);
    setError("");
    try {
      const result = await rfqCall<{ error?: string }>(name, args);
      if (result?.error) throw new Error(result.error);
      await load();
      onChanged();
      return true;
    } catch (e) {
      setError((e as Error).message);
      return false;
    } finally {
      setBusy(false);
    }
  };
  const buyer = r?.pharmacy_id === businessId;
  const current = versions.filter(
    (v) => !versions.some((other) => other.quote_id === v.quote_id && other.version > v.version),
  );
  const mine = current.find((v) => v.wholesaler_id === businessId);
  useEffect(() => {
    if (buyer && canManage)
      void rfqCall<typeof credit>("rfq_credit_comparison", { p_rfq_id: id })
        .then(setCredit)
        .catch((e) => setError(e.message));
  }, [id, buyer, canManage]);
  useEffect(() => {
    if (r && !buyer && canProcess)
      void rfqCall("respond_rfq_invitation", {
        p_rfq_id: r.id,
        p_wholesaler_id: businessId,
        p_action: "view",
      }).catch(() => {});
  }, [r, businessId, buyer, canProcess]);
  const transition = (action: string) =>
    void act("rfq_transition", {
      p_rfq_id: id,
      p_action: action,
      p_revision: r?.revision,
      p_reason: reason,
      p_deadline: deadline ? new Date(deadline).toISOString() : null,
    });
  if (loading && !r) return <p role="status">Loading RFQ…</p>;
  if (!r)
    return (
      <div>
        <p role="alert">{error || "RFQ unavailable."}</p>
        <Button onClick={onClose}>Back</Button>
      </div>
    );
  return (
    <section className="space-y-5 rounded-xl border p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold">{r.title}</h2>
          <p>
            {r.reference} · {label(r.status)}
          </p>
          <p className="text-sm">
            Supplier access:{" "}
            {r.visibility === "open" ? "Open to approved wholesalers" : "Private invitations"}
          </p>
          <p className="text-sm">
            Deadline:{" "}
            {r.response_deadline ? new Date(r.response_deadline).toLocaleString() : "Not set"}
          </p>
        </div>
        <Button variant="outline" onClick={onClose}>
          Back to RFQs
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
      <p>{r.notes}</p>
      <p className="text-sm">
        Delivery: {r.delivery_location || "Pharmacy address"} ·{" "}
        {r.expected_delivery_date || "Date not specified"} · {r.delivery_instructions} · Payment
        preference: {label(r.payment_preference)}
      </p>
      <div className="flex flex-wrap gap-2">
        {buyer && canProcess && (
          <>
            <Button variant="outline" onClick={() => onEdit(r, true)}>
              Repeat as new draft
            </Button>
            {r.status === "draft" && (
              <>
                <Button variant="outline" onClick={() => onEdit(r, false)}>
                  Edit draft
                </Button>
                <Button
                  disabled={busy}
                  onClick={() =>
                    void act("publish_enterprise_rfq", { p_rfq_id: id, p_revision: r.revision })
                  }
                >
                  {r.visibility === "open" ? "Publish open RFQ" : "Publish private invitations"}
                </Button>
              </>
            )}
          </>
        )}
        {!buyer && canProcess && ["open", "partially_awarded"].includes(r.status) && (
          <>
            <Button
              disabled={busy}
              onClick={() =>
                void act("respond_rfq_invitation", {
                  p_rfq_id: id,
                  p_wholesaler_id: businessId,
                  p_action: "accepted",
                })
              }
            >
              {r.visibility === "open" ? "Register interest" : "Accept invitation"}
            </Button>
            <Button
              variant="outline"
              disabled={busy || !reason.trim()}
              onClick={() =>
                void act("respond_rfq_invitation", {
                  p_rfq_id: id,
                  p_wholesaler_id: businessId,
                  p_action: "declined",
                  p_reason: reason,
                })
              }
            >
              {r.visibility === "open" ? "Decline participation" : "Decline invitation with reason"}
            </Button>
            <Button onClick={() => setQuoteEdit((v) => !v)}>
              {quoteEdit ? "Close editor" : "Prepare / revise quote"}
            </Button>
          </>
        )}
      </div>
      <RfqItemsTable
        items={items}
        showRemaining={buyer}
        remaining={(i) => remainingRequirement(i, allocations, groups)}
      />
      {buyer && (
        <details>
          <summary>Invitation responses ({invites.length})</summary>
          {invites.map((i) => (
            <p key={i.wholesaler_id}>
              {names[i.wholesaler_id] ?? "Supplier"}: {i.response_status} ·{" "}
              {i.viewed_at ? "Viewed" : "Not yet viewed"}
            </p>
          ))}
        </details>
      )}
      {quoteEdit && !buyer && (
        <EnterpriseQuoteEditor
          key={`${id}:${mine?.version ?? 0}`}
          rfq={r}
          items={items}
          businessId={businessId}
          current={mine}
          onSaved={() => {
            setQuoteEdit(false);
            void load();
            onChanged();
          }}
        />
      )}
      {buyer ? (
        <RfqEvaluation
          key={loadCount}
          items={items}
          current={current}
          versions={versions}
          names={names}
          credit={credit}
          groups={groups}
          allocations={allocations}
          canManage={canManage}
          busy={busy}
          onAward={({ allocations: chosen, settlement }) =>
            act("propose_rfq_awards", {
              p_rfq_id: id,
              p_allocations: chosen,
              p_settlement_method: settlement,
              p_request_id: crypto.randomUUID(),
            })
          }
          onNegotiate={(v, term, value) =>
            act("rfq_negotiate", {
              p_rfq_id: id,
              p_wholesaler_id: v.wholesaler_id,
              p_version_id: v.id,
              p_proposal: { [term]: value },
            })
          }
          onPdf={(v) => void exportRfqDocument(id, "pdf", v.id).catch((e) => setError(e.message))}
        />
      ) : (
        current.map((v) => (
          <RfqSubmittedQuote
            key={v.id}
            version={v}
            history={versions.filter((old) => old.quote_id === v.quote_id)}
            items={items}
            onPdf={() => void exportRfqDocument(id, "pdf", v.id).catch((e) => setError(e.message))}
          />
        ))
      )}
      <div className="flex gap-2">
        <Button
          variant="outline"
          onClick={() => void exportRfqDocument(id, "pdf").catch((e) => setError(e.message))}
        >
          RFQ PDF
        </Button>
        <Button
          variant="outline"
          onClick={() => void exportRfqDocument(id, "xlsx").catch((e) => setError(e.message))}
        >
          RFQ Excel
        </Button>
      </div>
      <RfqAttachments rfqId={id} businessId={businessId} canUpload={!buyer && canProcess} />
      <h3 className="font-semibold">Awards and linked orders</h3>
      {groups.map((g) => (
        <div key={g.id} className="space-y-2 rounded border p-3">
          <p>
            {names[g.wholesaler_id] ?? "Supplier"} · {label(g.status)} ·{" "}
            {formatGHS(Number(g.goods_ghs) + Number(g.delivery_ghs))} · {label(g.settlement_method)}
          </p>
          {g.last_error && <p role="alert">{g.last_error}</p>}
          {g.reason && <p>{g.reason}</p>}
          <Button
            variant="outline"
            onClick={() =>
              void exportRfqDocument(id, "pdf", undefined, g.id).catch((e) => setError(e.message))
            }
          >
            Award PDF
          </Button>
          {g.order_id && (
            <a
              className="text-primary underline"
              href={`/${buyer ? "pharmacy" : "wholesaler"}?tab=orders`}
            >
              Open existing order management ({g.order_id.slice(0, 8)})
            </a>
          )}
          {!buyer && canProcess && ["pending", "conversion_failed"].includes(g.status) && (
            <div className="flex gap-2">
              <Button
                disabled={busy}
                onClick={() => void act("confirm_rfq_award", { p_group_id: g.id, p_accept: true })}
              >
                Confirm availability and create order
              </Button>
              <Button
                variant="outline"
                disabled={busy || !reason.trim()}
                onClick={() =>
                  void act("confirm_rfq_award", {
                    p_group_id: g.id,
                    p_accept: false,
                    p_reason: reason,
                  })
                }
              >
                Decline award
              </Button>
            </div>
          )}
        </div>
      ))}
      <h3 className="font-semibold">Negotiations</h3>
      {negotiations.map((n) => (
        <div key={n.id} className="rounded border p-3">
          <p>
            {names[n.wholesaler_id]} · {n.status}
          </p>
          <p>
            {Object.entries(n.proposal)
              .map(([k, v]) => `${k}: ${v}`)
              .join("; ")}
          </p>
          <p>{n.response}</p>
          {!buyer && canProcess && n.status === "requested" && (
            <div className="flex flex-wrap gap-2">
              {["accepted", "countered", "rejected"].map((action) => (
                <Button
                  key={action}
                  variant="outline"
                  disabled={busy || !reason.trim()}
                  onClick={() =>
                    void act("rfq_respond_negotiation", {
                      p_id: n.id,
                      p_action: action,
                      p_response: reason,
                      p_version_id: mine?.id ?? null,
                    })
                  }
                >
                  {label(action)}
                </Button>
              ))}
            </div>
          )}
        </div>
      ))}
      <label className="block space-y-1.5">
        <span className="text-sm font-medium">Reason</span>
        <Input
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Required to decline, respond to a negotiation, close requirements or cancel"
        />
      </label>
      {buyer && canManage && r.status !== "draft" && (
        <div className="flex flex-wrap items-end gap-2">
          <label>
            New quotation deadline
            <Input
              type="datetime-local"
              value={deadline}
              onChange={(e) => setDeadline(e.target.value)}
            />
          </label>
          <Button
            variant="outline"
            disabled={busy || !deadline}
            onClick={() => transition("extend")}
          >
            Extend deadline
          </Button>
          <Button
            variant="outline"
            disabled={busy || r.status !== "open"}
            onClick={() => transition("evaluate")}
          >
            Begin evaluation
          </Button>
          <Button
            variant="outline"
            disabled={busy || !reason.trim()}
            onClick={() => transition("cancel_remaining")}
          >
            Close remaining requirements
          </Button>
          <Button variant="outline" disabled={busy} onClick={() => transition("complete")}>
            Complete resolved RFQ
          </Button>
          <Button
            variant="outline"
            disabled={busy || !reason.trim()}
            onClick={() => transition("cancel")}
          >
            Cancel RFQ
          </Button>
        </div>
      )}
    </section>
  );
}
