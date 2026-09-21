import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { supabase } from "@/integrations/supabase/client";
import {
  activityLabel,
  actorLabel,
  categoryLabel,
  detailRows,
  formatActivityTime,
  type ActivityDetail,
} from "@/lib/activity-log";

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-3 gap-2 border-b border-border py-2 text-sm last:border-0">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="col-span-2 break-words font-medium">{value || "—"}</dd>
    </div>
  );
}

/** Loads one full record only when opened; metadata is redacted by the database and again here. */
export function ActivityDetailSheet({
  activityId,
  onClose,
}: {
  activityId: string | null;
  onClose: () => void;
}) {
  const [detail, setDetail] = useState<ActivityDetail | null>(null);
  const [state, setState] = useState<"idle" | "loading" | "error">("idle");

  const load = async (id: string) => {
    setState("loading");
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data, error } = await (supabase as any).rpc("admin_get_activity", { p_id: id });
    const row = Array.isArray(data) ? data[0] : data;
    if (error || !row) {
      setDetail(null);
      setState("error");
      return;
    }
    setDetail(row as ActivityDetail);
    setState("idle");
  };

  useEffect(() => {
    if (!activityId) {
      setDetail(null);
      setState("idle");
      return;
    }
    void load(activityId);
  }, [activityId]);

  const rows = detail ? detailRows(detail.details) : [];

  return (
    <Sheet open={Boolean(activityId)} onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-lg">
        <SheetHeader>
          <SheetTitle>{detail ? activityLabel(detail.activity) : "Activity details"}</SheetTitle>
          <SheetDescription>
            Full record for this platform event. Sensitive values are hidden.
          </SheetDescription>
        </SheetHeader>

        {state === "loading" && (
          <div className="mt-6 space-y-3" role="status" aria-label="Loading details">
            <Skeleton className="h-6 w-full" />
            <Skeleton className="h-6 w-full" />
            <Skeleton className="h-6 w-2/3" />
          </div>
        )}

        {state === "error" && (
          <div role="alert" className="mt-6 space-y-3 text-sm">
            <p>We couldn&apos;t load this activity record.</p>
            <Button variant="outline" size="sm" onClick={() => activityId && void load(activityId)}>
              Try again
            </Button>
          </div>
        )}

        {detail && state === "idle" && (
          <div className="mt-6">
            <dl>
              <Field label="Event" value={activityLabel(detail.activity)} />
              <Field label="Category" value={categoryLabel(detail.activity)} />
              <Field label="Time" value={formatActivityTime(detail.created_at)} />
              <Field label="Organization" value={detail.organization ?? "Drugxone"} />
              <Field label="Performed by" value={actorLabel(detail.performed_by_email)} />
              <Field label="Record" value={detail.record_label ?? detail.record_type} />
              <Field label="Record type" value={detail.record_type} />
              <Field label="Record ID" value={detail.record_id ?? ""} />
              <Field label="IP address" value={detail.ip_address ?? "Not captured"} />
              <Field label="Event ID" value={detail.id} />
            </dl>

            <h3 className="mt-6 text-sm font-semibold">Details</h3>
            {rows.length === 0 ? (
              <p className="mt-2 text-sm text-muted-foreground">No extra details.</p>
            ) : (
              <dl className="mt-2">
                {rows.map((row, index) => (
                  <Field key={`${row.key}-${index}`} label={row.key} value={row.value} />
                ))}
              </dl>
            )}
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}
