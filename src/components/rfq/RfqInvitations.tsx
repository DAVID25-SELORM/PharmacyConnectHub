import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { RfqStatusBadge } from "./RfqStatusBadge";

export type Invitation = {
  wholesaler_id: string;
  response_status: string;
  viewed_at: string | null;
};

/** Who was invited and how each supplier has responded. */
export function RfqInvitations({
  invites,
  names,
}: {
  invites: Invitation[];
  names: Record<string, string>;
}) {
  if (!invites.length) return null;
  const viewed = invites.filter((i) => i.viewed_at).length;
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">Supplier responses</CardTitle>
        <CardDescription>
          {invites.length} invited · {viewed} viewed the request
        </CardDescription>
      </CardHeader>
      <CardContent>
        <div className="overflow-hidden rounded-lg border">
          <Table>
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead>Supplier</TableHead>
                <TableHead className="w-40">Response</TableHead>
                <TableHead className="w-40">Viewed</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {invites.map((i) => (
                <TableRow key={i.wholesaler_id}>
                  <TableCell className="font-medium">
                    {names[i.wholesaler_id] ?? "Supplier"}
                  </TableCell>
                  <TableCell>
                    <RfqStatusBadge value={i.response_status} />
                  </TableCell>
                  <TableCell className="text-sm text-muted-foreground">
                    {i.viewed_at ? "Viewed" : "Not yet viewed"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </CardContent>
    </Card>
  );
}
