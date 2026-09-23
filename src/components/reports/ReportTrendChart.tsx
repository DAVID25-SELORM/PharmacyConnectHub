import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { Card } from "@/components/ui/card";
import { formatReportDate } from "@/lib/reports";

export type TrendPoint = { bucket: string; orders: number; value: number };

/**
 * One shared time-series chart: orders + a money value (GMV/spend/sales) per day, already
 * bucketed by the database — the chart never receives more points than there are days in range.
 */
export function ReportTrendChart({
  title,
  valueLabel,
  points,
  loading,
}: {
  title: string;
  valueLabel: string;
  points: TrendPoint[];
  loading: boolean;
}) {
  return (
    <Card className="p-4">
      <div className="text-sm font-semibold">{title}</div>
      {loading ? (
        <div
          className="mt-4 h-56 animate-pulse rounded-lg bg-muted"
          role="status"
          aria-label="Loading chart"
        />
      ) : points.length === 0 ? (
        <p className="mt-4 py-16 text-center text-sm text-muted-foreground">
          No data for this range.
        </p>
      ) : (
        <div className="mt-2 h-56">
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={points} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
              <XAxis
                dataKey="bucket"
                tickFormatter={(value: string) => formatReportDate(value)}
                fontSize={11}
                minTickGap={24}
              />
              <YAxis yAxisId="value" fontSize={11} width={44} />
              <YAxis yAxisId="orders" orientation="right" fontSize={11} width={32} />
              <Tooltip
                labelFormatter={(value: string) => formatReportDate(value)}
                formatter={(value: number, name: string) => [
                  value.toLocaleString(),
                  name === "value" ? valueLabel : "Orders",
                ]}
              />
              <Line
                yAxisId="value"
                type="monotone"
                dataKey="value"
                stroke="hsl(var(--primary))"
                strokeWidth={2}
                dot={false}
              />
              <Line
                yAxisId="orders"
                type="monotone"
                dataKey="orders"
                stroke="hsl(var(--accent))"
                strokeWidth={2}
                dot={false}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}
    </Card>
  );
}
