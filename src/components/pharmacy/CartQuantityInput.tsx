import { useState } from "react";
import { Input } from "@/components/ui/input";

/** Commit valid quantities immediately so checkout and totals never lag behind typing.
 * Empty/zero drafts let users replace the number without removing the cart item. */
export function CartQuantityInput({
  quantity,
  productName,
  onChange,
}: {
  quantity: number;
  productName: string;
  onChange: (quantity: number) => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  return (
    <Input
      type="text"
      inputMode="numeric"
      pattern="[0-9]*"
      aria-label={`Quantity for ${productName}`}
      className="h-8 w-16 px-1 text-center text-sm font-medium"
      value={draft ?? String(quantity)}
      onChange={(event) => {
        const value = event.target.value;
        if (!/^\d*$/.test(value)) return;
        const next = Number(value);
        if (!Number.isSafeInteger(next)) return;
        if (value === "" || next === 0) {
          setDraft(value);
          return;
        }
        setDraft(null);
        onChange(next);
      }}
      onBlur={() => setDraft(null)}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === "Escape") {
          event.preventDefault();
          event.currentTarget.blur();
        }
      }}
    />
  );
}
