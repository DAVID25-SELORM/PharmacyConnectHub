import { useEffect, useMemo, useState, type ReactNode } from "react";
import { AlertTriangle, CheckCircle2, Globe, Lock } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { rfqCall, rfqDb, type EnterpriseRfq, type Requirement } from "@/lib/enterprise-rfq";
import { rfqRowIssues } from "@/lib/rfq-bulk";
import {
  RFQ_MAX_LINES,
  RFQ_MAX_SUPPLIERS,
  appendLines,
  blankLine,
  summarize,
  toPayloadItems,
  type RfqLine,
} from "@/lib/rfq-lines";
import { RFQ_PAYMENT_OPTIONS, paymentLabel, rfqDateTime } from "@/lib/rfq-format";
import { RfqAddTools } from "./RfqAddTools";
import { RfqMedicineTable } from "./RfqMedicineTable";
import { RfqSupplierPicker } from "./RfqSupplierPicker";

const selectClass =
  "h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-50";

function Field({
  label,
  hint,
  children,
  className,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <label className={`block space-y-1.5 ${className ?? ""}`}>
      <span className="text-sm font-medium">{label}</span>
      {children}
      {hint && <span className="block text-xs text-muted-foreground">{hint}</span>}
    </label>
  );
}

export function EnterpriseRfqEditor({
  businessId,
  initial,
  repeat,
  onSaved,
  onCancel,
}: {
  businessId: string;
  initial?: EnterpriseRfq;
  repeat?: boolean;
  onSaved: (id: string) => void;
  onCancel: () => void;
}) {
  const [title, setTitle] = useState(
    repeat ? `${initial?.title ?? ""} (repeat)` : (initial?.title ?? ""),
  );
  const [notes, setNotes] = useState(initial?.notes ?? "");
  const [deadline, setDeadline] = useState(
    repeat ? "" : (initial?.response_deadline?.slice(0, 16) ?? ""),
  );
  const [delivery, setDelivery] = useState(repeat ? "" : (initial?.expected_delivery_date ?? ""));
  const [location, setLocation] = useState(initial?.delivery_location ?? "");
  const [instructions, setInstructions] = useState(initial?.delivery_instructions ?? "");
  const [payment, setPayment] = useState(initial?.payment_preference ?? "cod");
  const [visibility, setVisibility] = useState<"private" | "open">(
    repeat ? "private" : (initial?.visibility ?? "private"),
  );
  const [lines, setLines] = useState<RfqLine[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [review, setReview] = useState(false);

  const productIds = lines
    .map((l) => l.masterProductId)
    .filter(Boolean)
    .sort()
    .join(",");
  const issues = useMemo(() => rfqRowIssues(lines), [lines]);
  const stats = summarize(lines, issues);

  useEffect(() => {
    if (!initial) return;
    let active = true;
    void Promise.all([
      rfqDb.from("rfq_items").select("*").eq("rfq_id", initial.id),
      rfqDb.from("rfq_invitees").select("wholesaler_id").eq("rfq_id", initial.id),
    ]).then(([items, invites]) => {
      if (!active) return;
      if (items.error || invites.error) {
        setError((items.error ?? invites.error).message);
        return;
      }
      setLines(
        (items.data as Requirement[]).map((i) => ({
          ...blankLine(),
          productName: i.product_name,
          quantity: String(i.quantity),
          notes: i.notes ?? "",
          masterProductId: i.master_product_id,
          unit: i.unit,
          shelfLifeDays: i.minimum_shelf_life_days,
          alternativesAllowed: i.alternatives_allowed,
          partialAllowed: i.partial_allowed,
          coldChainRequired: i.cold_chain_required,
          specialHandling: i.special_handling ?? "",
        })),
      );
      setSelected(invites.data.map((i: { wholesaler_id: string }) => i.wholesaler_id));
    });
    return () => {
      active = false;
    };
  }, [initial]);

  const changeLines = (next: RfqLine[]) => {
    setLines(next);
    setReview(false);
  };
  const addLines = (incoming: RfqLine[]) => {
    const { lines: next, added, dropped } = appendLines(lines, incoming, RFQ_MAX_LINES);
    changeLines(next);
    if (added) toast.success(`Added ${added} medicine${added === 1 ? "" : "s"} to the list.`);
    if (dropped)
      toast.error(`${dropped} did not fit: an RFQ holds at most ${RFQ_MAX_LINES} medicines.`);
  };

  const problems = [
    !title.trim() && "Give the request a title.",
    lines.length === 0 && "Add at least one medicine.",
    issues.size > 0 &&
      `${issues.size} medicine line${issues.size === 1 ? " needs" : "s need"} attention.`,
    visibility === "private" &&
      selected.length === 0 &&
      "Invite at least one supplier, or open the request to approved wholesalers.",
  ].filter(Boolean) as string[];
  // A draft can be saved without suppliers; they are needed to publish. Everything else blocks saving.
  const blocking = problems.filter((p) => !p.startsWith("Invite at least"));

  const save = async () => {
    setError("");
    if (blocking.length) {
      setError(blocking.join(" "));
      setReview(false);
      return;
    }
    setBusy(true);
    try {
      const id = await rfqCall<string>("save_enterprise_rfq", {
        p_pharmacy_id: businessId,
        p_request_id: crypto.randomUUID(),
        p_rfq_id: repeat ? null : (initial?.id ?? null),
        p_revision: repeat ? null : (initial?.revision ?? null),
        p_payload: {
          title,
          notes,
          deadline: deadline ? new Date(deadline).toISOString() : null,
          expectedDelivery: delivery || null,
          deliveryLocation: location,
          deliveryInstructions: instructions,
          paymentPreference: payment,
          visibility,
          items: toPayloadItems(lines),
          suppliers: visibility === "private" ? selected : [],
        },
      });
      onSaved(id);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const locked = busy || review;
  return (
    <div className="mx-auto w-full max-w-6xl space-y-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-2xl font-semibold tracking-tight">
              {repeat ? "Repeat RFQ" : initial ? "Edit draft" : "Create RFQ"}
            </h2>
            <Badge variant="secondary">Draft</Badge>
          </div>
          <p className="mt-1 max-w-2xl text-sm text-muted-foreground">
            Save a private draft, review it, then publish invitations. Repeat requests use new
            deadlines and carry no quotes or awards.
          </p>
        </div>
      </header>

      <fieldset disabled={locked} className="min-w-0 space-y-6">
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">1. Request details</CardTitle>
            <CardDescription>
              What you are asking for, and when and where you need it.
            </CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-2">
            <Field label="Title" className="sm:col-span-2">
              <Input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="e.g. Monthly antibiotics restock"
              />
            </Field>
            <Field
              label="Description"
              className="sm:col-span-2"
              hint="Optional. Shown to the suppliers you invite."
            >
              <Textarea rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
            </Field>
            <Field label="Quotation deadline">
              <Input
                type="datetime-local"
                value={deadline}
                onChange={(e) => setDeadline(e.target.value)}
              />
            </Field>
            <Field label="Expected delivery">
              <Input type="date" value={delivery} onChange={(e) => setDelivery(e.target.value)} />
            </Field>
            <Field label="Delivery location within this pharmacy">
              <Input value={location} onChange={(e) => setLocation(e.target.value)} />
            </Field>
            <Field label="Payment preference">
              <select
                className={selectClass}
                value={payment}
                onChange={(e) => setPayment(e.target.value)}
              >
                {RFQ_PAYMENT_OPTIONS.map(([value, text]) => (
                  <option key={value} value={value}>
                    {text}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Delivery and special handling instructions" className="sm:col-span-2">
              <Textarea
                rows={2}
                value={instructions}
                onChange={(e) => setInstructions(e.target.value)}
              />
            </Field>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-lg">2. Medicines</CardTitle>
            <CardDescription>
              Add medicines one by one, or in bulk from a spreadsheet, your past purchases or the
              catalogue. An RFQ holds up to {RFQ_MAX_LINES}.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <RfqMedicineTable
              lines={lines}
              onChange={changeLines}
              issues={issues}
              disabled={locked}
              tools={
                <RfqAddTools
                  businessId={businessId}
                  onAdd={addLines}
                  onError={setError}
                  disabled={locked}
                />
              }
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-lg">3. Suppliers</CardTitle>
            <CardDescription>Choose who can see this request and send quotations.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div
              className="grid gap-3 sm:grid-cols-2"
              role="radiogroup"
              aria-label="Supplier access"
            >
              {(
                [
                  [
                    "private",
                    Lock,
                    "Private invitations",
                    "Recommended. Only the suppliers you invite can see and answer it.",
                  ],
                  [
                    "open",
                    Globe,
                    "Open to approved wholesalers",
                    "Any approved wholesaler can respond until the deadline.",
                  ],
                ] as const
              ).map(([value, Icon, heading, text]) => (
                <label
                  key={value}
                  className={`flex cursor-pointer gap-3 rounded-lg border p-4 transition-colors ${
                    visibility === value ? "border-primary bg-primary/5" : "hover:bg-muted/40"
                  }`}
                >
                  <input
                    type="radio"
                    name="rfq-visibility"
                    className="mt-1"
                    checked={visibility === value}
                    onChange={() => {
                      setVisibility(value);
                      setReview(false);
                    }}
                  />
                  <span className="space-y-0.5">
                    <span className="flex items-center gap-1.5 text-sm font-medium">
                      <Icon className="h-4 w-4" /> {heading}
                    </span>
                    <span className="block text-xs text-muted-foreground">{text}</span>
                  </span>
                </label>
              ))}
            </div>
            <p className="text-xs text-muted-foreground">
              Each supplier sees only its own response and quotations.
            </p>
            {visibility === "private" && (
              <RfqSupplierPicker
                businessId={businessId}
                productIds={productIds}
                selected={selected}
                onSelect={(ids) => {
                  setSelected(ids);
                  setReview(false);
                }}
                onError={setError}
                disabled={locked}
              />
            )}
          </CardContent>
        </Card>
      </fieldset>

      {review && (
        <Card className="border-primary/40">
          <CardHeader>
            <CardTitle className="text-lg">Review before saving</CardTitle>
            <CardDescription>This saves a draft. Publishing is a separate action.</CardDescription>
          </CardHeader>
          <CardContent>
            <dl className="grid gap-x-8 gap-y-3 text-sm sm:grid-cols-2">
              {(
                [
                  ["Title", title],
                  ["Quotation deadline", rfqDateTime(deadline)],
                  ["Expected delivery", delivery || "Not set"],
                  ["Payment preference", paymentLabel(payment)],
                  [
                    "Medicines",
                    `${stats.total}${stats.unmatched ? ` (${stats.unmatched} not in the catalogue)` : ""}`,
                  ],
                  [
                    "Suppliers",
                    visibility === "open"
                      ? "Open to approved wholesalers"
                      : selected.length
                        ? `${selected.length} invited`
                        : "None yet: add suppliers before publishing",
                  ],
                ] as const
              ).map(([label, value]) => (
                <div key={label}>
                  <dt className="text-xs uppercase tracking-wide text-muted-foreground">{label}</dt>
                  <dd className="font-medium">{value}</dd>
                </div>
              ))}
            </dl>
          </CardContent>
        </Card>
      )}

      <div className="sticky bottom-0 z-10 -mx-4 border-t bg-background/95 px-4 py-3 backdrop-blur sm:mx-0 sm:rounded-lg sm:border">
        {error && (
          <p
            role="alert"
            className="mb-3 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
          >
            {error}
          </p>
        )}
        <div className="flex flex-wrap items-center gap-3">
          <ul className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <li className="flex items-center gap-1 tabular-nums">
              {lines.length ? (
                <CheckCircle2 className="h-3.5 w-3.5 text-success" />
              ) : (
                <AlertTriangle className="h-3.5 w-3.5 text-warning" />
              )}
              {stats.total} / {RFQ_MAX_LINES} medicines
            </li>
            {issues.size > 0 && (
              <li className="flex items-center gap-1 text-destructive">
                <AlertTriangle className="h-3.5 w-3.5" /> {issues.size} need attention
              </li>
            )}
            <li className="tabular-nums">
              {visibility === "open"
                ? "Open to approved wholesalers"
                : `${selected.length} / ${RFQ_MAX_SUPPLIERS} suppliers`}
            </li>
          </ul>
          <div className="ml-auto flex flex-wrap gap-2">
            <Button type="button" variant="ghost" disabled={busy} onClick={onCancel}>
              Close
            </Button>
            {review && (
              <Button type="button" variant="outline" onClick={() => setReview(false)}>
                Back to edit
              </Button>
            )}
            <Button
              type="button"
              disabled={busy}
              onClick={() => {
                if (review) return void save();
                if (blocking.length) {
                  setError(blocking.join(" "));
                  return;
                }
                setError("");
                setReview(true);
                window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" });
              }}
            >
              {busy ? "Saving…" : review ? "Confirm and save draft" : "Review draft"}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
