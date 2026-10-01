import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import {
  actorLabel,
  auditActivityLabel,
  auditCategoryLabel,
  detailRows,
  formatActivityTime,
  type AuditLogRow,
} from "@/lib/audit-centre";

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-3 gap-2 border-b border-border py-2 text-sm last:border-0">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="col-span-2 break-words font-medium">{value || "—"}</dd>
    </div>
  );
}

export function AuditLogDetailSheet({
  row,
  onClose,
}: {
  row: AuditLogRow | null;
  onClose: () => void;
}) {
  const rows = row ? detailRows(row.details) : [];

  return (
    <Sheet open={row !== null} onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-lg">
        <SheetHeader>
          <SheetTitle>{row ? auditActivityLabel(row.activity) : "Audit log details"}</SheetTitle>
          <SheetDescription>Full record for this event. Sensitive values are hidden.</SheetDescription>
        </SheetHeader>

        {row && (
          <div className="mt-6">
            <dl>
              <Field label="Event" value={auditActivityLabel(row.activity)} />
              <Field label="Category" value={auditCategoryLabel(row.activity)} />
              <Field label="Time" value={formatActivityTime(row.created_at)} />
              <Field label="Performed by" value={actorLabel(row.performed_by_email)} />
              <Field label="Record" value={row.record_label ?? row.record_type} />
              <Field label="Record type" value={row.record_type} />
              <Field label="Record ID" value={row.record_id ?? ""} />
              <Field label="Event ID" value={row.id} />
            </dl>

            <h3 className="mt-6 text-sm font-semibold">Details</h3>
            {rows.length === 0 ? (
              <p className="mt-2 text-sm text-muted-foreground">No extra details.</p>
            ) : (
              <dl className="mt-2">
                {rows.map((item, index) => (
                  <Field key={`${item.key}-${index}`} label={item.key} value={item.value} />
                ))}
              </dl>
            )}
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}
