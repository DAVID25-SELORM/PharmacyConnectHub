import { Badge } from "@/components/ui/badge";
import {
  Clock,
  CheckCircle2,
  PackageCheck,
  Truck,
  XCircle,
  Banknote,
  CreditCard,
} from "lucide-react";
import { timeAgo } from "@/lib/format";

export type OrderStatus =
  | "pending"
  | "accepted"
  | "packed"
  | "dispatched"
  | "delivered"
  | "cancelled";
export type PaymentMethod = "cod" | "paystack";
export type PaymentStatus = "unpaid" | "paid" | "refunded" | "failed";

export type OrderTimelineData = {
  status: OrderStatus;
  created_at: string;
  accepted_at: string | null;
  packed_at: string | null;
  dispatched_at: string | null;
  delivered_at: string | null;
  cancelled_at: string | null;
  cancellation_reason?: string | null;
};

export function StatusBadge({ status }: { status: OrderStatus }) {
  const map: Record<OrderStatus, { icon: typeof Clock; cls: string; label: string }> = {
    pending: {
      icon: Clock,
      cls: "bg-warning/15 text-warning-foreground border-warning/30",
      label: "Pending",
    },
    accepted: {
      icon: CheckCircle2,
      cls: "bg-primary/15 text-primary border-primary/30",
      label: "Accepted",
    },
    packed: {
      icon: PackageCheck,
      cls: "bg-primary/15 text-primary border-primary/30",
      label: "Packed",
    },
    dispatched: {
      icon: Truck,
      cls: "bg-accent/15 text-accent border-accent/30",
      label: "Dispatched",
    },
    delivered: {
      icon: CheckCircle2,
      cls: "bg-success/15 text-success border-success/30",
      label: "Delivered",
    },
    cancelled: {
      icon: XCircle,
      cls: "bg-destructive/15 text-destructive border-destructive/30",
      label: "Cancelled",
    },
  };
  const cfg = map[status];
  const Icon = cfg.icon;
  return (
    <Badge variant="secondary" className={`gap-1 border ${cfg.cls}`}>
      <Icon className="h-3 w-3" /> {cfg.label}
    </Badge>
  );
}

export function PaymentBadge({ method, status }: { method: PaymentMethod; status: PaymentStatus }) {
  if (method === "cod") {
    return (
      <Badge
        variant="secondary"
        className="gap-1 border border-border bg-muted text-muted-foreground"
      >
        <Banknote className="h-3 w-3" /> Pay on delivery
      </Badge>
    );
  }
  const cfg =
    status === "paid"
      ? { cls: "bg-success/15 text-success border-success/30", label: "Paid" }
      : status === "failed"
        ? {
            cls: "bg-destructive/15 text-destructive border-destructive/30",
            label: "Payment failed",
          }
        : status === "refunded"
          ? { cls: "bg-muted text-muted-foreground border-border", label: "Refunded" }
          : {
              cls: "bg-warning/15 text-warning-foreground border-warning/30",
              label: "Awaiting payment",
            };
  return (
    <Badge variant="secondary" className={`gap-1 border ${cfg.cls}`}>
      <CreditCard className="h-3 w-3" /> {cfg.label}
    </Badge>
  );
}

export function OrderTimeline({ o }: { o: OrderTimelineData }) {
  const steps: { key: string; label: string; at: string | null; icon: typeof Clock }[] = [
    { key: "placed", label: "Placed", at: o.created_at, icon: Clock },
    { key: "accepted", label: "Accepted", at: o.accepted_at, icon: CheckCircle2 },
    { key: "packed", label: "Packed", at: o.packed_at, icon: PackageCheck },
    { key: "dispatched", label: "Dispatched", at: o.dispatched_at, icon: Truck },
    { key: "delivered", label: "Delivered", at: o.delivered_at, icon: CheckCircle2 },
  ];
  if (o.status === "cancelled") {
    return (
      <div className="mt-4 rounded-xl border border-destructive/30 bg-destructive/5 p-3 text-sm">
        <div className="flex items-center gap-2">
          <XCircle className="h-4 w-4 text-destructive" />
          <span className="text-destructive font-medium">
            Cancelled {o.cancelled_at ? timeAgo(o.cancelled_at) : ""}
          </span>
        </div>
        {o.cancellation_reason && (
          <p className="mt-1 pl-6 text-xs text-muted-foreground">Reason: {o.cancellation_reason}</p>
        )}
      </div>
    );
  }
  return (
    <div className="mt-4 flex items-center gap-1 overflow-x-auto pb-1">
      {steps.map((s, i) => {
        const done = !!s.at;
        const Icon = s.icon;
        return (
          <div key={s.key} className="flex items-center gap-1 shrink-0">
            <div
              className={`flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] ${
                done ? "bg-success/15 text-success" : "bg-muted text-muted-foreground"
              }`}
            >
              <Icon className="h-3 w-3" />
              <span>{s.label}</span>
              {done && <span className="opacity-70">· {timeAgo(s.at!)}</span>}
            </div>
            {i < steps.length - 1 && (
              <div className={`h-px w-3 ${done ? "bg-success/40" : "bg-border"}`} />
            )}
          </div>
        );
      })}
    </div>
  );
}
