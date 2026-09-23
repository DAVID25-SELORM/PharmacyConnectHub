import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";

export type ReportKpi = {
  label: string;
  value: string;
  helper?: string;
  icon?: React.ReactNode;
};

/** Compact, responsive KPI row shared by every report Overview tab. */
export function ReportKpis({ items, loading }: { items: ReportKpi[]; loading: boolean }) {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
      {items.map((item) => (
        <Card key={item.label} className="flex h-full flex-col justify-between p-4">
          <div className="flex items-center justify-between gap-2">
            <div className="text-sm font-medium text-muted-foreground">{item.label}</div>
            {item.icon && <span aria-hidden="true">{item.icon}</span>}
          </div>
          {loading ? (
            <Skeleton className="mt-2 h-8 w-20" />
          ) : (
            <div className="mt-2 font-display text-2xl font-bold">{item.value}</div>
          )}
          {item.helper && <div className="mt-1 text-xs text-muted-foreground">{item.helper}</div>}
        </Card>
      ))}
    </div>
  );
}
