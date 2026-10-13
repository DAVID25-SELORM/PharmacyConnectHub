import { useState } from "react";
import { X } from "lucide-react";
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
import { rfqCall } from "@/lib/enterprise-rfq";
import { REPORT_GROUPS, reportValue } from "@/lib/rfq-format";

type SupplierRow = {
  wholesaler_id: string;
  name: string;
  orders: number;
  delivered: number;
  cancelled: number;
  spend: number;
};
type Insight = Record<string, unknown>;

/** The procurement report for the chosen dates, and (for pharmacies) price insights on the medicines requested. */
export function RfqProcurementReport({
  report,
  buyer,
  businessId,
  onClose,
  onError,
}: {
  report: Record<string, unknown>;
  buyer: boolean;
  businessId: string;
  onClose: () => void;
  onError: (message: string) => void;
}) {
  const [insights, setInsights] = useState<Insight[] | null>(null);
  const [insightPage, setInsightPage] = useState(0);
  const loadInsights = async (page: number) => {
    try {
      setInsights(
        await rfqCall<Insight[]>("rfq_price_insights", {
          p_pharmacy_id: businessId,
          p_offset: page * 25,
        }),
      );
      setInsightPage(page);
    } catch (e) {
      onError((e as Error).message);
    }
  };
  const suppliers = Array.isArray(report.suppliers) ? (report.suppliers as SupplierRow[]) : [];
  const reasons = Array.isArray(report.declineReasons)
    ? (report.declineReasons as { reason: string; count: number }[])
    : [];
  const requested = Array.isArray(report.requestedProducts)
    ? (report.requestedProducts as {
        master_product_id: string | null;
        product_name: string;
        requests: number;
        requested: number;
      }[])
    : [];

  return (
    <Card>
      <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between sm:space-y-0">
        <div className="space-y-1.5">
          <CardTitle className="text-lg">Procurement report</CardTitle>
          <CardDescription>
            For the dates selected below. Order values are in GHS and follow linked order status. No
            savings are claimed without an approved baseline.
          </CardDescription>
        </div>
        <Button type="button" variant="ghost" size="sm" className="gap-1" onClick={onClose}>
          <X className="h-4 w-4" /> Close report
        </Button>
      </CardHeader>
      <CardContent className="space-y-6">
        <div className="grid gap-4 lg:grid-cols-2">
          {REPORT_GROUPS.map((group) => (
            <section key={group.title} className="rounded-lg border p-4">
              <h3 className="mb-3 text-sm font-medium text-muted-foreground">{group.title}</h3>
              <dl className="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-3">
                {group.fields.map(([key, label, unit]) => (
                  <div key={key}>
                    <dt className="text-xs text-muted-foreground">{label}</dt>
                    <dd className="text-xl font-semibold tabular-nums">
                      {reportValue(report[key], unit)}
                    </dd>
                  </div>
                ))}
              </dl>
            </section>
          ))}
        </div>

        {suppliers.length > 0 && (
          <section className="space-y-2">
            <h3 className="text-sm font-medium">Suppliers</h3>
            <div className="overflow-hidden rounded-lg border">
              <Table>
                <TableHeader>
                  <TableRow className="bg-muted/40 hover:bg-muted/40">
                    <TableHead>Supplier</TableHead>
                    <TableHead className="w-24 text-right">Orders</TableHead>
                    <TableHead className="w-24 text-right">Delivered</TableHead>
                    <TableHead className="w-24 text-right">Cancelled</TableHead>
                    <TableHead className="w-36 text-right">Spend</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {suppliers.map((s) => (
                    <TableRow key={s.wholesaler_id}>
                      <TableCell className="font-medium">{s.name}</TableCell>
                      <TableCell className="text-right tabular-nums">{s.orders}</TableCell>
                      <TableCell className="text-right tabular-nums">{s.delivered}</TableCell>
                      <TableCell className="text-right tabular-nums">{s.cancelled}</TableCell>
                      <TableCell className="whitespace-nowrap text-right tabular-nums">
                        {reportValue(s.spend, "ghs")}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          </section>
        )}

        {reasons.length > 0 && (
          <section className="space-y-2">
            <h3 className="text-sm font-medium">Why invitations were declined</h3>
            <ul className="divide-y rounded-lg border text-sm">
              {reasons.map((x) => (
                <li key={x.reason} className="flex justify-between gap-4 px-3 py-2">
                  <span>{x.reason}</span>
                  <span className="tabular-nums text-muted-foreground">{x.count}</span>
                </li>
              ))}
            </ul>
          </section>
        )}

        {buyer && requested.length > 0 && (
          <section className="space-y-2">
            <h3 className="text-sm font-medium">Most requested medicines</h3>
            <div className="max-h-72 overflow-auto rounded-lg border">
              <Table>
                <TableHeader>
                  <TableRow className="bg-muted/40 hover:bg-muted/40">
                    <TableHead>Medicine</TableHead>
                    <TableHead className="w-28 text-right">Requests</TableHead>
                    <TableHead className="w-28 text-right">Units</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {requested.map((x, i) => (
                    <TableRow key={`${x.master_product_id ?? x.product_name}:${i}`}>
                      <TableCell>{x.product_name}</TableCell>
                      <TableCell className="text-right tabular-nums">{x.requests}</TableCell>
                      <TableCell className="text-right tabular-nums">{x.requested}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          </section>
        )}

        {buyer && (
          <section className="space-y-2">
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="text-sm font-medium">Medicine price history</h3>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => void loadInsights(0)}
              >
                {insights ? "Reload" : "Show price history"}
              </Button>
            </div>
            {insights && (
              <>
                <div className="overflow-x-auto rounded-lg border">
                  <Table className="min-w-[640px]">
                    <TableHeader>
                      <TableRow className="bg-muted/40 hover:bg-muted/40">
                        <TableHead>Medicine</TableHead>
                        <TableHead className="w-24 text-right">Requests</TableHead>
                        <TableHead className="w-36 text-right">Previous unit price</TableHead>
                        <TableHead className="w-36 text-right">Awarded unit price</TableHead>
                        <TableHead className="w-36 text-right">Difference</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {insights.map((i, index) => (
                        <TableRow key={index}>
                          <TableCell className="font-medium">{String(i.medicine)}</TableCell>
                          <TableCell className="text-right tabular-nums">
                            {String(i.requests)}
                          </TableCell>
                          <TableCell className="whitespace-nowrap text-right tabular-nums">
                            {reportValue(i.historical_unit_price, "ghs")}
                          </TableCell>
                          <TableCell className="whitespace-nowrap text-right tabular-nums">
                            {reportValue(i.awarded_unit_price, "ghs")}
                          </TableCell>
                          <TableCell className="whitespace-nowrap text-right tabular-nums">
                            {i.historical_price_difference_ghs == null
                              ? "Not comparable"
                              : reportValue(i.historical_price_difference_ghs, "ghs")}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
                <p className="text-xs text-muted-foreground">
                  Compared with your previous delivered purchase of the same catalogue medicine.
                  Unit prices exclude delivery, and a difference is not a realised saving.
                </p>
                <div className="flex gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={!insightPage}
                    onClick={() => void loadInsights(insightPage - 1)}
                  >
                    Previous page
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={insights.length < 25}
                    onClick={() => void loadInsights(insightPage + 1)}
                  >
                    Next page
                  </Button>
                </div>
              </>
            )}
          </section>
        )}
      </CardContent>
    </Card>
  );
}
