import { useCallback, useEffect, useRef, useState } from "react";
import { DashboardHeader } from "@/components/DashboardShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { downloadPdf, downloadXlsx } from "@/lib/reports";
import {
  crmEntities,
  emptyCrm,
  lastVisit,
  nextFollowup,
  matchesRep,
  value,
  type CrmData,
  type CrmEntity,
  type CrmRow,
} from "@/lib/pharmacy-crm";
// New migration tables are accessed through the same client and enforced by RLS.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;
const date = (v: unknown) => (v ? new Date(String(v)).toLocaleString() : "Not recorded");
const label = (s: string) => s.replaceAll("_", " ").replace(/^./, (c) => c.toUpperCase());
const control = "w-full rounded-md border bg-background p-2 text-sm";
type Field = {
  key: string;
  title?: string;
  type?: string;
  required?: boolean;
  options?: string[];
  lookup?: string;
};
const fields: Partial<Record<CrmEntity, Field[]>> = {
  representatives: [
    { key: "name", required: true },
    { key: "rep_type", options: ["sales", "medical", "supplier", "other"] },
    { key: "job_title" },
    { key: "phone", type: "tel" },
    { key: "whatsapp", type: "tel" },
    { key: "email", type: "email" },
    { key: "territory" },
    { key: "preferred_contact", options: ["phone", "whatsapp", "email", "other"] },
    { key: "status", options: ["active", "inactive"] },
    { key: "notes", type: "textarea" },
  ],
  companies: [
    { key: "name", required: true },
    { key: "company_type", options: ["wholesaler", "manufacturer", "supplier", "other"] },
    { key: "wholesaler_id", title: "Registered wholesaler (optional)", lookup: "suppliers" },
    { key: "notes", type: "textarea" },
  ],
  rep_companies: [
    { key: "company_id", required: true, lookup: "companies" },
    { key: "designated", title: "Designated representative for this company", type: "checkbox" },
  ],
  rep_products: [
    { key: "label", title: "Product / brand name", required: true },
    { key: "brand" },
    { key: "master_product_id", title: "Catalogue product (optional)", lookup: "products" },
  ],
  interactions: [
    { key: "occurred_at", title: "Date and time", type: "datetime-local", required: true },
    { key: "staff_user_id", title: "Staff member", lookup: "staff", required: true },
    { key: "interaction_type", options: ["visit", "call", "email", "whatsapp", "other"] },
    { key: "purpose", required: true },
    { key: "products_discussed", type: "textarea" },
    {
      key: "samples_received",
      title: "Samples received (description and quantity; does not update inventory)",
      type: "textarea",
    },
    { key: "price_list_received", type: "checkbox" },
    { key: "quotation_discussed", type: "checkbox" },
    { key: "notes", type: "textarea" },
    { key: "followup_due_at", title: "Follow-up date (optional)", type: "datetime-local" },
    { key: "followup_task", title: "Follow-up task" },
  ],
  followups: [
    { key: "task", required: true },
    { key: "due_at", title: "Follow-up date", type: "datetime-local", required: true },
    { key: "assigned_to", lookup: "staff" },
    { key: "status", options: ["pending", "completed", "cancelled"] },
    { key: "notes", type: "textarea" },
  ],
  procurement_links: [
    {
      key: "order_id",
      title: "Order (choose exactly one order, RFQ or quotation)",
      lookup: "orders",
    },
    { key: "rfq_id", title: "RFQ", lookup: "rfqs" },
    { key: "quote_id", title: "Quotation", lookup: "quotes" },
    { key: "notes", type: "textarea" },
  ],
};
type Option = { id: string; name: string };
async function readAll(entity: CrmEntity, pharmacyId: string) {
  const rows: CrmRow[] = [];
  for (let from = 0; ; from += 500) {
    const { data, error } = await db
      .from(`pharmacy_crm_${entity}`)
      .select("*")
      .eq("pharmacy_id", pharmacyId)
      .order("id")
      .range(from, from + 499);
    if (error) throw error;
    rows.push(...data);
    if (data.length < 500) return rows;
  }
}
export function PharmacyCrm() {
  const { business, user } = useSession();
  const allowed =
    business?.type === "pharmacy" &&
    business.verification_status === "approved" &&
    ["owner", "manager"].includes(business.staff_role);
  const [data, setData] = useState<CrmData>(emptyCrm);
  const [loading, setLoading] = useState(true),
    [error, setError] = useState("");
  const [tab, setTab] = useState("representatives"),
    [repId, setRepId] = useState("");
  const [search, setSearch] = useState(""),
    [status, setStatus] = useState(""),
    [type, setType] = useState(""),
    [due, setDue] = useState(false),
    [since, setSince] = useState("");
  const [page, setPage] = useState(0),
    [archived, setArchived] = useState(false);
  const [editor, setEditor] = useState<{ entity: CrmEntity; row?: CrmRow } | null>(null);
  const [busy, setBusy] = useState(false);
  const generation = useRef(0);
  const [staffNames, setStaffNames] = useState<Record<string, string>>({});
  const actorName = (id: unknown) =>
    staffNames[String(id)] || (id === user?.id ? "Me" : "Former staff member");
  const load = useCallback(async () => {
    if (!allowed || !business) return;
    const gen = ++generation.current;
    setLoading(true);
    setError("");
    try {
      const entries = await Promise.all(
        crmEntities.map(async (e) => [e, await readAll(e, business.id)]),
      );
      const { data: staff } = await db.rpc("list_business_staff", { _business_id: business.id });
      if (gen === generation.current) {
        setData(Object.fromEntries(entries) as CrmData);
        setStaffNames(
          Object.fromEntries(
            (staff ?? []).map((r: { user_id: string; full_name: string; user_email: string }) => [
              r.user_id,
              r.full_name || r.user_email || "Staff member",
            ]),
          ),
        );
      }
    } catch (e) {
      if (gen === generation.current)
        setError(e instanceof Error ? e.message : String((e as { message?: string }).message ?? e));
    } finally {
      if (gen === generation.current) setLoading(false);
    }
  }, [allowed, business]);
  useEffect(() => {
    void load();
    return () => {
      // Invalidate pending reads when the workspace changes or the page unmounts.
      // eslint-disable-next-line react-hooks/exhaustive-deps
      generation.current++;
    };
  }, [load]);
  const rep = data.representatives.find((r) => r.id === repId);
  const repName = (id: unknown) =>
    value(data.representatives.find((r) => r.id === id) ?? { id: "" }, "name") ||
    "Archived representative";
  const save = async (entity: CrmEntity, payload: Record<string, unknown>, id?: string) => {
    if (!business || busy) return false;
    setBusy(true);
    setError("");
    try {
      const { error } = await db.rpc("save_pharmacy_crm", {
        p_pharmacy_id: business.id,
        p_entity: entity,
        p_data: payload,
        p_id: id ?? null,
      });
      if (error) throw error;
      await load();
      return true;
    } catch (e) {
      setError(String((e as { message?: string }).message ?? e));
      return false;
    } finally {
      setBusy(false);
    }
  };
  const visibleReps = data.representatives.filter(
    (r) =>
      Boolean(r.archived) === archived &&
      matchesRep(data, r, search) &&
      (!status || r.status === status) &&
      (!type || r.rep_type === type) &&
      (!since || lastVisit(data, r.id).slice(0, 10) >= since) &&
      (!due ||
        (nextFollowup(data, r.id) !== "" && new Date(nextFollowup(data, r.id)) <= new Date())),
  );
  const exportReps = async (pdf: boolean) => {
    setBusy(true);
    try {
      const headers = [
        "Name",
        "Type",
        "Job title",
        "Phone",
        "WhatsApp",
        "Email",
        "Territory",
        "Preferred contact",
        "Status",
        "Companies",
        "Products / brands",
        "Last visit",
        "Next follow-up",
        "Notes",
      ];
      const rows = visibleReps.map((r) => [
        ...[
          "name",
          "rep_type",
          "job_title",
          "phone",
          "whatsapp",
          "email",
          "territory",
          "preferred_contact",
          "status",
        ].map((k) => value(r, k)),
        data.rep_companies
          .filter((l) => l.rep_id === r.id && !l.archived)
          .map((l) =>
            value(data.companies.find((c) => c.id === l.company_id) ?? { id: "" }, "name"),
          )
          .join(", "),
        data.rep_products
          .filter((p) => p.rep_id === r.id && !p.archived)
          .map((p) => [p.label, p.brand].filter(Boolean).join(" / "))
          .join(", "),
        date(lastVisit(data, r.id)),
        date(nextFollowup(data, r.id)),
        value(r, "notes"),
      ]);
      const sheets = [{ name: "Representatives", headers, rows }];
      if (pdf)
        await downloadPdf("representatives.pdf", "Pharmacy representatives - private", [
          {
            name: "Contact details",
            headers: headers.slice(0, 9),
            rows: rows.map((r) => r.slice(0, 9)),
          },
          {
            name: "Relationships and follow-ups",
            headers: [headers[0], ...headers.slice(9)],
            rows: rows.map((r) => [r[0], ...r.slice(9)]),
          },
        ]);
      else await downloadXlsx("representatives.xlsx", sheets);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };
  const editButton = (entity: CrmEntity, row: CrmRow) => (
    <Button size="sm" variant="outline" disabled={busy} onClick={() => setEditor({ entity, row })}>
      Edit
    </Button>
  );
  const archiveButton = (entity: CrmEntity, row: CrmRow) => (
    <Button
      size="sm"
      variant="ghost"
      disabled={busy}
      onClick={() => {
        if (
          window.confirm(
            row.archived
              ? "Restore this record?"
              : "Archive this record? Its history will be retained.",
          )
        )
          void save(entity, { archived: !row.archived }, row.id);
      }}
    >
      {row.archived ? "Restore" : "Archive"}
    </Button>
  );
  const section = (entity: CrmEntity, title: string, render: (r: CrmRow) => React.ReactNode) => (
    <section className="rounded-xl border p-4 space-y-3">
      <div className="flex justify-between gap-2">
        <h2 className="font-semibold">{title}</h2>
        {!rep?.archived && (
          <Button size="sm" onClick={() => setEditor({ entity })}>
            Add
          </Button>
        )}
      </div>
      {data[entity]
        .filter((r) => r.rep_id === repId && !r.archived)
        .map((r) => (
          <div key={r.id} className="border-t pt-3 space-y-2">
            {render(r)}
            {!rep?.archived && (
              <div className="flex gap-2">
                {editButton(entity, r)}
                {archiveButton(entity, r)}
              </div>
            )}
          </div>
        ))}
      {!data[entity].some((r) => r.rep_id === repId && !r.archived) && (
        <p className="text-sm text-muted-foreground">No records yet.</p>
      )}
    </section>
  );
  if (!allowed)
    return (
      <>
        <DashboardHeader subtitle="Contacts / CRM" showNav />
        <p className="p-8">Contacts / CRM is available to verified pharmacy owners and managers.</p>
      </>
    );
  return (
    <>
      <DashboardHeader subtitle="Contacts / CRM" showNav />
      <main className="container mx-auto max-w-6xl p-4 md:p-6 space-y-5">
        <div>
          <h1 className="text-2xl font-bold">{rep ? value(rep, "name") : "Representatives"}</h1>
          <p className="text-sm text-muted-foreground">
            Private supplier relationships for {business?.name}. Only pharmacy owners and managers
            have access.
          </p>
        </div>
        {error && (
          <div role="alert" className="rounded border border-destructive p-3 text-destructive">
            {error}
            <Button variant="ghost" onClick={() => void load()}>
              Retry loading
            </Button>
          </div>
        )}
        {loading ? (
          <p role="status">Loading contacts...</p>
        ) : rep ? (
          <>
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" onClick={() => setRepId("")}>
                Back to representatives
              </Button>
              {editButton("representatives", rep)}
              {archiveButton("representatives", rep)}
            </div>
            <section className="rounded-xl border p-4 grid gap-3 sm:grid-cols-3">
              {[
                "rep_type",
                "job_title",
                "phone",
                "whatsapp",
                "email",
                "territory",
                "preferred_contact",
                "status",
                "notes",
              ].map((k) => (
                <div key={k}>
                  <p className="text-xs text-muted-foreground">{label(k)}</p>
                  <p className="whitespace-pre-wrap break-words">
                    {value(rep, k) || "Not recorded"}
                  </p>
                </div>
              ))}
              <p>Last visit: {date(lastVisit(data, rep.id))}</p>
              <p>Next follow-up: {date(nextFollowup(data, rep.id))}</p>
              <p className="text-xs">
                Created {date(rep.created_at)} by {actorName(rep.created_by)} | Updated{" "}
                {date(rep.updated_at)} by {actorName(rep.updated_by)}
              </p>
            </section>
            <div className="grid gap-4 lg:grid-cols-2">
              {section("rep_companies", "Companies", (r) => (
                <p>
                  {value(data.companies.find((c) => c.id === r.company_id) ?? { id: "" }, "name")}{" "}
                  {r.designated && <strong>Designated rep</strong>}
                </p>
              ))}
              {section("rep_products", "Products / brands", (r) => (
                <p>
                  {value(r, "label")} {value(r, "brand")}
                </p>
              ))}
              {section("interactions", "Visits / interactions", (r) => (
                <>
                  <p className="font-medium">
                    {date(r.occurred_at)} | {value(r, "interaction_type")} | {value(r, "purpose")}
                  </p>
                  {["products_discussed", "samples_received", "notes"].map(
                    (k) =>
                      value(r, k) && (
                        <p key={k} className="whitespace-pre-wrap">
                          {label(k)}: {value(r, k)}
                        </p>
                      ),
                  )}
                  <p className="text-sm">
                    Staff: {actorName(r.staff_user_id)} | Price list received:{" "}
                    {r.price_list_received ? "Yes" : "No"} | Quotation discussed:{" "}
                    {r.quotation_discussed ? "Yes" : "No"}
                  </p>
                </>
              ))}
              {section("followups", "Follow-ups", (r) => (
                <>
                  <p>
                    {value(r, "task")} | {date(r.due_at)} | {value(r, "status")}
                  </p>
                  <p>{value(r, "notes")}</p>
                  {r.status === "pending" && !rep.archived && (
                    <Button
                      size="sm"
                      disabled={busy}
                      onClick={() => void save("followups", { status: "completed" }, r.id)}
                    >
                      Mark completed
                    </Button>
                  )}
                  {r.assigned_to && <p>Assigned to {actorName(r.assigned_to)}</p>}
                  {r.completed_at && (
                    <p>
                      Completed {date(r.completed_at)} by {actorName(r.completed_by)}
                    </p>
                  )}
                </>
              ))}
              {section("procurement_links", "Related orders / RFQs / quotations", (r) => (
                <ProcurementReference row={r} />
              ))}
              <section className="rounded-xl border p-4 space-y-3">
                <h2 className="font-semibold">Activity history</h2>
                <div className="max-h-96 overflow-auto">
                  {data.activity
                    .filter((r) => r.rep_id === rep.id)
                    .sort((a, b) => value(b, "occurred_at").localeCompare(value(a, "occurred_at")))
                    .map((r) => (
                      <details key={r.id} className="border-t py-2">
                        <summary>
                          {date(r.occurred_at)} |{" "}
                          {label(value(r, "entity").replace("pharmacy_crm_", ""))} |{" "}
                          {value(r, "action")}
                        </summary>
                        <p className="text-xs">Actor: {actorName(r.actor_id)}</p>
                        <pre className="whitespace-pre-wrap break-all text-xs">
                          {JSON.stringify({ before: r.before_data, after: r.after_data }, null, 2)}
                        </pre>
                      </details>
                    ))}
                </div>
              </section>
            </div>
          </>
        ) : (
          <>
            <nav className="flex flex-wrap gap-2" aria-label="CRM sections">
              {[
                ["representatives", "All Representatives"],
                ["companies", "Companies"],
                ["interactions", "Visit History"],
                ["followups", "Follow-ups"],
              ].map(([key, title]) => (
                <Button
                  key={key}
                  variant={tab === key ? "default" : "outline"}
                  onClick={() => {
                    setTab(key);
                    setPage(0);
                    setSearch("");
                  }}
                >
                  {title}
                </Button>
              ))}
            </nav>
            <div className="flex flex-wrap gap-3">
              <Input
                className="max-w-sm"
                aria-label="Search CRM"
                placeholder="Search name, company, product or territory..."
                value={search}
                onChange={(e) => {
                  setSearch(e.target.value);
                  setPage(0);
                }}
              />
              {tab === "representatives" && (
                <>
                  <select
                    aria-label="Status"
                    className={control + " max-w-40"}
                    value={status}
                    onChange={(e) => {
                      setStatus(e.target.value);
                      setPage(0);
                    }}
                  >
                    <option value="">All statuses</option>
                    {["active", "inactive"].map((s) => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>
                  <select
                    aria-label="Rep type"
                    className={control + " max-w-40"}
                    value={type}
                    onChange={(e) => {
                      setType(e.target.value);
                      setPage(0);
                    }}
                  >
                    <option value="">All rep types</option>
                    {["sales", "medical", "supplier", "other"].map((s) => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>
                  <label className="text-sm">
                    Last visit on/after
                    <Input
                      type="date"
                      value={since}
                      onChange={(e) => {
                        setSince(e.target.value);
                        setPage(0);
                      }}
                    />
                  </label>
                </>
              )}
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={archived}
                  onChange={(e) => {
                    setArchived(e.target.checked);
                    setPage(0);
                  }}
                />
                Archived
              </label>
              {["representatives", "followups"].includes(tab) && (
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={due}
                    onChange={(e) => {
                      setDue(e.target.checked);
                      setPage(0);
                    }}
                  />
                  Follow-up due
                </label>
              )}
            </div>
            <div className="flex flex-wrap gap-2">
              {["representatives", "companies"].includes(tab) && (
                <Button onClick={() => setEditor({ entity: tab as CrmEntity })}>
                  Add {tab === "companies" ? "company" : "representative"}
                </Button>
              )}
              {tab === "representatives" && (
                <>
                  <Button
                    variant="outline"
                    disabled={busy || !visibleReps.length}
                    onClick={() => void exportReps(false)}
                  >
                    Export Excel
                  </Button>
                  <Button
                    variant="outline"
                    disabled={busy || !visibleReps.length}
                    onClick={() => void exportReps(true)}
                  >
                    Export PDF
                  </Button>
                </>
              )}
            </div>
            {tab === "representatives" ? (
              <>
                <div className="grid gap-3 md:grid-cols-2">
                  {visibleReps.slice(page * 25, page * 25 + 25).map((r) => (
                    <button
                      key={r.id}
                      onClick={() => setRepId(r.id)}
                      className="rounded-xl border p-4 text-left hover:bg-accent"
                    >
                      <strong>{value(r, "name")}</strong>
                      <p className="text-sm">
                        {value(r, "rep_type")} | {value(r, "territory")} | {value(r, "status")}
                      </p>
                      <p className="text-sm">{value(r, "phone") || value(r, "email")}</p>
                      <p className="text-xs text-muted-foreground">
                        Last visit {date(lastVisit(data, r.id))} | Follow-up{" "}
                        {date(nextFollowup(data, r.id))}
                      </p>
                    </button>
                  ))}
                </div>
                <Pager page={page} count={visibleReps.length} onChange={setPage} />
              </>
            ) : (
              <CrmList
                data={data}
                tab={tab as CrmEntity}
                search={search}
                archived={archived}
                due={due}
                page={page}
                setPage={setPage}
                repName={repName}
                openRep={setRepId}
                edit={editButton}
                archive={archiveButton}
              />
            )}
          </>
        )}
        {editor && business && (
          <CrmEditor
            key={`${editor.entity}-${editor.row?.id ?? "new"}`}
            entity={editor.entity}
            row={editor.row}
            repId={repId}
            pharmacyId={business.id}
            userId={user?.id ?? ""}
            companies={data.companies}
            busy={busy}
            onClose={() => setEditor(null)}
            onSave={async (payload) => {
              if (await save(editor.entity, payload, editor.row?.id)) setEditor(null);
              else
                throw new Error(
                  "Could not save. Check required fields, company designation conflicts, and procurement links, then retry.",
                );
            }}
          />
        )}
      </main>
    </>
  );
}
function Pager({
  page,
  count,
  onChange,
}: {
  page: number;
  count: number;
  onChange: (n: number) => void;
}) {
  return (
    <div className="flex items-center gap-3 py-3 text-sm">
      <Button variant="outline" disabled={page === 0} onClick={() => onChange(page - 1)}>
        Previous
      </Button>
      <span>
        {count
          ? `${page * 25 + 1}-${Math.min(count, page * 25 + 25)} of ${count}`
          : "No matching records"}
      </span>
      <Button
        variant="outline"
        disabled={(page + 1) * 25 >= count}
        onClick={() => onChange(page + 1)}
      >
        Next
      </Button>
    </div>
  );
}
function CrmList({
  data,
  tab,
  search,
  archived,
  due,
  page,
  setPage,
  repName,
  openRep,
  edit,
  archive,
}: {
  data: CrmData;
  tab: CrmEntity;
  search: string;
  archived: boolean;
  due: boolean;
  page: number;
  setPage: (p: number) => void;
  repName: (id: unknown) => string;
  openRep: (id: string) => void;
  edit: (e: CrmEntity, r: CrmRow) => React.ReactNode;
  archive: (e: CrmEntity, r: CrmRow) => React.ReactNode;
}) {
  const rows = data[tab]
    .filter(
      (r) =>
        Boolean(r.archived) === archived &&
        [r.name, r.purpose, r.task, r.notes, repName(r.rep_id)]
          .join(" ")
          .toLowerCase()
          .includes(search.toLowerCase()) &&
        (!(tab === "followups" && due) ||
          (r.status === "pending" && new Date(value(r, "due_at")) <= new Date())),
    )
    .sort((a, b) => value(b, "occurred_at").localeCompare(value(a, "occurred_at")));
  return (
    <>
      <div className="space-y-3">
        {rows.slice(page * 25, page * 25 + 25).map((r) => (
          <div key={r.id} className="rounded-xl border p-4 space-y-2">
            <p className="font-medium">
              {value(r, "name") || value(r, "purpose") || value(r, "task")}
            </p>
            {r.rep_id && (
              <Button variant="link" onClick={() => openRep(value(r, "rep_id"))}>
                {repName(r.rep_id)}
              </Button>
            )}
            <p className="text-sm">
              {tab === "companies" ? value(r, "company_type") : date(r.occurred_at || r.due_at)}{" "}
              {value(r, "status")}
            </p>
            <p className="whitespace-pre-wrap text-sm">{value(r, "notes")}</p>
            {tab === "companies" && (
              <>
                <p className="text-sm">
                  Representatives:{" "}
                  {data.rep_companies
                    .filter((l) => l.company_id === r.id && !l.archived)
                    .map((l) => `${repName(l.rep_id)}${l.designated ? " (designated)" : ""}`)
                    .join(", ") || "None linked"}
                </p>
                {edit(tab, r)}
                {archive(tab, r)}
              </>
            )}
          </div>
        ))}
      </div>
      <Pager page={page} count={rows.length} onChange={setPage} />
    </>
  );
}
function ProcurementReference({ row }: { row: CrmRow }) {
  const [name, setName] = useState("Loading reference...");
  useEffect(() => {
    let live = true;
    void (async () => {
      const kind = row.order_id ? "orders" : row.rfq_id ? "rfqs" : "rfq_quotes";
      const { data, error } = await db
        .from(kind)
        .select(
          kind === "orders"
            ? "order_number"
            : kind === "rfqs"
              ? "reference, title"
              : "rfqs(reference, title), businesses(name)",
        )
        .eq("id", row.order_id || row.rfq_id || row.quote_id)
        .maybeSingle();
      if (live)
        setName(
          error || !data
            ? "Reference unavailable"
            : data.order_number ||
                data.reference ||
                `${data.rfqs?.reference ?? "Quotation"} | ${data.businesses?.name ?? "Supplier"}`,
        );
    })();
    return () => {
      live = false;
    };
  }, [row]);
  return (
    <>
      <p>{name}</p>
      <p>{value(row, "notes")}</p>
      <a
        className="text-sm underline"
        href={row.order_id ? "/pharmacy?tab=orders" : "/pharmacy/rfqs"}
      >
        Open {row.order_id ? "orders" : "RFQs"}
      </a>
    </>
  );
}
function CrmEditor({
  entity,
  row,
  repId,
  pharmacyId,
  userId,
  companies,
  busy,
  onClose,
  onSave,
}: {
  entity: CrmEntity;
  row?: CrmRow;
  repId: string;
  pharmacyId: string;
  userId: string;
  companies: CrmRow[];
  busy: boolean;
  onClose: () => void;
  onSave: (p: Record<string, unknown>) => Promise<void>;
}) {
  const [lookupError, setLookupError] = useState("");
  const [saveError, setSaveError] = useState("");
  const [payload, setPayload] = useState<Record<string, unknown>>(() => ({
    ...Object.fromEntries(
      (fields[entity] ?? []).filter((f) => f.options).map((f) => [f.key, f.options![0]]),
    ),
    ...row,
    rep_id: row?.rep_id ?? repId,
    staff_user_id: row?.staff_user_id ?? userId,
    occurred_at: row?.occurred_at ?? new Date().toISOString(),
  }));
  const update = (k: string, v: unknown) => setPayload((p) => ({ ...p, [k]: v }));
  const localTime = (v: unknown) => {
    if (!v) return "";
    const d = new Date(String(v));
    return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  };
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>
            {row ? "Edit" : "Add"}{" "}
            {
              {
                representatives: "representative",
                companies: "company",
                rep_companies: "company link",
                rep_products: "product / brand",
                interactions: "visit / interaction",
                followups: "follow-up",
                procurement_links: "procurement link",
                activity: "activity",
              }[entity]
            }
          </DialogTitle>
          <DialogDescription>
            Private to your pharmacy. Changes are recorded in activity history.
          </DialogDescription>
        </DialogHeader>
        <form
          className="grid gap-4 sm:grid-cols-2"
          onSubmit={(e) => {
            e.preventDefault();
            setSaveError("");
            void onSave(payload).catch((e) => setSaveError(String(e.message ?? e)));
          }}
        >
          {(fields[entity] ?? [])
            .filter((f) => !(row && f.key.startsWith("followup_")))
            .map((f) => (
              <label
                key={f.key}
                className={`space-y-1 text-sm ${f.type === "textarea" ? "sm:col-span-2" : ""}`}
              >
                <span>
                  {f.title ?? label(f.key)}
                  {f.required ? " *" : ""}
                </span>
                {f.lookup ? (
                  <Lookup
                    kind={f.lookup}
                    selected={String(payload[f.key] ?? "")}
                    onChange={(v) => update(f.key, v || null)}
                    pharmacyId={pharmacyId}
                    companies={companies}
                    userId={userId}
                    required={f.required}
                    onError={setLookupError}
                  />
                ) : f.options ? (
                  <select
                    className={control}
                    value={String(payload[f.key] ?? f.options[0])}
                    onChange={(e) => update(f.key, e.target.value)}
                  >
                    {f.options.map((o) => (
                      <option key={o} value={o}>
                        {label(o)}
                      </option>
                    ))}
                  </select>
                ) : f.type === "checkbox" ? (
                  <input
                    className="ml-2"
                    type="checkbox"
                    checked={Boolean(payload[f.key])}
                    onChange={(e) => update(f.key, e.target.checked)}
                  />
                ) : f.type === "textarea" ? (
                  <textarea
                    className={control}
                    rows={3}
                    maxLength={10000}
                    value={String(payload[f.key] ?? "")}
                    onChange={(e) => update(f.key, e.target.value)}
                  />
                ) : (
                  <Input
                    type={f.type ?? "text"}
                    required={f.required}
                    maxLength={f.key === "name" ? 200 : 500}
                    value={
                      f.type === "datetime-local"
                        ? localTime(payload[f.key])
                        : String(payload[f.key] ?? "")
                    }
                    onChange={(e) =>
                      update(
                        f.key,
                        f.type === "datetime-local"
                          ? e.target.value
                            ? new Date(e.target.value).toISOString()
                            : null
                          : e.target.value,
                      )
                    }
                  />
                )}
              </label>
            ))}
          {saveError && (
            <p role="alert" className="text-destructive sm:col-span-2">
              {saveError}
            </p>
          )}
          {lookupError && (
            <p role="alert" className="text-destructive sm:col-span-2">
              {lookupError}
            </p>
          )}
          <div className="flex gap-2 sm:col-span-2">
            <Button type="submit" disabled={busy}>
              {busy ? "Saving..." : "Save"}
            </Button>
            <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
              Cancel
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
function Lookup({
  kind,
  selected,
  onChange,
  pharmacyId,
  companies,
  userId,
  required,
  onError,
}: {
  kind: string;
  selected: string;
  onChange: (v: string) => void;
  pharmacyId: string;
  companies: CrmRow[];
  userId: string;
  required?: boolean;
  onError: (e: string) => void;
}) {
  const [search, setSearch] = useState(""),
    [options, setOptions] = useState<Option[]>([]);
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => {
      void (async () => {
        try {
          let rows: Option[] = [];
          if (kind === "companies")
            rows = companies
              .filter(
                (c) => !c.archived && value(c, "name").toLowerCase().includes(search.toLowerCase()),
              )
              .map((c) => ({ id: c.id, name: value(c, "name") }));
          else if (kind === "staff") {
            const { data, error } = await db.rpc("list_business_staff", {
              _business_id: pharmacyId,
            });
            if (error) throw error;
            rows = [
              { id: userId, name: "Me" },
              ...(data ?? [])
                .filter(
                  (r: { status: string; user_id: string }) =>
                    r.status === "active" && r.user_id !== userId,
                )
                .map((r: { user_id: string; full_name: string; user_email: string }) => ({
                  id: r.user_id,
                  name: r.full_name || r.user_email || "Staff member",
                })),
            ];
          } else {
            const table =
              kind === "suppliers"
                ? "businesses"
                : kind === "products"
                  ? "master_products"
                  : kind === "quotes"
                    ? "rfq_quotes"
                    : kind;
            const columns =
              kind === "orders"
                ? "id,order_number"
                : kind === "rfqs"
                  ? "id,reference,title"
                  : kind === "quotes"
                    ? "id,rfqs!inner(reference,title,pharmacy_id),businesses(name)"
                    : "id,name";
            let q = db.from(table).select(columns).order("id").limit(30);
            if (kind === "suppliers")
              q = q.eq("type", "wholesaler").eq("verification_status", "approved");
            if (kind === "orders" || kind === "rfqs") q = q.eq("pharmacy_id", pharmacyId);
            if (kind === "quotes") q = q.eq("rfqs.pharmacy_id", pharmacyId);
            if (search)
              q = q.ilike(
                kind === "orders"
                  ? "order_number"
                  : kind === "rfqs"
                    ? "title"
                    : kind === "quotes"
                      ? "rfqs.title"
                      : "name",
                `%${search.replaceAll("%", "").replaceAll("_", "")}%`,
              );
            const { data, error } = await q;
            if (error) throw error;
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            rows = (data ?? []).map((r: any) => ({
              id: r.id,
              name:
                r.name ||
                r.order_number ||
                (r.reference
                  ? `${r.reference} | ${r.title}`
                  : `${r.rfqs?.reference} | ${r.businesses?.name}`),
            }));
            if (selected && !rows.some((r) => r.id === selected)) {
              const { data: s } = await db
                .from(table)
                .select(columns)
                .eq("id", selected)
                .maybeSingle();
              if (s)
                rows.unshift({
                  id: s.id,
                  name:
                    s.name ||
                    s.order_number ||
                    s.reference ||
                    s.rfqs?.reference ||
                    "Selected quotation",
                });
            }
          }
          if (live) setOptions(rows);
        } catch (e) {
          if (live) onError(String((e as { message?: string }).message ?? e));
        }
      })();
    }, 250);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [kind, search, selected, pharmacyId, companies, userId, onError]);
  return (
    <div className="space-y-1">
      <Input
        aria-label={`Search ${kind}`}
        placeholder={`Search ${kind}...`}
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />
      <select
        className={control}
        aria-label={`Select ${kind}`}
        required={required}
        value={selected}
        onChange={(e) => onChange(e.target.value)}
      >
        <option value="">Choose {kind}</option>
        {options.map((o) => (
          <option key={o.id} value={o.id}>
            {o.name}
          </option>
        ))}
        {selected && !options.some((o) => o.id === selected) && (
          <option value={selected}>Current selection</option>
        )}
      </select>
      <p className="text-xs text-muted-foreground">
        Showing up to 30 matches. Search to narrow results.
      </p>
    </div>
  );
}
