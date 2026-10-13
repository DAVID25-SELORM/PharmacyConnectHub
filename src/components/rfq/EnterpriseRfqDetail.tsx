import { exportRfqDocument } from "@/lib/enterprise-rfq-documents";
import { RfqAttachments } from "./RfqAttachments";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  rfqCall,
  rfqDb,
  remainingRequirement,
  type EnterpriseRfq,
  type Requirement,
  type QuoteVersion,
  type AwardGroup,
  type Allocation,
} from "@/lib/enterprise-rfq";
import { EnterpriseQuoteEditor } from "./EnterpriseQuoteEditor";
import { RfqAwards } from "./RfqAwards";
import { RfqDetailHeader } from "./RfqDetailHeader";
import { RfqEvaluation } from "./RfqEvaluation";
import { RfqInvitations, type Invitation } from "./RfqInvitations";
import { RfqItemsTable } from "./RfqItemsTable";
import { RfqManageMenu } from "./RfqManageMenu";
import { RfqNegotiations, type Negotiation } from "./RfqNegotiations";
import type { CreditInfo } from "./RfqQuoteOverview";
import { RfqReasonDialog } from "./RfqReasonDialog";
import { RfqSubmittedQuote } from "./RfqSubmittedQuote";

/** An action that is waiting for the person to give a reason, a response or a date. */
type Pending =
  | { kind: "decline_invitation" }
  | { kind: "decline_award"; group: AwardGroup }
  | { kind: "respond"; negotiation: Negotiation; action: string }
  | { kind: "extend" }
  | { kind: "close_remaining" }
  | { kind: "cancel" };

const RESPONSE_WORDS: Record<string, string> = {
  accepted: "Accept",
  countered: "Counter",
  rejected: "Reject",
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
  const [invites, setInvites] = useState<Invitation[]>([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadCount, setLoadCount] = useState(0);
  const [quoteEdit, setQuoteEdit] = useState(false);
  const [credit, setCredit] = useState<CreditInfo[]>([]);
  const [pending, setPending] = useState<Pending | null>(null);
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
  const transition = (action: string, extra: { reason?: string; deadline?: string } = {}) =>
    act("rfq_transition", {
      p_rfq_id: id,
      p_action: action,
      p_revision: r?.revision,
      p_reason: extra.reason ?? "",
      p_deadline: extra.deadline ? new Date(extra.deadline).toISOString() : null,
    });
  const download = (promise: Promise<unknown>) => void promise.catch((e) => setError(e.message));

  if (loading && !r)
    return (
      <Card>
        <CardContent className="p-8 text-sm text-muted-foreground" role="status">
          Loading request…
        </CardContent>
      </Card>
    );
  if (!r)
    return (
      <Card>
        <CardContent className="space-y-3 p-8">
          <p role="alert" className="text-destructive">
            {error || "This request is unavailable."}
          </p>
          <Button type="button" variant="outline" onClick={onClose}>
            Back to requests
          </Button>
        </CardContent>
      </Card>
    );

  const supplierActive = !buyer && canProcess && ["open", "partially_awarded"].includes(r.status);
  const quoteCount = current.length;

  return (
    <div className="space-y-6">
      <RfqDetailHeader
        rfq={r}
        quoteCount={quoteCount}
        onBack={onClose}
        actions={
          <>
            {buyer && canProcess && (
              <>
                <Button type="button" variant="outline" onClick={() => onEdit(r, true)}>
                  Repeat as new draft
                </Button>
                {r.status === "draft" && (
                  <>
                    <Button type="button" variant="outline" onClick={() => onEdit(r, false)}>
                      Edit draft
                    </Button>
                    <Button
                      type="button"
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
            {buyer && canManage && r.status !== "draft" && (
              <RfqManageMenu
                status={r.status}
                busy={busy}
                onExtend={() => setPending({ kind: "extend" })}
                onEvaluate={() => void transition("evaluate")}
                onCloseRemaining={() => setPending({ kind: "close_remaining" })}
                onComplete={() => void transition("complete")}
                onCancel={() => setPending({ kind: "cancel" })}
              />
            )}
            {supplierActive && (
              <>
                <Button
                  type="button"
                  variant="outline"
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
                  type="button"
                  variant="outline"
                  disabled={busy}
                  onClick={() => setPending({ kind: "decline_invitation" })}
                >
                  {r.visibility === "open" ? "Decline participation…" : "Decline invitation…"}
                </Button>
                <Button type="button" onClick={() => setQuoteEdit((v) => !v)}>
                  {quoteEdit ? "Close quotation editor" : "Prepare / revise quote"}
                </Button>
              </>
            )}
          </>
        }
      />

      {error && (
        <p
          role="alert"
          className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
        >
          {error}
        </p>
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

      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Requested medicines</CardTitle>
        </CardHeader>
        <CardContent>
          <RfqItemsTable
            items={items}
            showRemaining={buyer}
            remaining={(i) => remainingRequirement(i, allocations, groups)}
          />
        </CardContent>
      </Card>

      {buyer && <RfqInvitations invites={invites} names={names} />}

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
          onPdf={(v) => download(exportRfqDocument(id, "pdf", v.id))}
        />
      ) : (
        current.map((v) => (
          <RfqSubmittedQuote
            key={v.id}
            version={v}
            history={versions.filter((old) => old.quote_id === v.quote_id)}
            items={items}
            onPdf={() => download(exportRfqDocument(id, "pdf", v.id))}
          />
        ))
      )}

      <RfqAwards
        groups={groups}
        allocations={allocations}
        names={names}
        buyer={buyer}
        canConfirm={canProcess}
        busy={busy}
        onPdf={(g) => download(exportRfqDocument(id, "pdf", undefined, g.id))}
        onConfirm={(g) => void act("confirm_rfq_award", { p_group_id: g.id, p_accept: true })}
        onDecline={(g) => setPending({ kind: "decline_award", group: g })}
      />

      <RfqNegotiations
        negotiations={negotiations}
        names={names}
        buyer={buyer}
        canRespond={canProcess}
        busy={busy}
        onRespond={(negotiation, action) => setPending({ kind: "respond", negotiation, action })}
      />

      <RfqAttachments
        rfqId={id}
        businessId={businessId}
        canUpload={!buyer && canProcess}
        exports={
          <>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => download(exportRfqDocument(id, "pdf"))}
            >
              Request PDF
            </Button>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => download(exportRfqDocument(id, "xlsx"))}
            >
              Request Excel
            </Button>
          </>
        }
      />

      {pending?.kind === "decline_invitation" && (
        <RfqReasonDialog
          title={r.visibility === "open" ? "Decline participation" : "Decline this invitation"}
          description="The buyer sees your reason."
          label="Reason"
          placeholder="Why you cannot quote on this request"
          confirmLabel="Decline"
          destructive
          busy={busy}
          onClose={() => setPending(null)}
          onSubmit={(reason) =>
            act("respond_rfq_invitation", {
              p_rfq_id: id,
              p_wholesaler_id: businessId,
              p_action: "declined",
              p_reason: reason,
            })
          }
        />
      )}
      {pending?.kind === "decline_award" && (
        <RfqReasonDialog
          title="Decline this award"
          description="No order is created. The buyer sees your reason."
          label="Reason"
          placeholder="Why you cannot supply this award"
          confirmLabel="Decline award"
          destructive
          busy={busy}
          onClose={() => setPending(null)}
          onSubmit={(reason) =>
            act("confirm_rfq_award", {
              p_group_id: pending.group.id,
              p_accept: false,
              p_reason: reason,
            })
          }
        />
      )}
      {pending?.kind === "respond" && (
        <RfqReasonDialog
          title={`${RESPONSE_WORDS[pending.action] ?? "Respond to"} this request`}
          description="Your reply is sent to the buyer with your decision."
          label="Your reply"
          placeholder={
            pending.action === "countered"
              ? "What you can offer instead"
              : "A short note for the buyer"
          }
          confirmLabel={RESPONSE_WORDS[pending.action] ?? "Send"}
          busy={busy}
          onClose={() => setPending(null)}
          onSubmit={(response) =>
            act("rfq_respond_negotiation", {
              p_id: pending.negotiation.id,
              p_action: pending.action,
              p_response: response,
              p_version_id: mine?.id ?? null,
            })
          }
        />
      )}
      {pending?.kind === "extend" && (
        <RfqReasonDialog
          title="Extend the quotation deadline"
          description="Suppliers can quote until the new date and time."
          label="New deadline"
          inputType="datetime-local"
          confirmLabel="Extend deadline"
          busy={busy}
          onClose={() => setPending(null)}
          onSubmit={(deadline) => transition("extend", { deadline })}
        />
      )}
      {pending?.kind === "close_remaining" && (
        <RfqReasonDialog
          title="Close the remaining requirements"
          description="Requirements that have not been awarded stop waiting for quotations."
          label="Reason"
          placeholder="Why the remaining requirements are being closed"
          confirmLabel="Close remaining requirements"
          busy={busy}
          onClose={() => setPending(null)}
          onSubmit={(reason) => transition("cancel_remaining", { reason })}
        />
      )}
      {pending?.kind === "cancel" && (
        <RfqReasonDialog
          title="Cancel this request"
          description="Suppliers are told the request is cancelled."
          label="Reason"
          placeholder="Why the request is being cancelled"
          confirmLabel="Cancel request"
          destructive
          busy={busy}
          onClose={() => setPending(null)}
          onSubmit={(reason) => transition("cancel", { reason })}
        />
      )}
    </div>
  );
}
