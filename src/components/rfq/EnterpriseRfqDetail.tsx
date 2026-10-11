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
  compareVersions,
  remainingRequirement,
  type EnterpriseRfq,
  type Requirement,
  type QuoteVersion,
  type AwardGroup,
  type Allocation,
} from "@/lib/enterprise-rfq";
import { EnterpriseQuoteEditor } from "./EnterpriseQuoteEditor";
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
  const [quoteEdit, setQuoteEdit] = useState(false);
  const [selection, setSelection] = useState<Record<string, string>>({});
  const [accepted, setAccepted] = useState<Record<string, boolean>>({});
  const [category, setCategory] = useState("cash_private");
  const [payment, setPayment] = useState("cod");
  const [sort, setSort] = useState("cost");
  const [credit, setCredit] = useState<
    {
      wholesaler_id: string;
      payment_terms_days: number | null;
      available_ghs: number;
      status: string;
    }[]
  >([]);
  const [reason, setReason] = useState("");
  const [deadline, setDeadline] = useState("");
  const [negotiationTerm, setNegotiationTerm] = useState("price");
  const [confirm, setConfirm] = useState(false);
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
      setSelection({});
      setConfirm(false);
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
  const award = () => {
    const selected = current.flatMap((v) =>
      v.snapshot.items
        .filter((l) => Number(selection[l.id]) > 0)
        .map((l) => ({
          versionId: v.id,
          quoteItemId: l.id,
          quantity: Number(selection[l.id]),
          acceptAlternative: accepted[l.id] ?? false,
          category,
        })),
    );
    void act("propose_rfq_awards", {
      p_rfq_id: id,
      p_allocations: selected,
      p_settlement_method: payment,
      p_request_id: crypto.randomUUID(),
    });
  };
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
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr>
              <th>Medicine / specification</th>
              <th>Requested</th>
              {buyer && <th>Remaining</th>}
              <th>Shelf life</th>
            </tr>
          </thead>
          <tbody>
            {items.map((i) => (
              <tr key={i.id} className="border-t">
                <td className="min-w-48 py-2">
                  {i.product_name}
                  <p className="text-xs text-muted-foreground">
                    {Object.entries(i.specification)
                      .filter(([, v]) => v)
                      .map(([k, v]) => `${k}: ${v}`)
                      .join(" · ")}{" "}
                    {i.notes}
                    {i.cold_chain_required && <span> · Cold chain required</span>}
                    {i.special_handling && <span> · Handling: {i.special_handling}</span>}
                  </p>
                </td>
                <td>
                  {i.quantity} {i.unit}
                </td>
                {buyer && <td>{remainingRequirement(i, allocations, groups)}</td>}
                <td>{i.minimum_shelf_life_days} days</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
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
      <h3 className="font-semibold">
        {buyer ? "Compare quotations" : "Your submitted quotations"}
      </h3>
      <select
        aria-label="Sort quotations"
        className="rounded border p-2"
        value={sort}
        onChange={(e) => setSort(e.target.value)}
      >
        <option value="cost">Lowest landed total</option>
        <option value="delivery">Fastest stated delivery</option>
        <option value="quantity">Highest offered quantity</option>
        {buyer && canManage && <option value="credit">Longest approved credit term</option>}
      </select>
      <p className="text-xs text-muted-foreground">
        Sorting uses stated terms, not a recommendation of therapeutic suitability. Review
        specification differences, minimum orders and quantity coverage.
      </p>
      {(sort === "credit"
        ? [...current].sort(
            (a, b) =>
              (credit.find((c) => c.wholesaler_id === b.wholesaler_id && c.status === "active")
                ?.payment_terms_days ?? 0) -
                (credit.find((c) => c.wholesaler_id === a.wholesaler_id && c.status === "active")
                  ?.payment_terms_days ?? 0) || a.id.localeCompare(b.id),
          )
        : compareVersions(current, sort)
      ).map((v) => (
        <article key={v.id} className="space-y-2 rounded border p-3">
          <h4 className="font-semibold">
            {names[v.wholesaler_id] ?? "Supplier"} · revision {v.version}
          </h4>
          {credit
            .filter((c) => c.wholesaler_id === v.wholesaler_id)
            .map((c) => (
              <p key={c.wholesaler_id} className="text-xs">
                Credit account: {c.status} · {c.payment_terms_days ?? 0} days ·{" "}
                {formatGHS(c.available_ghs)} available. Eligibility is rechecked at confirmation.
              </p>
            ))}
          <p>
            {formatGHS(v.snapshot.quote.total_ghs)} goods +{" "}
            {formatGHS(v.snapshot.quote.delivery_charge_ghs)} delivery ·{" "}
            {v.snapshot.quote.lead_time_days ?? "Unspecified"} days · Valid until{" "}
            {v.snapshot.quote.valid_until}
          </p>
          <p>
            {v.snapshot.quote.payment_terms} · {v.snapshot.taxTreatment}
          </p>
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead>
                <tr>
                  <th>Offered medicine</th>
                  <th>Quantity</th>
                  <th>Final unit price</th>
                  <th>Expiry</th>
                  {buyer && canManage && <th>Award units</th>}
                </tr>
              </thead>
              <tbody>
                {v.snapshot.items.map((l) => (
                  <tr key={l.id} className="border-t">
                    <td className="min-w-56 py-2">
                      {String(l.offered_specification.name ?? "Product")}
                      <p className="text-xs">
                        Requested: {items.find((i) => i.id === l.rfq_item_id)?.product_name}
                      </p>
                      <p className="text-xs">
                        {["brand", "strength", "form", "pack"]
                          .map((k) => `${k}: ${l.offered_specification[k] ?? "not stated"}`)
                          .join(" · ")}
                      </p>
                      <p className="text-xs">
                        Lot: {l.batch_number || "Not stated"} · Available:{" "}
                        {l.expected_available_on || "not stated"} · Cold chain:{" "}
                        {l.cold_chain_supported ? "supplier confirmed" : "not confirmed"}
                        {l.special_handling ? ` · Handling: ${l.special_handling}` : ""}
                      </p>
                      <p className="text-xs">
                        Stock observed at quote submission:{" "}
                        {String(l.offered_specification.stockAtSubmission ?? "not recorded")} (not
                        reserved)
                      </p>
                      {l.alternative && (
                        <p className="font-medium text-amber-700">
                          Alternative: 1 offered unit = {l.requested_units_per_offered_unit}{" "}
                          requested units
                        </p>
                      )}
                    </td>
                    <td>{l.quantity}</td>
                    <td>{formatGHS(l.final_unit_price_ghs)}</td>
                    <td>{l.expiry_date}</td>
                    {buyer && canManage && (
                      <td className="min-w-28">
                        <Input
                          aria-label={`Award ${l.offered_specification.name}`}
                          type="number"
                          min="0"
                          max={l.quantity}
                          value={selection[l.id] ?? ""}
                          onChange={(e) => {
                            setSelection((s) => ({ ...s, [l.id]: e.target.value }));
                            setConfirm(false);
                          }}
                        />
                        {l.alternative && (
                          <label className="text-xs">
                            <input
                              type="checkbox"
                              checked={accepted[l.id] ?? false}
                              onChange={(e) =>
                                setAccepted((a) => ({ ...a, [l.id]: e.target.checked }))
                              }
                            />
                            Accept specification and conversion
                          </label>
                        )}
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {buyer && canManage && (
            <div className="flex flex-wrap gap-2">
              <Button
                variant="outline"
                onClick={() => {
                  setSelection(
                    Object.fromEntries(v.snapshot.items.map((l) => [l.id, String(l.quantity)])),
                  );
                  setConfirm(false);
                }}
              >
                Select whole quote
              </Button>
              <Button
                variant="outline"
                disabled={busy || !reason.trim()}
                onClick={() =>
                  void act("rfq_negotiate", {
                    p_rfq_id: id,
                    p_wholesaler_id: v.wholesaler_id,
                    p_version_id: v.id,
                    p_proposal: { [negotiationTerm]: reason.trim() },
                  })
                }
              >
                Request revised commercial terms
              </Button>
              <label className="text-sm">
                Requested change
                <select
                  aria-label="Negotiation term"
                  className="ml-2 rounded border p-2"
                  value={negotiationTerm}
                  onChange={(e) => setNegotiationTerm(e.target.value)}
                >
                  <option value="price">Unit price</option>
                  <option value="quantity">Quantity</option>
                  <option value="delivery">Delivery date or fee</option>
                  <option value="credit">Payment terms</option>
                  <option value="substitution">Product substitution</option>
                </select>
              </label>
            </div>
          )}
          <Button
            variant="outline"
            onClick={() =>
              void exportRfqDocument(id, "pdf", v.id).catch((e) => setError(e.message))
            }
          >
            Quotation PDF
          </Button>
          <details>
            <summary>Immutable revision history</summary>
            {versions
              .filter((old) => old.quote_id === v.quote_id)
              .map((old) => (
                <p key={old.id}>
                  Revision {old.version}: {formatGHS(old.snapshot.quote.total_ghs)} +{" "}
                  {formatGHS(old.snapshot.quote.delivery_charge_ghs)} · {old.reason} ·{" "}
                  {old.created_at}
                </p>
              ))}
          </details>
        </article>
      ))}
      {buyer && current.length > 0 && (
        <section className="space-y-2 rounded border p-3">
          <h4 className="font-semibold">Requirement-by-requirement comparison</h4>
          <p className="text-xs text-muted-foreground">
            Each supplier’s latest submitted version is compared. Alternatives remain subject to
            explicit review; stock shown is a submission-time observation, not a reservation.
            Catalogue matching does not independently verify regulatory authorization or
            registration.
          </p>
          <div className="overflow-x-auto">
            <table className="min-w-full text-left text-sm">
              <thead>
                <tr>
                  <th className="p-2">Requested medicine</th>
                  {current.map((v) => (
                    <th key={v.id} className="min-w-56 p-2">
                      {names[v.wholesaler_id] ?? "Supplier"} · v{v.version}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {items.map((item) => (
                  <tr key={item.id} className="border-t">
                    <th className="p-2 align-top">
                      {item.product_name}
                      <p className="text-xs font-normal">
                        {item.quantity} {item.unit}
                        {item.cold_chain_required ? " · cold chain required" : ""}
                        {item.special_handling ? ` · ${item.special_handling}` : ""}
                      </p>
                    </th>
                    {current.map((v) => {
                      const line = v.snapshot.items.find((entry) => entry.rfq_item_id === item.id);
                      return (
                        <td key={v.id} className="p-2 align-top">
                          {line ? (
                            <>
                              <p>
                                {String(line.offered_specification.name ?? "Product")}{" "}
                                {line.alternative ? "(proposed alternative)" : "(catalogue match)"}
                              </p>
                              <p>
                                {line.quantity} offered · {formatGHS(line.final_unit_price_ghs)} /
                                unit ·{" "}
                                {formatGHS(
                                  Number(line.quantity) * Number(line.final_unit_price_ghs),
                                )}{" "}
                                line
                              </p>
                              <p>
                                Expiry {line.expiry_date || "not stated"} · Available{" "}
                                {line.expected_available_on || "not stated"} · Lot{" "}
                                {line.batch_number || "not stated"}
                              </p>
                              <p>
                                Available{" "}
                                {String(
                                  line.offered_specification.stockAtSubmission ?? "not recorded",
                                )}{" "}
                                at submission · Cold chain{" "}
                                {line.cold_chain_supported ? "confirmed" : "not confirmed"}
                              </p>
                            </>
                          ) : (
                            <span>Not quoted</span>
                          )}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
      {buyer && canManage && current.length > 0 && (
        <div className="space-y-2 rounded border p-3">
          <div className="flex flex-wrap gap-3">
            <label>
              Order classification
              <select
                className="block rounded border p-2"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
              >
                {["cash_private", "nhis", "other"].map((c) => (
                  <option key={c}>{c}</option>
                ))}
              </select>
            </label>
            <label>
              Settlement
              <select
                className="block rounded border p-2"
                value={payment}
                onChange={(e) => setPayment(e.target.value)}
              >
                {["cod", "credit", "bank_transfer", "momo", "cheque", "other"].map((c) => (
                  <option key={c}>{c}</option>
                ))}
              </select>
            </label>
          </div>
          {confirm && (
            <p>
              Confirm {Object.values(selection).filter((q) => Number(q) > 0).length} selected
              allocations. Suppliers must confirm before orders are created. Unselected requirements
              remain unresolved.
            </p>
          )}
          <Button
            disabled={busy || !Object.values(selection).some((q) => Number(q) > 0)}
            onClick={() => (confirm ? award() : setConfirm(true))}
          >
            {confirm ? "Confirm pending awards" : "Review allocations"}
          </Button>
        </div>
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
      <label className="block">
        Reason / proposed commercial changes
        <Input
          type={
            negotiationTerm === "price"
              ? "number"
              : negotiationTerm === "quantity"
                ? "number"
                : negotiationTerm === "delivery"
                  ? "date"
                  : "text"
          }
          min={negotiationTerm === "price" || negotiationTerm === "quantity" ? "1" : undefined}
          step={
            negotiationTerm === "price" ? "0.01" : negotiationTerm === "quantity" ? "1" : undefined
          }
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder={
            negotiationTerm === "price"
              ? "Requested unit price in GHS"
              : negotiationTerm === "quantity"
                ? "Requested quantity"
                : "Required for decline, negotiation or cancellation"
          }
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
