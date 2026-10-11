import { WorkspaceProcurementReport } from "./WorkspaceProcurementReport";
import { SupplierProfile } from "./SupplierProfile";
import { useEffect, useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { useSession } from "@/hooks/use-session";
import { downloadPdf, downloadXlsx, downloadCsv, rowsToCsv, formatGHSCell } from "@/lib/reports";
import {
  CHANNELS,
  SOURCES,
  DOCUMENTS,
  db,
  externalRpc,
  today,
  label,
  emptyFilters,
  newDraft,
  newLine,
  validateDraft,
  draftTotal,
  draftFromPurchase,
  riskSignals,
  purchaseSheet,
  traceabilitySheets,
  type Context,
  type Draft,
  type Detail,
  type PurchaseList,
  type Purchase,
  type Analytics,
  type Line,
  type Contact,
} from "@/lib/external-procurement";

const panel = "rounded-xl border bg-card p-4 sm:p-6 space-y-4";
const selectClass =
  "flex min-h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm";
function Field({ title, children }: { title: string; children: ReactNode }) {
  return (
    <label className="block min-w-0 space-y-1 text-sm font-medium">
      <span>{title}</span>
      {children}
    </label>
  );
}
function Choice({
  title,
  value,
  onChange,
  options,
  empty,
}: {
  title: string;
  value: string;
  onChange: (s: string) => void;
  options: Record<string, string>;
  empty?: string;
}) {
  return (
    <Field title={title}>
      <select
        aria-label={title}
        className={selectClass}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        {empty !== undefined && <option value="">{empty}</option>}
        {Object.entries(options).map(([v, l]) => (
          <option key={v} value={v}>
            {l}
          </option>
        ))}
      </select>
    </Field>
  );
}
const contactOptions = (c: Contact[]) =>
  Object.fromEntries(c.map((x) => [x.id, `${x.name}${x.phone ? ` · ${x.phone}` : ""}`]));
const message = (e: unknown) =>
  e instanceof Error ? e.message : "Something went wrong. Please retry.";

export function ExternalProcurement({
  initial,
}: {
  initial?: { q?: string; review?: string; payment?: string; view?: string };
}) {
  const { business } = useSession();
  const [context, setContext] = useState<Context | null>(null),
    [list, setList] = useState<PurchaseList | null>(null),
    [error, setError] = useState("");
  const [filters, setFilters] = useState({
      ...emptyFilters,
      q: initial?.q ?? "",
      review: initial?.review ?? "",
      payment: initial?.payment ?? "",
    }),
    [offset, setOffset] = useState(0),
    [tab, setTab] = useState(initial?.view ?? "purchases"),
    [busy, setBusy] = useState(false);
  const [detail, setDetail] = useState<Detail | null>(null),
    [draft, setDraft] = useState<Draft | null>(null),
    [editing, setEditing] = useState<Detail | null>(null),
    [request, setRequest] = useState(crypto.randomUUID());
  const [contactKind, setContactKind] = useState<"person" | "company" | null>(null),
    [analytics, setAnalytics] = useState<Analytics | null>(null),
    [revision, setRevision] = useState(0);
  const reload = () => setRevision((x) => x + 1);
  useEffect(() => {
    let live = true;
    if (!business) return;
    setError("");
    setList(null);
    Promise.all([
      externalRpc<Context>("external_procurement_context", { p_pharmacy_id: business.id }),
      externalRpc<PurchaseList>("list_external_purchases", {
        p_pharmacy_id: business.id,
        p_filters: filters,
        p_offset: offset,
      }),
    ])
      .then(([c, l]) => {
        if (live) {
          setContext(c);
          setList(l);
        }
      })
      .catch((e) => {
        if (live) setError(message(e));
      });
    return () => {
      live = false;
    };
  }, [business, filters, offset, revision]);
  useEffect(() => {
    let live = true;
    if (!business || tab !== "history") return;
    setAnalytics(null);
    externalRpc<Analytics>("external_procurement_analytics", {
      p_pharmacy_id: business.id,
      p_from: filters.from || null,
      p_to: filters.to || null,
      p_query: filters.q,
      p_filters: filters,
      p_offset: offset,
      p_limit: 30,
    })
      .then((a) => {
        if (live) setAnalytics(a);
      })
      .catch((e) => {
        if (live) setError(message(e));
      });
    return () => {
      live = false;
    };
  }, [business, tab, filters, offset, revision]);
  async function run(action: () => Promise<void>) {
    setBusy(true);
    try {
      await action();
      setError("");
    } catch (e) {
      toast.error(message(e));
    } finally {
      setBusy(false);
    }
  }
  async function open(id: string) {
    setDetail(await externalRpc<Detail>("get_external_purchase", { p_id: id }));
  }
  function filter(k: keyof typeof filters, v: string) {
    setFilters((f) => ({ ...f, [k]: v }));
    setOffset(0);
  }
  async function exportPurchases(format: "csv" | "xlsx") {
    if (!business) return;
    const rows: Purchase[] = [];
    let page = 0;
    let total = Infinity;
    while (rows.length < total) {
      const data = await externalRpc<PurchaseList>("list_external_purchases", {
        p_pharmacy_id: business.id,
        p_filters: filters,
        p_offset: page,
        p_limit: 200,
      });
      total = data.summary.count;
      if (!data.rows.length) break;
      rows.push(...data.rows);
      page += data.rows.length;
    }
    const sheet = purchaseSheet(rows);
    if (format === "csv")
      downloadCsv("external-procurement.csv", rowsToCsv(sheet.headers, sheet.rows));
    else await downloadXlsx("external-procurement.xlsx", [sheet]);
  }
  async function exportHistory() {
    if (!business) return;
    const rows: Analytics["rows"] = [];
    let page = 0;
    while (true) {
      const data = await externalRpc<Analytics>("external_procurement_analytics", {
        p_pharmacy_id: business.id,
        p_from: filters.from || null,
        p_to: filters.to || null,
        p_query: filters.q,
        p_filters: filters,
        p_offset: page,
        p_limit: 200,
      });
      rows.push(...data.rows);
      page += data.rows.length;
      if (!data.rows.length || page >= data.count) break;
    }
    await downloadXlsx("procurement-history.xlsx", [
      {
        name: "Procurement history",
        headers: [
          "Reference",
          "Date",
          "Channel",
          "Product",
          "Manufacturer",
          "Supplier",
          "Source",
          "Quantity",
          "Returned",
          "Unit cost GHS",
          "Batches",
          "Review",
        ],
        rows: rows.map((r) => [
          r.reference,
          r.date,
          r.channel,
          r.product,
          r.manufacturer ?? "",
          r.seller ?? "",
          r.source ?? "",
          r.quantity,
          r.returned,
          r.unit_cost,
          r.batches ?? "",
          r.review,
        ]),
      },
    ]);
  }
  if (!business) return null;
  return (
    <>
      <DashboardHeader subtitle="External procurement" showNav />
      <main className="mx-auto max-w-7xl space-y-6 p-4 sm:p-6">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold">External procurement</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Record receipts, establish their source and review stock before release.
            </p>
            <p className="text-xs text-muted-foreground">
              Verification labels describe DrugXOne workflow, not legal compliance.
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" asChild>
              <Link to="/pharmacy">DrugXOne marketplace</Link>
            </Button>
            {context?.can_record && (
              <Button
                onClick={() => {
                  setEditing(null);
                  setDraft(newDraft());
                  setRequest(crypto.randomUUID());
                }}
              >
                Record external purchase
              </Button>
            )}
          </div>
        </div>
        {error && (
          <div role="alert" className="rounded-lg border border-destructive p-4 text-destructive">
            {error}
            <Button variant="outline" className="ml-3" onClick={reload}>
              Retry
            </Button>
          </div>
        )}
        <nav className="flex flex-wrap gap-2" aria-label="Procurement sections">
          {[
            "purchases",
            "suppliers",
            "history",
            "workspaces",
            ...(context?.is_owner ? ["settings"] : []),
          ].map((t) => (
            <Button
              key={t}
              variant={tab === t ? "default" : "outline"}
              onClick={() => {
                setTab(t);
                setOffset(0);
              }}
            >
              {t === "history" ? "Product procurement history" : label(t)}
            </Button>
          ))}
        </nav>
        {(tab === "purchases" || tab === "history") && (
          <section className={panel}>
            <div className="grid gap-3 sm:grid-cols-3">
              <Field
                title={
                  tab === "history"
                    ? "Product, supplier, batch or manufacturer"
                    : "Search reference, invoice, product, batch, person or phone"
                }
              >
                <Input value={filters.q} onChange={(e) => filter("q", e.target.value)} />
              </Field>
              <Field title="From">
                <Input
                  type="date"
                  value={filters.from}
                  onChange={(e) => filter("from", e.target.value)}
                />
              </Field>
              <Field title="Through">
                <Input
                  type="date"
                  value={filters.to}
                  onChange={(e) => filter("to", e.target.value)}
                />
              </Field>
            </div>
            <div className="grid gap-3 sm:grid-cols-4">
              {" "}
              {(["product", "manufacturer", "minimum_price", "maximum_price"] as const).map(
                (key) => (
                  <Field key={key} title={label(key)}>
                    <Input
                      type={key.includes("price") ? "number" : "text"}
                      min="0"
                      step="0.01"
                      value={filters[key]}
                      onChange={(e) => filter(key, e.target.value)}
                    />
                  </Field>
                ),
              )}
            </div>
            {tab === "purchases" && (
              <div className="grid gap-3 sm:grid-cols-3">
                <Choice
                  title="Channel"
                  value={filters.channel}
                  onChange={(v) => filter("channel", v)}
                  options={CHANNELS}
                  empty="All channels"
                />
                <Choice
                  title="Verification"
                  value={filters.verification}
                  onChange={(v) => filter("verification", v)}
                  options={Object.fromEntries(
                    ["verified", "partially_verified", "unverified", "quarantined", "rejected"].map(
                      (x) => [x, label(x)],
                    ),
                  )}
                  empty="All statuses"
                />
                <Choice
                  title="Review"
                  value={filters.review}
                  onChange={(v) => filter("review", v)}
                  options={Object.fromEntries(
                    [
                      "draft",
                      "awaiting_review",
                      "needs_information",
                      "approved",
                      "quarantined",
                      "rejected",
                    ].map((x) => [x, label(x)]),
                  )}
                  empty="All reviews"
                />
                <Choice
                  title="Payment"
                  value={filters.payment}
                  onChange={(v) => filter("payment", v)}
                  options={{
                    outstanding: "All outstanding",
                    paid: "Paid",
                    part_paid: "Part payment",
                    credit: "Credit",
                  }}
                  empty="All payments"
                />
                <Choice
                  title="Supplier / intermediary"
                  value={filters.supplier}
                  onChange={(v) => filter("supplier", v)}
                  options={contactOptions([
                    ...(context?.people ?? []),
                    ...(context?.companies ?? []),
                  ])}
                  empty="All contacts"
                />
                <Field title="Original source">
                  <Input
                    value={filters.source}
                    onChange={(e) => filter("source", e.target.value)}
                  />
                </Field>
              </div>
            )}
            <Button
              variant="ghost"
              onClick={() => {
                setFilters({ ...emptyFilters });
                setOffset(0);
              }}
            >
              Clear filters
            </Button>
          </section>
        )}
        {tab === "purchases" && (
          <>
            {filters.supplier &&
              context &&
              [...context.people, ...context.companies]
                .filter((c) => c.id === filters.supplier)
                .map((c) => (
                  <SupplierProfile
                    key={c.id}
                    pharmacy={business!.id}
                    contact={c}
                    open={(id) => void run(() => open(id))}
                  />
                ))}
            {list && (
              <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
                {[
                  ["Purchases", list.summary.count, ""],
                  ["External spend", formatGHSCell(list.summary.spend), ""],
                  ["Awaiting review", list.summary.awaiting_review, "awaiting_review"],
                  ["Quarantined batches", list.summary.quarantined, "quarantined"],
                  ["Verified", list.summary.verified, "verified"],
                  ["Partially verified", list.summary.partially_verified, "partially_verified"],
                  ["Unverified", list.summary.unverified, "unverified"],
                  ["Outstanding credit", formatGHSCell(list.summary.outstanding), "credit"],
                ].map(([title, value, target]) => (
                  <button
                    key={title}
                    className="rounded-xl border bg-card p-4 text-left"
                    onClick={() => {
                      if (target)
                        filter(
                          target === "credit"
                            ? "payment"
                            : ["awaiting_review", "quarantined"].includes(String(target))
                              ? "review"
                              : "verification",
                          String(target),
                        );
                    }}
                  >
                    <span className="text-sm text-muted-foreground">{title}</span>
                    <strong className="mt-1 block text-xl">{value}</strong>
                  </button>
                ))}
              </div>
            )}
            <div className="flex gap-2">
              <Button
                variant="outline"
                disabled={busy || !list}
                onClick={() => void run(() => exportPurchases("csv"))}
              >
                Export CSV
              </Button>
              <Button
                variant="outline"
                disabled={busy || !list}
                onClick={() => void run(() => exportPurchases("xlsx"))}
              >
                Export Excel
              </Button>
            </div>
            {!list && !error && <p role="status">Loading purchases…</p>}
            {list?.rows.length === 0 && (
              <div className={panel}>No external purchases match these filters.</div>
            )}
            <div className="grid gap-3 md:grid-cols-2">
              {list?.rows.map((p) => (
                <button
                  key={p.id}
                  className={`${panel} text-left hover:border-primary`}
                  disabled={busy}
                  onClick={() => void run(() => open(p.id))}
                >
                  <div className="flex flex-wrap justify-between gap-2">
                    <strong className="break-all">{p.reference}</strong>
                    <span>{p.purchase_date}</span>
                  </div>
                  <div>
                    <span className="text-xs uppercase text-muted-foreground">
                      Delivered / sold by
                    </span>
                    <p>{p.seller_snapshot.name ?? "Unknown"}</p>
                    <span className="text-xs uppercase text-muted-foreground">
                      Original pharmaceutical source
                    </span>
                    <p>{p.source_snapshot.name ?? "Unknown"}</p>
                  </div>
                  <div className="flex flex-wrap gap-2 text-sm">
                    <span>{CHANNELS[p.channel]}</span>
                    <span className="rounded bg-muted px-2">{label(p.review_status)}</span>
                    <span>{label(p.verification_status)}</span>
                  </div>
                  <p>
                    {formatGHSCell(p.total_ghs)} · {label(p.payment_status)} · {p.document_count}{" "}
                    documents
                  </p>
                </button>
              ))}
            </div>
            <Pager offset={offset} count={list?.summary.count ?? 0} change={setOffset} />
          </>
        )}
        {tab === "suppliers" && context && (
          <section className={panel}>
            <div className="flex flex-wrap gap-2">
              <h2 className="mr-auto text-lg font-semibold">External suppliers & intermediaries</h2>
              {context.can_record && (
                <>
                  <Button onClick={() => setContactKind("person")}>Add intermediary</Button>
                  <Button variant="outline" onClick={() => setContactKind("company")}>
                    Add company
                  </Button>
                </>
              )}
            </div>
            <p className="text-sm text-muted-foreground">
              Private contacts shared with your pharmacy CRM. A contact has no marketplace account
              or privileges. Select a contact to inspect purchases, spend, source history and
              evidence.
            </p>
            <Field title="Find name or phone">
              <Input value={filters.q} onChange={(e) => filter("q", e.target.value)} />
            </Field>
            <div className="grid gap-3 sm:grid-cols-2">
              {[
                ...context.people.map((p) => ({ ...p, kind: "Individual / intermediary" })),
                ...context.companies.map((p) => ({ ...p, kind: "External company" })),
              ]
                .filter((p) =>
                  `${p.name} ${p.phone}`.toLowerCase().includes(filters.q.toLowerCase()),
                )
                .map((p) => (
                  <button
                    key={p.id}
                    className="rounded-lg border p-4 text-left hover:border-primary"
                    onClick={() => {
                      setFilters({ ...emptyFilters, supplier: p.id });
                      setTab("purchases");
                      setOffset(0);
                    }}
                  >
                    <strong>{p.name}</strong>
                    <p>{p.kind}</p>
                    <p className="text-sm text-muted-foreground">
                      {p.phone ?? "No phone"} · {p.location ?? ""}
                    </p>
                    {context.supplier_stats?.[p.id] && (
                      <p className="mt-2 text-sm">
                        {context.supplier_stats[p.id].purchases} purchases ·{" "}
                        {formatGHSCell(context.supplier_stats[p.id].spend)}
                        <br />
                        Last purchase: {context.supplier_stats[p.id].last_purchase}
                        <br />
                        {context.supplier_stats[p.id].unknown_sources} receipts with unknown
                        original source
                      </p>
                    )}
                  </button>
                ))}
            </div>
          </section>
        )}
        {tab === "history" && (
          <section className={panel}>
            <h2 className="text-lg font-semibold">Purchasing across all channels</h2>
            <Button variant="outline" disabled={busy} onClick={() => void run(exportHistory)}>
              Export complete filtered history
            </Button>
            <p className="text-sm text-muted-foreground">
              Marketplace quantities reflect current committed supply. External receipts include
              pending/quarantined purchases, with returns shown separately; drafts and rejected
              purchases are excluded.
            </p>
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              {analytics?.channels.map((c) => (
                <div key={c.channel} className="rounded-lg bg-muted p-3">
                  <strong>{label(c.channel)}</strong>
                  <p>
                    {c.units} units · {c.returned} returned
                  </p>
                  <p>Gross {formatGHSCell(c.gross_cost)}</p>
                </div>
              ))}
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              {analytics?.rows.map((r, n) => (
                <article key={`${r.purchase_id}-${n}`} className="rounded-lg border p-4">
                  <strong>{r.product}</strong>
                  <p>
                    {r.date} · {label(r.channel)}
                  </p>
                  <p>
                    {r.quantity} × {formatGHSCell(r.unit_cost)} · {r.returned} returned
                  </p>
                  <p>Seller: {r.seller ?? "Unknown"}</p>
                  <p>Source: {r.source ?? "Unknown"}</p>
                  <p>Batch: {r.batches ?? "See marketplace order"}</p>
                  <p>
                    {label(r.verification)} · {label(r.review)}
                  </p>
                  {r.channel !== "marketplace" && (
                    <Button
                      variant="link"
                      disabled={busy}
                      onClick={() => void run(() => open(r.purchase_id))}
                    >
                      Trace purchase
                    </Button>
                  )}
                </article>
              ))}
            </div>
            <h3 className="font-semibold">Product prices by supplier</h3>
            <p className="text-sm text-muted-foreground">
              Prices are compared only within the same catalogue product or mapped inventory item.
              Unmapped local descriptions remain separate.
            </p>
            <div className="grid gap-3 sm:grid-cols-2">
              {analytics?.products?.map((r) => (
                <article
                  className="rounded-lg border p-4"
                  key={`${r.product_key}-${r.supplier_key}-${r.channel}`}
                >
                  <strong>{r.product}</strong>
                  <p>
                    {r.seller} | {label(r.channel)}
                  </p>
                  <p>Weighted unit cost {formatGHSCell(r.weighted_average)}</p>
                  <p>
                    Range {formatGHSCell(r.minimum_price)} - {formatGHSCell(r.maximum_price)}
                  </p>
                  <p>
                    Last price {formatGHSCell(r.last_price)} on {r.last_purchase}
                  </p>
                </article>
              ))}
            </div>
            {analytics?.rows.length === 0 && <p>No purchases found.</p>}
            <Pager offset={offset} count={analytics?.count ?? 0} change={setOffset} />
          </section>
        )}
        {tab === "workspaces" && <WorkspaceProcurementReport />}
        {tab === "settings" && context?.is_owner && (
          <section className={panel}>
            <a href="/settings" className="text-primary underline">Manage document branding in Business Settings</a>
            <div className="border-t pt-6">
            <h2 className="text-lg font-semibold">Review policy</h2>
            <p>
              Assign active pharmacy members who are authorized to perform pharmacist reviews.
              Assignment records authorization; it does not verify professional credentials. Unknown
              sources cannot be approved for saleable stock.
            </p>
            <label className="flex items-center gap-2">
              <input
                type="checkbox"
                checked={context.collect_identity}
                disabled={busy}
                onChange={(e) =>
                  void run(async () => {
                    await externalRpc("configure_external_procurement", {
                      p_pharmacy_id: business.id,
                      p_collect_identity: e.target.checked,
                    });
                    reload();
                  })
                }
              />
              Enable optional identity-reference collection
            </label>
            <p className="text-sm text-muted-foreground">
              Collect only a necessary reference, never identity document images. Disabling
              collection preserves previously recorded evidence.
            </p>
            {context.staff.map((s) => (
              <label key={s.id} className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={context.reviewers.includes(s.id)}
                  disabled={busy}
                  onChange={(e) =>
                    void run(async () => {
                      await externalRpc("configure_external_procurement", {
                        p_pharmacy_id: business.id,
                        p_collect_identity: context.collect_identity,
                        p_reviewer: s.id,
                        p_enabled: e.target.checked,
                      });
                      reload();
                    })
                  }
                />
                {s.name}
              </label>
            ))}
            </div>
          </section>
        )}
      </main>
      {draft && context && (
        <PurchaseForm
          draft={draft}
          setDraft={setDraft}
          context={context}
          pharmacy={business.id}
          busy={busy}
          close={() => setDraft(null)}
          contact={setContactKind}
          save={() =>
            void run(async () => {
              const error = validateDraft(draft);
              if (error) throw new Error(error);
              const id = await externalRpc<string>("save_external_purchase", {
                p_pharmacy_id: business.id,
                p_data: draft,
                p_request_id: request,
                p_id: editing?.id ?? null,
                p_version: editing?.version ?? null,
              });
              setDraft(null);
              await open(id);
              reload();
              toast.success("Receipt saved. Add evidence and submit for review.");
            })
          }
        />
      )}
      {contactKind && context && (
        <ContactForm
          kind={contactKind}
          identity={context.collect_identity}
          busy={busy}
          close={() => setContactKind(null)}
          save={(data) =>
            void run(async () => {
              await externalRpc("save_external_contact", {
                p_pharmacy_id: business.id,
                p_kind: contactKind,
                p_data: data,
              });
              setContactKind(null);
              reload();
              toast.success("Contact saved in your pharmacy directory.");
            })
          }
        />
      )}
      {detail && context && (
        <PurchaseDetail
          purchase={detail}
          context={context}
          pharmacyName={business.name}
          pharmacyId={business.id}
          busy={busy}
          close={() => setDetail(null)}
          act={(action) =>
            void run(async () => {
              await action();
              await open(detail.id);
              reload();
            })
          }
          edit={() => {
            setEditing(detail);
            setDraft(draftFromPurchase(detail));
            setDetail(null);
            setRequest(crypto.randomUUID());
          }}
        />
      )}
    </>
  );
}

function Pager({
  offset,
  count,
  change,
}: {
  offset: number;
  count: number;
  change: (n: number) => void;
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <Button
        variant="outline"
        disabled={offset === 0}
        onClick={() => change(Math.max(0, offset - 30))}
      >
        Previous
      </Button>
      <span className="text-sm">
        {count ? `${offset + 1}–${Math.min(offset + 30, count)} of ${count}` : "0 records"}
      </span>
      <Button variant="outline" disabled={offset + 30 >= count} onClick={() => change(offset + 30)}>
        Next
      </Button>
    </div>
  );
}

function ContactForm({
  kind,
  identity,
  busy,
  close,
  save,
}: {
  kind: "person" | "company";
  identity: boolean;
  busy: boolean;
  close: () => void;
  save: (d: Record<string, string>) => void;
}) {
  const [data, setData] = useState<Record<string, string>>({});
  return (
    <Dialog
      open
      onOpenChange={(v) => {
        if (!v && !busy) close();
      }}
    >
      <DialogContent className="max-h-[90dvh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {kind === "person" ? "Record intermediary" : "Record external company"}
          </DialogTitle>
        </DialogHeader>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            save(data);
          }}
          className="space-y-3"
        >
          {[
            "name",
            "phone",
            ...(kind === "person" ? ["alternate_phone", "email"] : ["license_reference"]),
            "location",
            "notes",
            ...(kind === "person" && identity ? ["identity_type", "identity_reference"] : []),
          ].map((k) => (
            <Field key={k} title={label(k)}>
              <Input
                required={k === "name" || (kind === "person" && k === "phone")}
                type={k === "email" ? "email" : "text"}
                maxLength={k === "notes" ? 1000 : 200}
                value={data[k] ?? ""}
                onChange={(e) => setData({ ...data, [k]: e.target.value })}
              />
            </Field>
          ))}
          <p className="text-xs text-muted-foreground">
            This creates a private contact only. It does not register or verify a wholesaler.
          </p>
          <Button disabled={busy} type="submit">
            Save contact
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function PurchaseForm({
  draft: d,
  setDraft,
  context,
  pharmacy,
  busy,
  close,
  contact,
  save,
}: {
  draft: Draft;
  setDraft: (d: Draft) => void;
  context: Context;
  pharmacy: string;
  busy: boolean;
  close: () => void;
  contact: (k: "person" | "company") => void;
  save: () => void;
}) {
  const [wholesalers, setWholesalers] = useState<Contact[]>([]),
    [step, setStep] = useState(0);
  useEffect(() => {
    db.from("businesses")
      .select("id,name")
      .eq("type", "wholesaler")
      .eq("verification_status", "approved")
      .then(({ data, error }) => {
        if (error) toast.error(error.message);
        else setWholesalers(data ?? []);
      });
  }, []);
  const patch = (p: Partial<Draft>) => setDraft({ ...d, ...p });
  return (
    <Dialog
      open
      onOpenChange={(v) => {
        if (!v && !busy) close();
      }}
    >
      <DialogContent className="max-h-[94dvh] max-w-4xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Record external purchase</DialogTitle>
        </DialogHeader>
        <nav className="flex flex-wrap gap-2">
          {["Purchase & seller", "Original source", "Products & batches", "Review receipt"].map(
            (s, i) => (
              <Button
                key={s}
                size="sm"
                variant={step === i ? "default" : "outline"}
                onClick={() => setStep(i)}
              >
                {i + 1}. {s}
              </Button>
            ),
          )}
        </nav>
        {step === 0 && (
          <div className="space-y-4">
            <div className="grid gap-3 sm:grid-cols-2">
              <Choice
                title="Purchase channel"
                value={d.channel}
                onChange={(v) =>
                  patch({
                    channel: v as Draft["channel"],
                    seller_contact_id: "",
                    seller_company_id: "",
                  })
                }
                options={CHANNELS}
              />
              <Field title="Purchase date">
                <Input
                  type="date"
                  max={today()}
                  value={d.purchase_date}
                  onChange={(e) => patch({ purchase_date: e.target.value })}
                />
              </Field>
              <Field title="Invoice number">
                <Input
                  value={d.invoice_number}
                  onChange={(e) => patch({ invoice_number: e.target.value })}
                />
              </Field>
              <Field title="Receipt number">
                <Input
                  value={d.receipt_number}
                  onChange={(e) => patch({ receipt_number: e.target.value })}
                />
              </Field>
            </div>
            <Choice
              title="Delivered / sold by"
              value={d.channel === "external_licensed" ? d.seller_company_id : d.seller_contact_id}
              onChange={(v) =>
                patch(
                  d.channel === "external_licensed"
                    ? { seller_company_id: v }
                    : { seller_contact_id: v },
                )
              }
              options={contactOptions(
                d.channel === "external_licensed" ? context.companies : context.people,
              )}
              empty={
                d.channel === "unknown"
                  ? "Unknown / choose existing contact"
                  : "Choose existing contact (name / phone)"
              }
            />
            <Button
              variant="outline"
              onClick={() => contact(d.channel === "external_licensed" ? "company" : "person")}
            >
              Add new contact
            </Button>
            <p className="text-sm text-muted-foreground">
              Existing contacts can be reused. Every purchase receives a separate source review.
            </p>
            <div className="grid gap-3 sm:grid-cols-2">
              <Choice
                title="Payment method"
                value={d.payment_method}
                onChange={(v) => patch({ payment_method: v })}
                options={{
                  cash: "Cash",
                  bank_transfer: "Bank transfer",
                  mobile_money: "Mobile money",
                  cheque: "Cheque",
                  other: "Other",
                }}
              />
              <Field title="Credit due date (optional)">
                <Input
                  type="date"
                  value={d.due_date}
                  onChange={(e) => patch({ due_date: e.target.value })}
                />
              </Field>
            </div>
            <p className="text-sm text-muted-foreground">
              Record paid or part-paid amounts on the saved receipt. Outstanding credit is
              calculated from payments and returns.
            </p>
            <Field title="Purchase notes">
              <textarea
                className={selectClass}
                value={d.notes}
                onChange={(e) => patch({ notes: e.target.value })}
              />
            </Field>
          </div>
        )}
        {step === 1 && (
          <div className="space-y-4">
            <h3 className="font-semibold">Where did these medicines originally come from?</h3>
            <Choice
              title="Original pharmaceutical source type"
              value={d.source_type}
              onChange={(v) =>
                patch({
                  source_type: v as Draft["source_type"],
                  source_company_id: "",
                  source_wholesaler_id: "",
                  source: {},
                })
              }
              options={SOURCES}
            />
            {d.source_type === "platform_wholesaler" ? (
              <Choice
                title="Approved DrugXOne wholesaler"
                value={d.source_wholesaler_id}
                onChange={(v) => patch({ source_wholesaler_id: v })}
                options={contactOptions(wholesalers)}
                empty="Choose wholesaler"
              />
            ) : d.source_type !== "unknown" ? (
              <>
                <Choice
                  title="Existing external company (optional)"
                  value={d.source_company_id}
                  onChange={(v) => patch({ source_company_id: v })}
                  options={contactOptions(context.companies)}
                  empty="Enter source details below"
                />
                <div className="grid gap-3 sm:grid-cols-2">
                  {["name", "license_reference", "phone", "location"].map((k) => (
                    <Field key={k} title={`Source ${label(k)}`}>
                      <Input
                        disabled={!!d.source_company_id}
                        value={d.source[k] ?? ""}
                        onChange={(e) => patch({ source: { ...d.source, [k]: e.target.value } })}
                      />
                    </Field>
                  ))}
                </div>
              </>
            ) : (
              <p className="rounded-lg bg-amber-50 p-3 text-amber-950">
                Original source unknown: this receipt will remain unverified and its stock
                quarantined.
              </p>
            )}
            {d.source_type !== "unknown" && (
              <div className="grid gap-3 sm:grid-cols-2">
                {["invoice_number", "invoice_date", "purchase_reference", "notes"].map((k) => (
                  <Field key={k} title={`Original source ${label(k)}`}>
                    <Input
                      type={k === "invoice_date" ? "date" : "text"}
                      value={d.source[k] ?? ""}
                      onChange={(e) => patch({ source: { ...d.source, [k]: e.target.value } })}
                    />
                  </Field>
                ))}
              </div>
            )}
          </div>
        )}
        {step === 2 && (
          <div className="space-y-4">
            {d.items.map((i, index) => (
              <ProductLine
                key={index}
                line={i}
                pharmacy={pharmacy}
                update={(v) => patch({ items: d.items.map((x, n) => (n === index ? v : x)) })}
                remove={() => patch({ items: d.items.filter((_, n) => n !== index) })}
              />
            ))}
            <Button variant="outline" onClick={() => patch({ items: [...d.items, newLine()] })}>
              Add medicine
            </Button>
          </div>
        )}
        {step === 3 && (
          <div className={panel}>
            <h3 className="font-semibold">Review the receipt</h3>
            <p>
              Delivered / sold by:{" "}
              {[...context.people, ...context.companies].find(
                (c) => c.id === (d.seller_contact_id || d.seller_company_id),
              )?.name ?? "Unknown"}
            </p>
            <p>Original source: {SOURCES[d.source_type]}</p>
            <p>
              {d.source_type === "unknown"
                ? "Unknown"
                : (context.companies.find((c) => c.id === d.source_company_id)?.name ??
                  wholesalers.find((c) => c.id === d.source_wholesaler_id)?.name ??
                  d.source.name)}
            </p>
            {d.items.map((i, n) => (
              <p key={n}>
                {i.product.name}: {i.quantity} packs across {i.batches.length} batch(es)
              </p>
            ))}
            <p className="font-semibold">Total {formatGHSCell(draftTotal(d))}</p>
            <p>
              Stock remains in quarantine until an assigned reviewer approves source, supporting
              invoice and complete batch details.
            </p>
            <p>After saving, attach documents, record payment and submit for review.</p>
            {validateDraft(d) && (
              <p role="alert" className="text-destructive">
                {validateDraft(d)}
              </p>
            )}
            <Button disabled={busy || !!validateDraft(d)} onClick={save}>
              Save receipt & continue to evidence
            </Button>
          </div>
        )}
        <div className="flex justify-between">
          <Button variant="outline" disabled={step === 0} onClick={() => setStep(step - 1)}>
            Back
          </Button>
          {step < 3 && <Button onClick={() => setStep(step + 1)}>Continue</Button>}
        </div>
      </DialogContent>
    </Dialog>
  );
}

function ProductLine({
  line: i,
  pharmacy,
  update,
  remove,
}: {
  line: Line;
  pharmacy: string;
  update: (i: Line) => void;
  remove: () => void;
}) {
  const [query, setQuery] = useState(""),
    [results, setResults] = useState<
      {
        id: string;
        name: string;
        brand_name: string;
        strength: string;
        dosage_form: string;
        pack_size: string;
        manufacturer: string;
        generic_name: string;
      }[]
    >([]),
    [inventory, setInventory] = useState<Contact[]>([]);
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => {
      if (query.length < 2) {
        setResults([]);
        return;
      }
      db.from("master_products")
        .select("id,name,brand_name,strength,dosage_form,pack_size,manufacturer,generic_name")
        .eq("active", true)
        .ilike("name", `%${query}%`)
        .limit(20)
        .then(({ data, error }) => {
          if (live) {
            if (error) toast.error(error.message);
            else setResults(data ?? []);
          }
        });
    }, 250);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [query]);
  const [inventoryQuery, setInventoryQuery] = useState("");
  const [inventoryPage, setInventoryPage] = useState(0);
  useEffect(() => {
    let live = true;
    db.from("pharmacy_inventory_items")
      .select("id,name,strength,pack_size")
      .eq("pharmacy_id", pharmacy)
      .eq("active", true)
      .eq("item_type", "medicine")
      .ilike("name", `%${inventoryQuery}%`)
      .order("name")
      .order("id")
      .range(inventoryPage * 50, inventoryPage * 50 + 49)
      .then(({ data, error }) => {
        if (live) {
          if (error) toast.error(error.message);
          else
            setInventory(
              (data ?? []).map((item) => ({
                id: item.id,
                name: [item.name, item.strength, item.pack_size].filter(Boolean).join(" | "),
              })),
            );
        }
      });
    return () => {
      live = false;
    };
  }, [pharmacy, inventoryQuery, inventoryPage]);
  return (
    <section className={panel}>
      <div className="flex justify-between">
        <h3 className="font-semibold">Medicine & receipt batches</h3>
        <Button variant="ghost" onClick={remove}>
          Remove line
        </Button>
      </div>
      <Field title="Search existing product catalogue">
        <Input
          placeholder="Type at least 2 characters"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </Field>
      {results.length > 0 && (
        <div className="max-h-44 overflow-y-auto rounded border">
          {results.map((p) => (
            <button
              key={p.id}
              className="block w-full border-b p-2 text-left text-sm hover:bg-muted"
              onClick={() => {
                update({
                  ...i,
                  master_product_id: p.id,
                  product: {
                    name: p.name,
                    brand: p.brand_name,
                    strength: p.strength,
                    form: p.dosage_form,
                    pack_size: p.pack_size,
                    manufacturer: p.manufacturer,
                    generic_name: p.generic_name,
                  },
                });
                setQuery("");
                setResults([]);
              }}
            >
              {p.name} · {p.strength} · {p.pack_size}
            </button>
          ))}
        </div>
      )}
      <p className="text-xs text-muted-foreground">
        A product not found can be recorded locally. This will not create a shared catalogue
        product.
      </p>
      {i.master_product_id && (
        <Button size="sm" variant="outline" onClick={() => update({ ...i, master_product_id: "" })}>
          Use local product description instead
        </Button>
      )}
      <Field title="Search inventory to map an existing item">
        <Input
          value={inventoryQuery}
          onChange={(e) => {
            setInventoryQuery(e.target.value);
            setInventoryPage(0);
          }}
          placeholder="Search all inventory by name"
        />
      </Field>
      <div className="grid gap-3 sm:grid-cols-3">
        {[
          "name",
          "brand",
          "generic_name",
          "strength",
          "form",
          "pack_size",
          "manufacturer",
          "registration",
          "barcode",
          "notes",
        ].map((k) => (
          <Field key={k} title={label(k)}>
            <Input
              disabled={!!i.master_product_id && !["registration", "barcode", "notes"].includes(k)}
              value={i.product[k as keyof typeof i.product] ?? ""}
              onChange={(e) => update({ ...i, product: { ...i.product, [k]: e.target.value } })}
            />
          </Field>
        ))}
        <Field title="Total quantity (packs)">
          <Input
            type="number"
            min="1"
            step="1"
            value={i.quantity}
            onChange={(e) => update({ ...i, quantity: Number(e.target.value) })}
          />
        </Field>
        <Field title="Unit cost (GHS)">
          <Input
            type="number"
            min="0"
            step="0.01"
            value={i.unit_cost_ghs}
            onChange={(e) => update({ ...i, unit_cost_ghs: Number(e.target.value) })}
          />
        </Field>
      </div>
      <Choice
        title="Post to this pharmacy inventory item (confirm the exact medicine / pack)"
        value={i.inventory_item_id}
        onChange={(v) => update({ ...i, inventory_item_id: v })}
        options={{
          ...(i.inventory_item_id
            ? { [i.inventory_item_id]: "Selected inventory item (search to change)" }
            : {}),
          ...contactOptions(inventory),
        }}
        empty="Create a local inventory item after approval"
      />
      <div className="flex flex-wrap items-center gap-3">
        <Button
          variant="outline"
          disabled={inventoryPage === 0}
          onClick={() => setInventoryPage((n) => n - 1)}
        >
          Previous inventory matches
        </Button>
        <span>Page {inventoryPage + 1}</span>
        <Button
          variant="outline"
          disabled={inventory.length < 50}
          onClick={() => setInventoryPage((n) => n + 1)}
        >
          More inventory matches
        </Button>
      </div>
      {i.batches.map((b, n) => (
        <div key={n} className="grid gap-2 rounded-lg bg-muted p-3 sm:grid-cols-4">
          <Field title="Batch number">
            <Input
              value={b.batch_number}
              onChange={(e) =>
                update({
                  ...i,
                  batches: i.batches.map((v, x) =>
                    x === n ? { ...v, batch_number: e.target.value } : v,
                  ),
                })
              }
            />
          </Field>
          <Field title="Expiry date">
            <Input
              type="date"
              value={b.expiry_date}
              onChange={(e) =>
                update({
                  ...i,
                  batches: i.batches.map((v, x) =>
                    x === n ? { ...v, expiry_date: e.target.value } : v,
                  ),
                })
              }
            />
          </Field>
          <Field title="Batch quantity">
            <Input
              type="number"
              min="1"
              value={b.quantity}
              onChange={(e) =>
                update({
                  ...i,
                  batches: i.batches.map((v, x) =>
                    x === n ? { ...v, quantity: Number(e.target.value) } : v,
                  ),
                })
              }
            />
          </Field>
          <Button
            variant="ghost"
            onClick={() => update({ ...i, batches: i.batches.filter((_, x) => x !== n) })}
          >
            Remove batch
          </Button>
        </div>
      ))}
      <Button
        variant="outline"
        onClick={() =>
          update({
            ...i,
            batches: [...i.batches, { batch_number: "", expiry_date: "", quantity: 1 }],
          })
        }
      >
        Add another batch
      </Button>
      <p className="text-sm">
        Line total {formatGHSCell(i.quantity * i.unit_cost_ghs)}. Missing batch/expiry details can
        be recorded, but block approval.
      </p>
    </section>
  );
}

function PurchaseDetail({
  purchase: p,
  context: c,
  pharmacyName,
  pharmacyId,
  busy,
  close,
  act,
  edit,
}: {
  purchase: Detail;
  context: Context;
  pharmacyName: string;
  pharmacyId: string;
  busy: boolean;
  close: () => void;
  act: (f: () => Promise<void>) => void;
  edit: () => void;
}) {
  const [notes, setNotes] = useState(""),
    [docType, setDocType] = useState("supplier_invoice"),
    [file, setFile] = useState<File | null>(null);
  const [amount, setAmount] = useState(""),
    [method, setMethod] = useState("cash"),
    [reference, setReference] = useState(""),
    [date, setDate] = useState(today());
  const [batch, setBatch] = useState(""),
    [qty, setQty] = useState("1"),
    [kind, setKind] = useState("return"),
    [reason, setReason] = useState(""),
    [returnedTo, setReturnedTo] = useState(""),
    [credit, setCredit] = useState("0");
  const [movementDate, setMovementDate] = useState(today());
  const [paymentRequest, setPaymentRequest] = useState(crypto.randomUUID());
  const [batchRequest, setBatchRequest] = useState(crypto.randomUUID());
  const [holdRequest, setHoldRequest] = useState(crypto.randomUUID());
  const editable = !p.posted_at && p.review_status !== "rejected";
  const review = (decision: string) =>
    act(async () => {
      await externalRpc("review_external_purchase", {
        p_purchase_id: p.id,
        p_decision: decision,
        p_version: p.version,
        p_notes: notes,
      });
      toast.success("Review saved.");
    });
  return (
    <Dialog
      open
      onOpenChange={(v) => {
        if (!v && !busy) close();
      }}
    >
      <DialogContent className="max-h-[94dvh] max-w-5xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="break-all">{p.reference}</DialogTitle>
        </DialogHeader>
        <div className="space-y-5">
          <div className="flex flex-wrap gap-2">
            <span className="rounded bg-muted px-3 py-1">{label(p.review_status)}</span>
            <span className="rounded bg-muted px-3 py-1">{label(p.verification_status)}</span>
            <Button
              variant="outline"
              disabled={busy}
              onClick={() =>
                act(async () => {
                  await downloadPdf(
                    `${p.reference}.pdf`,
                    `${pharmacyName} — GOODS RECEIVED NOTE`,
                    traceabilitySheets(p, pharmacyName),
                    pharmacyId,
                  );
                })
              }
            >
              Print / PDF goods received note
            </Button>
            <Button
              variant="outline"
              disabled={busy}
              onClick={() =>
                act(async () => {
                  await downloadXlsx(`${p.reference}.xlsx`, traceabilitySheets(p, pharmacyName));
                })
              }
            >
              Export traceability
            </Button>
            {c.can_record && editable && (
              <Button variant="outline" onClick={edit}>
                Edit receipt
              </Button>
            )}
          </div>
          <section className="grid gap-4 rounded-lg bg-muted p-4 sm:grid-cols-2">
            <div>
              <p className="text-xs uppercase">Delivered / sold by</p>
              <strong>{p.seller_snapshot.name ?? "Unknown"}</strong>
              <p>{p.seller_snapshot.phone}</p>
            </div>
            <div>
              <p className="text-xs uppercase">Original pharmaceutical source</p>
              <strong>{p.source_snapshot.name ?? "Unknown"}</strong>
              <p>{label(p.source_type)}</p>
              <p>{p.source_snapshot.license_reference}</p>
            </div>
            <p>
              {p.purchase_date} · {CHANNELS[p.channel]}
            </p>
            <p>Invoice {p.invoice_number ?? "not provided"}</p>
            <p>Received by {p.received_name ?? p.received_by}</p>
            <p>
              Reviewed by {p.reviewed_name ?? p.reviewed_by ?? "Pending"}{" "}
              {p.reviewed_at?.slice(0, 10)}
            </p>
          </section>
          {riskSignals(p).length > 0 && (
            <div
              role="status"
              className="rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950"
            >
              {riskSignals(p).map((s) => (
                <p key={s}>{s}</p>
              ))}
            </div>
          )}
          <section className={panel}>
            <h3 className="font-semibold">Products, batches & remaining stock</h3>
            {p.items.map((i) => (
              <div key={i.id} className="rounded-lg border p-3">
                <strong>{i.product_snapshot.name}</strong>
                <p>
                  {i.product_snapshot.brand} {i.product_snapshot.strength}{" "}
                  {i.product_snapshot.pack_size} · {i.product_snapshot.manufacturer}
                </p>
                <p>
                  {i.quantity} packs × {formatGHSCell(i.unit_cost_ghs)}
                </p>
                {i.batches.map((b) => (
                  <p key={b.id} className="mt-2 rounded bg-muted p-2 text-sm">
                    Batch {b.batch_number ?? "Unknown"} · Expiry {b.expiry_date ?? "Unknown"} ·
                    Consumed {b.consumed ?? 0} | Returned / corrected {b.returned ?? 0} | Received{" "}
                    {b.quantity} · Remaining {b.remaining} · {label(b.disposition ?? "quarantine")}
                  </p>
                ))}
              </div>
            ))}
          </section>
          <section className={panel}>
            <h3 className="font-semibold">Supporting documents</h3>
            {p.documents.map((d) => (
              <div key={d.id} className="flex flex-wrap items-center gap-2">
                <span className="min-w-0 flex-1 break-all">
                  {label(d.document_type)}: {d.filename}
                </span>
                <Button
                  variant="outline"
                  disabled={busy}
                  onClick={() =>
                    act(async () => {
                      const { data, error } = await db.storage
                        .from("external-procurement")
                        .createSignedUrl(d.storage_path, 60);
                      if (error) throw error;
                      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
                    })
                  }
                >
                  Open
                </Button>
                {c.can_record && editable && (
                  <Button
                    variant="ghost"
                    disabled={busy}
                    onClick={() =>
                      act(async () => {
                        await externalRpc("external_document_action", {
                          p_purchase_id: p.id,
                          p_type: d.document_type,
                          p_path: d.storage_path,
                          p_filename: d.filename,
                          p_remove_id: d.id,
                        });
                      })
                    }
                  >
                    Remove from evidence
                  </Button>
                )}
              </div>
            ))}
            {c.can_record && editable && (
              <div className="grid gap-3 sm:grid-cols-3">
                <Choice
                  title="Document type"
                  value={docType}
                  onChange={setDocType}
                  options={DOCUMENTS}
                />
                <Field title="PDF or image · max 10 MB">
                  <Input
                    type="file"
                    accept="application/pdf,image/jpeg,image/png,image/webp"
                    onChange={(e) => setFile(e.target.files?.[0] ?? null)}
                  />
                </Field>
                <Button
                  disabled={busy || !file}
                  onClick={() =>
                    act(async () => {
                      if (!file) return;
                      if (
                        file.size > 10485760 ||
                        !["application/pdf", "image/jpeg", "image/png", "image/webp"].includes(
                          file.type,
                        )
                      )
                        throw new Error("Choose a PDF, JPG, PNG or WebP up to 10 MB.");
                      const { data: purchase, error: readError } = await db
                        .from("external_purchases")
                        .select("pharmacy_id")
                        .eq("id", p.id)
                        .single();
                      if (readError) throw readError;
                      const storagePath = `${purchase.pharmacy_id}/${p.id}/${crypto.randomUUID()}.${file.name.split(".").pop()}`;
                      const { error } = await db.storage
                        .from("external-procurement")
                        .upload(storagePath, file, { upsert: false });
                      if (error) throw error;
                      await externalRpc("external_document_action", {
                        p_purchase_id: p.id,
                        p_type: docType,
                        p_path: storagePath,
                        p_filename: file.name,
                      });
                      setFile(null);
                    })
                  }
                >
                  Upload evidence
                </Button>
              </div>
            )}
          </section>
          <section className={panel}>
            <h3 className="font-semibold">Review & release</h3>
            <p>{p.review_notes ?? "No review recorded."}</p>
            <p className="text-sm text-muted-foreground">
              Only assigned active reviewers may release stock. Source, invoice evidence and
              complete unexpired batches are required.
            </p>
            {c.can_record && editable && (
              <Button disabled={busy} onClick={() => review("submit")}>
                Submit for review
              </Button>
            )}
            {c.can_review && editable && p.review_status !== "draft" && (
              <>
                <Field title="Review notes (required)">
                  <textarea
                    className={selectClass}
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                  />
                </Field>
                <div className="flex flex-wrap gap-2">
                  {["approved", "quarantined", "needs_information", "rejected"].map((s) => (
                    <Button
                      key={s}
                      variant={s === "approved" ? "default" : "outline"}
                      disabled={busy || !notes.trim()}
                      onClick={() => review(s)}
                    >
                      {s === "approved" ? "Approve & post saleable stock" : label(s)}
                    </Button>
                  ))}
                </div>
              </>
            )}
          </section>
          <section className={panel}>
            <h3 className="font-semibold">Payment / credit</h3>
            <div className="grid gap-2 sm:grid-cols-4">
              <p>Total {formatGHSCell(p.total_ghs)}</p>
              <p>Paid {formatGHSCell(p.paid_ghs)}</p>
              <p>Return credit {formatGHSCell(p.credit_ghs)}</p>
              <p>Balance {formatGHSCell(p.outstanding_ghs)}</p>
            </div>
            <p>
              {label(p.payment_status)} · Due {p.due_date ?? "not specified"}
            </p>
            {p.outstanding_ghs < 0 && (
              <p>Supplier refund / credit owed: {formatGHSCell(-p.outstanding_ghs)}</p>
            )}
            {c.can_pay && (
              <>
                <div className="grid gap-3 sm:grid-cols-4">
                  <Field title="Amount paid (GHS)">
                    <Input
                      type="number"
                      min="0.01"
                      step="0.01"
                      value={amount}
                      onChange={(e) => setAmount(e.target.value)}
                    />
                  </Field>
                  <Choice
                    title="Method"
                    value={method}
                    onChange={setMethod}
                    options={{
                      cash: "Cash",
                      bank_transfer: "Bank transfer",
                      mobile_money: "Mobile money",
                      cheque: "Cheque",
                      other: "Other",
                    }}
                  />
                  <Field title="Payment reference">
                    <Input value={reference} onChange={(e) => setReference(e.target.value)} />
                  </Field>
                  <Field title="Payment date">
                    <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
                  </Field>
                </div>
                <Button
                  disabled={busy || !amount}
                  onClick={() =>
                    act(async () => {
                      await externalRpc("record_external_payment", {
                        p_purchase_id: p.id,
                        p_amount: Number(amount),
                        p_method: method,
                        p_reference: reference,
                        p_paid_at: date,
                        p_request_id: paymentRequest,
                      });
                      setAmount("");
                      setPaymentRequest(crypto.randomUUID());
                    })
                  }
                >
                  Record payment
                </Button>
                {p.payments.map((x) => (
                  <div key={x.id} className="flex flex-wrap items-center gap-2">
                    <span>
                      {x.paid_at} · {formatGHSCell(x.amount_ghs)} · {x.reference}
                    </span>
                    {x.amount_ghs > 0 && !p.payments.some((r) => r.reverses_id === x.id) && (
                      <Button
                        variant="ghost"
                        disabled={busy}
                        onClick={() =>
                          act(async () => {
                            await externalRpc("record_external_payment", {
                              p_purchase_id: p.id,
                              p_amount: -x.amount_ghs,
                              p_method: x.method,
                              p_reference: `Reversal: ${x.reference ?? ""}`,
                              p_paid_at: today(),
                              p_request_id: crypto.randomUUID(),
                              p_reverses_id: x.id,
                            });
                          })
                        }
                      >
                        Reverse payment
                      </Button>
                    )}
                  </div>
                ))}
              </>
            )}
          </section>
          {c.can_record && p.posted_at && (
            <section className={panel}>
              <h3 className="font-semibold">Record stock consumption</h3>
              <p className="text-sm text-muted-foreground">
                Select the actual lot dispensed or used. Prefer the earliest expiry. Expired and
                quarantined lots cannot be consumed.
              </p>
              <Choice
                title="Consumption batch"
                value={batch}
                onChange={setBatch}
                empty="Choose batch"
                options={Object.fromEntries(
                  p.items.flatMap((i) =>
                    i.batches
                      .filter((b) => b.disposition === "saleable" && (b.remaining ?? 0) > 0)
                      .map((b) => [
                        b.id!,
                        `${i.product_snapshot.name} | ${b.batch_number} | expires ${b.expiry_date} | ${b.remaining} remaining`,
                      ]),
                  ),
                )}
              />
              <Field title="Units consumed">
                <Input type="number" min="1" value={qty} onChange={(e) => setQty(e.target.value)} />
              </Field>
              <Field title="Consumption reference / reason">
                <Input value={reason} onChange={(e) => setReason(e.target.value)} />
              </Field>
              <Button
                disabled={busy || !batch || !reason.trim()}
                onClick={() =>
                  act(async () => {
                    await externalRpc("consume_external_batch", {
                      p_batch_id: batch,
                      p_quantity: Number(qty),
                      p_reason: reason,
                      p_request_id: batchRequest,
                    });
                    setBatchRequest(crypto.randomUUID());
                    setReason("");
                  })
                }
              >
                Record consumption
              </Button>
            </section>
          )}
          {c.can_review && (
            <section className={panel}>
              <h3 className="font-semibold">Return / correction / expiry write-off</h3>
              <p className="text-sm text-muted-foreground">
                Reduce a specific lot with an audited movement. For additional received units,
                record a new receipt referencing this purchase. The original receipt is retained.
              </p>
              <div className="grid gap-3 sm:grid-cols-2">
                <Choice
                  title="Receipt batch"
                  value={batch}
                  onChange={setBatch}
                  options={Object.fromEntries(
                    p.items.flatMap((i) =>
                      i.batches.map((b) => [
                        b.id!,
                        `${i.product_snapshot.name} · ${b.batch_number ?? "Unknown"} · ${b.remaining} remaining`,
                      ]),
                    ),
                  )}
                  empty="Choose batch"
                />
                <Choice
                  title="Movement"
                  value={kind}
                  onChange={setKind}
                  options={{
                    return: "Return to supplier",
                    correction: "Quantity correction",
                    write_off: "Write-off (expiry / recall / damage)",
                  }}
                />
                <Field title="Quantity">
                  <Input
                    type="number"
                    min="1"
                    value={qty}
                    onChange={(e) => setQty(e.target.value)}
                  />
                </Field>
                <Field title="Agreed supplier credit (GHS)">
                  <Input
                    type="number"
                    min="0"
                    step="0.01"
                    value={credit}
                    onChange={(e) => setCredit(e.target.value)}
                  />
                </Field>
                <Field title="Reason / recall reference">
                  <Input value={reason} onChange={(e) => setReason(e.target.value)} />
                </Field>
                <Field title="Movement date">
                  <Input
                    type="date"
                    min={p.purchase_date}
                    max={today()}
                    value={movementDate}
                    onChange={(e) => setMovementDate(e.target.value)}
                  />
                </Field>
                <Field title="Returned to / disposition">
                  <Input value={returnedTo} onChange={(e) => setReturnedTo(e.target.value)} />
                </Field>
              </div>
              <Button
                disabled={busy || !batch || !reason.trim() || !returnedTo.trim()}
                variant="outline"
                onClick={() =>
                  act(async () => {
                    await externalRpc("adjust_external_batch", {
                      p_batch_id: batch,
                      p_quantity: Number(qty),
                      p_kind: kind,
                      p_reason: reason,
                      p_returned_to: returnedTo,
                      p_date: movementDate,
                      p_credit: Number(credit),
                      p_request_id: batchRequest,
                    });
                    setReason("");
                    setBatchRequest(crypto.randomUUID());
                  })
                }
              >
                Record batch movement
              </Button>
              {p.posted_at && (
                <div className="flex flex-wrap gap-2">
                  {[true, false].map((hold) => (
                    <Button
                      key={String(hold)}
                      disabled={busy || !batch || !reason.trim()}
                      variant="outline"
                      onClick={() =>
                        act(async () => {
                          await externalRpc("hold_external_batch", {
                            p_batch_id: batch,
                            p_hold: hold,
                            p_reason: reason,
                            p_request_id: holdRequest,
                          });
                          setHoldRequest(crypto.randomUUID());
                          setReason("");
                        })
                      }
                    >
                      {hold ? "Quarantine selected batch" : "Release selected batch"}
                    </Button>
                  ))}
                </div>
              )}
              {p.returns.map((r) => (
                <p key={r.id}>
                  {r.returned_at} · {label(r.kind)} · {r.quantity} · {r.reason} · {r.returned_to}
                </p>
              ))}
            </section>
          )}
          <section className={panel}>
            <h3 className="font-semibold">Activity history</h3>
            {p.events.map((e) => (
              <details key={e.id} className="border-b pb-2 text-sm">
                <summary>
                  {e.occurred_at.slice(0, 19).replace("T", " ")} · {label(e.action.toLowerCase())}
                </summary>
                <p>Actor: {e.actor_id}</p>
                <pre className="max-h-52 overflow-auto whitespace-pre-wrap break-all text-xs">
                  {JSON.stringify(e.details, null, 2)}
                </pre>
              </details>
            ))}
          </section>
        </div>
      </DialogContent>
    </Dialog>
  );
}
