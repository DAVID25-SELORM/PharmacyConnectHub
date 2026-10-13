import { ExternalLink } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { Allocation, AwardGroup } from "@/lib/enterprise-rfq";
import { formatGHS } from "@/lib/format";
import { paymentLabel } from "@/lib/rfq-format";
import { RfqStatusBadge } from "./RfqStatusBadge";

/** Awards proposed to suppliers, their confirmation and the orders they became. */
export function RfqAwards({
  groups,
  allocations,
  names,
  buyer,
  canConfirm,
  busy,
  onPdf,
  onConfirm,
  onDecline,
}: {
  groups: AwardGroup[];
  allocations: Allocation[];
  names: Record<string, string>;
  buyer: boolean;
  /** The supplier can confirm or decline awards made to it. */
  canConfirm: boolean;
  busy: boolean;
  onPdf: (group: AwardGroup) => void;
  onConfirm: (group: AwardGroup) => void;
  onDecline: (group: AwardGroup) => void;
}) {
  if (!groups.length) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">Awards and linked orders</CardTitle>
        <CardDescription>
          {buyer
            ? "Awards wait for each supplier to confirm availability. A confirmed award creates an order in your usual order management."
            : "Confirm that you can supply an award to create the order, or decline it with a reason."}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <div className="overflow-hidden rounded-lg border">
          <div className="overflow-x-auto">
            <Table className="min-w-[820px]">
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead>Supplier</TableHead>
                  <TableHead className="w-40">Status</TableHead>
                  <TableHead className="w-20 text-right">Lines</TableHead>
                  <TableHead className="w-36 text-right">Total with delivery</TableHead>
                  <TableHead className="w-36">Settlement</TableHead>
                  <TableHead className="w-72">
                    <span className="sr-only">Actions</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {groups.map((g) => {
                  const lines = allocations.filter((a) => a.group_id === g.id).length;
                  const waiting =
                    !buyer && canConfirm && ["pending", "conversion_failed"].includes(g.status);
                  return (
                    <TableRow key={g.id}>
                      <TableCell className="align-top">
                        <div className="font-medium">{names[g.wholesaler_id] ?? "Supplier"}</div>
                        {g.reason && (
                          <p className="mt-1 text-xs text-muted-foreground">{g.reason}</p>
                        )}
                        {g.last_error && (
                          <p role="alert" className="mt-1 text-xs text-destructive">
                            {g.last_error}
                          </p>
                        )}
                      </TableCell>
                      <TableCell className="align-top">
                        <RfqStatusBadge value={g.status} />
                      </TableCell>
                      <TableCell className="align-top text-right tabular-nums">{lines}</TableCell>
                      <TableCell className="whitespace-nowrap align-top text-right font-medium tabular-nums">
                        {formatGHS(Number(g.goods_ghs) + Number(g.delivery_ghs))}
                      </TableCell>
                      <TableCell className="align-top text-sm">
                        {paymentLabel(g.settlement_method)}
                      </TableCell>
                      <TableCell className="align-top">
                        <div className="flex flex-wrap justify-end gap-2">
                          {waiting && (
                            <>
                              <Button
                                type="button"
                                size="sm"
                                disabled={busy}
                                onClick={() => onConfirm(g)}
                              >
                                Confirm and create order
                              </Button>
                              <Button
                                type="button"
                                size="sm"
                                variant="outline"
                                disabled={busy}
                                onClick={() => onDecline(g)}
                              >
                                Decline…
                              </Button>
                            </>
                          )}
                          <Button type="button" size="sm" variant="ghost" onClick={() => onPdf(g)}>
                            Award PDF
                          </Button>
                          {g.order_id && (
                            <Button asChild size="sm" variant="ghost" className="gap-1">
                              <a href={`/${buyer ? "pharmacy" : "wholesaler"}?tab=orders`}>
                                Order {g.order_id.slice(0, 8)} <ExternalLink className="h-3 w-3" />
                              </a>
                            </Button>
                          )}
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
