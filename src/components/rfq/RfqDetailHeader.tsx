import type { ReactNode } from "react";
import { ArrowLeft, Globe, Lock } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import type { EnterpriseRfq } from "@/lib/enterprise-rfq";
import { paymentLabel, rfqDate, rfqDateTime } from "@/lib/rfq-format";
import { RfqStatusBadge } from "./RfqStatusBadge";

/** Title, status and the key facts of a request, with the actions available to this viewer. */
export function RfqDetailHeader({
  rfq,
  quoteCount,
  onBack,
  actions,
}: {
  rfq: EnterpriseRfq;
  quoteCount: number;
  onBack: () => void;
  /** Buttons for what this person can do now. */
  actions?: ReactNode;
}) {
  const open = rfq.visibility === "open";
  return (
    <Card>
      <CardContent className="space-y-5 p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="space-y-2">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="-ml-2 gap-1 text-muted-foreground"
              onClick={onBack}
            >
              <ArrowLeft className="h-4 w-4" /> Back to requests
            </Button>
            <h2 className="text-2xl font-semibold tracking-tight">{rfq.title}</h2>
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-mono text-muted-foreground">{rfq.reference}</span>
              <RfqStatusBadge value={rfq.display_status ?? rfq.status} />
              <Badge variant="outline" className="gap-1 font-normal">
                {open ? <Globe className="h-3 w-3" /> : <Lock className="h-3 w-3" />}
                {open ? "Open to approved wholesalers" : "Private invitations"}
              </Badge>
              <span className="text-muted-foreground">
                {quoteCount} quotation{quoteCount === 1 ? "" : "s"}
              </span>
            </div>
          </div>
          {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
        </div>

        <dl className="grid gap-x-8 gap-y-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
          {(
            [
              ["Respond by", rfqDateTime(rfq.response_deadline)],
              ["Delivery needed", rfqDate(rfq.expected_delivery_date)],
              ["Deliver to", rfq.delivery_location || "Pharmacy address"],
              ["Payment preference", paymentLabel(rfq.payment_preference)],
            ] as const
          ).map(([name, value]) => (
            <div key={name}>
              <dt className="text-xs uppercase tracking-wide text-muted-foreground">{name}</dt>
              <dd className="font-medium">{value}</dd>
            </div>
          ))}
          {rfq.delivery_instructions && (
            <div className="sm:col-span-2 lg:col-span-4">
              <dt className="text-xs uppercase tracking-wide text-muted-foreground">
                Delivery and handling instructions
              </dt>
              <dd className="whitespace-pre-line">{rfq.delivery_instructions}</dd>
            </div>
          )}
          {rfq.notes && (
            <div className="sm:col-span-2 lg:col-span-4">
              <dt className="text-xs uppercase tracking-wide text-muted-foreground">Description</dt>
              <dd className="whitespace-pre-line">{rfq.notes}</dd>
            </div>
          )}
        </dl>
      </CardContent>
    </Card>
  );
}
