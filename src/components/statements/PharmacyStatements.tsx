import { useState } from "react";
import { Card } from "@/components/ui/card";
import { StatementView } from "@/components/statements/StatementView";

/** Pharmacy-side statements: pick a supplier, see the same statement the supplier sees. */
export function PharmacyStatements({
  pharmacyId,
  wholesalers,
}: {
  pharmacyId: string;
  wholesalers: Array<{ id: string; name: string }>;
}) {
  const [wholesalerId, setWholesalerId] = useState("");

  return (
    <div className="space-y-4">
      <div>
        <h2 className="font-display text-xl font-bold">Statements</h2>
        <p className="text-sm text-muted-foreground">
          A running account with each supplier: what you were charged, what has been paid, and what
          is still owed.
        </p>
      </div>
      <label className="block max-w-sm text-sm">
        <span className="mb-1 block text-muted-foreground">Supplier</span>
        <select
          className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
          value={wholesalerId}
          onChange={(event) => setWholesalerId(event.target.value)}
        >
          <option value="">Choose a supplier</option>
          {wholesalers.map((wholesaler) => (
            <option key={wholesaler.id} value={wholesaler.id}>
              {wholesaler.name}
            </option>
          ))}
        </select>
      </label>
      {wholesalerId ? (
        <StatementView key={wholesalerId} wholesalerId={wholesalerId} pharmacyId={pharmacyId} />
      ) : (
        <Card className="p-10 text-center text-sm text-muted-foreground">
          Choose a supplier to see your statement.
        </Card>
      )}
    </div>
  );
}
