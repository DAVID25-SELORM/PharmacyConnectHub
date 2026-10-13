import { Badge } from "@/components/ui/badge";
import { label } from "@/lib/enterprise-rfq";
import { statusTone, type StatusTone } from "@/lib/rfq-format";

const TONES: Record<StatusTone, string> = {
  success: "border-success/30 bg-success/15 text-success",
  primary: "border-primary/30 bg-primary/10 text-primary",
  warning: "border-warning/30 bg-warning/15 text-warning-foreground",
  danger: "border-destructive/30 bg-destructive/15 text-destructive",
  muted: "border-border bg-muted text-muted-foreground",
};

/** A request, invitation, award or negotiation status as a coloured, readable badge. */
export function RfqStatusBadge({ value, className }: { value: string; className?: string }) {
  const text = label(value);
  return (
    <Badge
      variant="secondary"
      className={`border font-medium capitalize ${TONES[statusTone(value)]} ${className ?? ""}`}
    >
      {text}
    </Badge>
  );
}
