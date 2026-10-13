import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { RFQ_TERM_LABELS } from "@/lib/rfq-format";
import { RfqStatusBadge } from "./RfqStatusBadge";

export type Negotiation = {
  id: string;
  wholesaler_id: string;
  status: string;
  proposal: Record<string, string>;
  response: string | null;
};

const ACTIONS: [action: string, text: string][] = [
  ["accepted", "Accept"],
  ["countered", "Counter"],
  ["rejected", "Reject"],
];

/** Requests to revise a supplier's terms, and the supplier's replies. */
export function RfqNegotiations({
  negotiations,
  names,
  buyer,
  canRespond,
  busy,
  onRespond,
}: {
  negotiations: Negotiation[];
  names: Record<string, string>;
  buyer: boolean;
  canRespond: boolean;
  busy: boolean;
  onRespond: (negotiation: Negotiation, action: string) => void;
}) {
  if (!negotiations.length) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">Negotiations</CardTitle>
        <CardDescription>
          {buyer
            ? "Changes you asked suppliers to make to their quotations."
            : "Changes the buyer asked you to make. Reply to each request."}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {negotiations.map((n) => (
          <div key={n.id} className="space-y-2 rounded-lg border p-4">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium">{names[n.wholesaler_id] ?? "Supplier"}</span>
              <RfqStatusBadge value={n.status} />
            </div>
            <ul className="flex flex-wrap gap-2 text-sm">
              {Object.entries(n.proposal).map(([term, value]) => (
                <li key={term} className="rounded-md bg-muted px-2.5 py-1">
                  <span className="text-muted-foreground">{RFQ_TERM_LABELS[term] ?? term}: </span>
                  <span className="font-medium">{value}</span>
                </li>
              ))}
            </ul>
            {n.response && (
              <p className="rounded-md border-l-2 border-primary/40 bg-muted/40 px-3 py-2 text-sm">
                <span className="text-muted-foreground">Reply: </span>
                {n.response}
              </p>
            )}
            {!buyer && canRespond && n.status === "requested" && (
              <div className="flex flex-wrap gap-2 pt-1">
                {ACTIONS.map(([action, text]) => (
                  <Button
                    key={action}
                    type="button"
                    size="sm"
                    variant={action === "accepted" ? "default" : "outline"}
                    disabled={busy}
                    onClick={() => onRespond(n, action)}
                  >
                    {text}…
                  </Button>
                ))}
              </div>
            )}
          </div>
        ))}
      </CardContent>
    </Card>
  );
}
