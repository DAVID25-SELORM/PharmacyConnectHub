import { Link } from "@tanstack/react-router";
import { ArrowRight, CheckCircle2 } from "lucide-react";
import { useEffect, useState } from "react";
import {
  Bar,
  BarChart,
  Cell,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { supabase } from "@/integrations/supabase/client";
import { auditActivityLabel, type AuditLogRow } from "@/lib/audit-centre";
import {
  sortAttention,
  type AgingBucket,
  type AttentionItem,
  type AttentionTone,
} from "@/lib/dashboard";
import { formatGHS, timeAgo } from "@/lib/format";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

const TONE_BORDER: Record<AttentionTone, string> = {
  danger: "border-l-destructive",
  warning: "border-l-warning",
  info: "border-l-primary",
};
const TONE_TEXT: Record<AttentionTone, string> = {
  danger: "text-destructive",
  warning: "text-warning-foreground",
  info: "text-primary",
};

/** A summary figure that opens the page behind it. Colour only reflects status (`tone`), never
 * decoration: a card is red/amber only when the number needs action. */
export function MetricCard({
  label,
  value,
  helper,
  icon,
  tone,
  to,
  search,
}: {
  label: string;
  value: string;
  helper: string;
  icon: React.ReactNode;
  tone?: AttentionTone;
  to: string;
  search?: Record<string, string>;
}) {
  return (
    <Link
      to={to}
      search={search as never}
      className="group block rounded-xl focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring"
    >
      <Card
        className={`h-full border-l-4 p-4 transition-colors group-hover:border-primary/50 ${tone ? TONE_BORDER[tone] : "border-l-transparent"}`}
      >
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <div className="text-xs uppercase tracking-wider text-muted-foreground">{label}</div>
            <div
              className={`mt-1.5 font-display text-2xl font-bold ${tone ? TONE_TEXT[tone] : ""}`}
            >
              {value}
            </div>
          </div>
          <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-muted text-primary">
            {icon}
          </div>
        </div>
        <p className="mt-1.5 text-xs text-muted-foreground">{helper}</p>
      </Card>
    </Link>
  );
}

export function MetricGrid({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">{children}</div>;
}

export function NeedsAttentionCard({
  items,
  loading,
}: {
  items: AttentionItem[];
  loading: boolean;
}) {
  const visible = sortAttention(items);
  return (
    <Card className="p-5">
      <div className="font-semibold">Needs attention</div>
      <p className="mt-1 text-sm text-muted-foreground">
        Things waiting on you. Each one opens the relevant page.
      </p>
      {loading ? (
        <div className="mt-4 space-y-2" role="status" aria-label="Loading">
          <Skeleton className="h-12 w-full" />
          <Skeleton className="h-12 w-full" />
        </div>
      ) : visible.length === 0 ? (
        <div className="mt-4 flex items-center gap-2 rounded-lg border border-dashed border-border p-4 text-sm text-muted-foreground">
          <CheckCircle2 className="h-4 w-4 text-success" aria-hidden="true" />
          Nothing needs your attention right now.
        </div>
      ) : (
        <ul className="mt-4 space-y-2">
          {visible.map((item) => (
            <li key={item.key}>
              <Link
                to={item.to}
                search={item.search as never}
                className={`flex items-center justify-between gap-3 rounded-lg border border-border border-l-4 p-3 text-sm transition-colors hover:bg-muted/50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring ${TONE_BORDER[item.tone]}`}
              >
                <span className="min-w-0">
                  <span className="font-medium">{item.label}</span>
                  <span className="block text-xs text-muted-foreground">{item.detail}</span>
                </span>
                <span className="flex shrink-0 items-center gap-2">
                  <span className={`font-display text-lg font-bold ${TONE_TEXT[item.tone]}`}>
                    {item.count}
                  </span>
                  <ArrowRight className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

export type ActionItem = {
  title: string;
  description: string;
  to: string;
  search?: Record<string, string>;
};

export function ActionsCard({ items }: { items: ActionItem[] }) {
  if (items.length === 0) return null;
  return (
    <Card className="p-5">
      <div className="font-semibold">Quick actions</div>
      <div className="mt-3 grid gap-2">
        {items.map((item) => (
          <Link
            key={item.title}
            to={item.to}
            search={item.search as never}
            className="flex items-center justify-between gap-3 rounded-lg border border-border p-3 text-sm transition-colors hover:bg-muted/50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring"
          >
            <span>
              <span className="font-medium">{item.title}</span>
              <span className="block text-xs text-muted-foreground">{item.description}</span>
            </span>
            <ArrowRight className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden="true" />
          </Link>
        ))}
      </div>
    </Card>
  );
}

/** Credit balances grouped by how late they are. Colour reflects lateness (muted when not yet due,
 * increasingly red as it ages) -- the same status meaning used on the cards. */
export function AgingChart({
  title,
  buckets,
  loading,
}: {
  title: string;
  buckets: AgingBucket[];
  loading: boolean;
}) {
  const fills = [
    "var(--primary)",
    "var(--warning)",
    "color-mix(in oklab, var(--destructive) 55%, transparent)",
    "color-mix(in oklab, var(--destructive) 80%, transparent)",
    "var(--destructive)",
  ];
  const empty = buckets.every((b) => b.total === 0);
  return (
    <Card className="p-4">
      <div className="text-sm font-semibold">{title}</div>
      {loading ? (
        <div
          className="mt-4 h-56 animate-pulse rounded-lg bg-muted"
          role="status"
          aria-label="Loading chart"
        />
      ) : empty ? (
        <p className="mt-4 py-16 text-center text-sm text-muted-foreground">Nothing outstanding.</p>
      ) : (
        <div className="mt-2 h-56">
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={buckets} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" className="stroke-border" vertical={false} />
              <XAxis dataKey="label" fontSize={11} interval={0} tick={{ fontSize: 10 }} />
              <YAxis fontSize={11} width={48} />
              <Tooltip formatter={(value: number) => [formatGHS(value), "Outstanding"]} />
              <Bar dataKey="total" radius={[4, 4, 0, 0]}>
                {buckets.map((_, index) => (
                  <Cell key={index} fill={fills[index]} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}
    </Card>
  );
}

/** The newest few audit events for this business. Only rendered for roles list_audit_log allows. */
export function RecentActivityCard({
  businessId,
  auditPath,
}: {
  businessId: string;
  auditPath: "/pharmacy/audit" | "/wholesaler/audit";
}) {
  const [rows, setRows] = useState<AuditLogRow[] | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void db
      .rpc("list_audit_log", { p_business_id: businessId, p_limit: 8 })
      .then(({ data, error }: { data: AuditLogRow[] | null; error: unknown }) => {
        if (cancelled) return;
        if (error) setFailed(true);
        else setRows(data ?? []);
      });
    return () => {
      cancelled = true;
    };
  }, [businessId]);

  return (
    <Card className="p-5">
      <div className="flex items-center justify-between gap-3">
        <div className="font-semibold">Recent activity</div>
        <Link to={auditPath} className="text-xs font-medium text-primary hover:underline">
          View all
        </Link>
      </div>
      {failed ? (
        <p className="mt-4 text-sm text-muted-foreground">
          Activity isn&apos;t available right now.
        </p>
      ) : rows === null ? (
        <div className="mt-4 space-y-2" role="status" aria-label="Loading activity">
          <Skeleton className="h-9 w-full" />
          <Skeleton className="h-9 w-full" />
          <Skeleton className="h-9 w-full" />
        </div>
      ) : rows.length === 0 ? (
        <p className="mt-4 text-sm text-muted-foreground">No activity recorded yet.</p>
      ) : (
        <ul className="mt-3 divide-y divide-border text-sm">
          {rows.map((row) => (
            <li key={row.id} className="flex items-start justify-between gap-3 py-2">
              <span className="min-w-0">
                <span className="font-medium">{auditActivityLabel(row.activity)}</span>
                {row.record_label && (
                  <span className="block truncate text-xs text-muted-foreground">
                    {row.record_label}
                  </span>
                )}
              </span>
              <span className="shrink-0 text-xs text-muted-foreground">
                {timeAgo(row.created_at)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
