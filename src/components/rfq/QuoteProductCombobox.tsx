import { useEffect, useState } from "react";
import { ChevronsUpDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { rfqDb } from "@/lib/enterprise-rfq";
import { toIlikeTerm } from "@/lib/rfq";

export type OfferedProduct = { id: string; name: string; stock: number; price_ghs?: number };

/** Searchable picker over the supplier's own active catalogue. It only searches while it is open. */
export function QuoteProductCombobox({
  businessId,
  selected,
  hasValue,
  onPick,
  disabled = false,
  label,
}: {
  businessId: string;
  selected?: OfferedProduct;
  /** A product is chosen even when its name has not been looked up yet. */
  hasValue: boolean;
  onPick: (product: OfferedProduct | null) => void;
  disabled?: boolean;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const search = useDebouncedValue(query, 250);
  const [rows, setRows] = useState<OfferedProduct[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!open) return;
    let active = true;
    setLoading(true);
    void rfqDb
      .from("products")
      .select("id,name,stock,price_ghs")
      .eq("wholesaler_id", businessId)
      .eq("active", true)
      .ilike("name", `%${toIlikeTerm(search)}%`)
      .order("name")
      .limit(25)
      .then(
        ({ data, error }: { data: OfferedProduct[] | null; error: { message: string } | null }) => {
          if (!active) return;
          setRows(data ?? []);
          setError(error?.message ?? "");
          setLoading(false);
        },
      );
    return () => {
      active = false;
    };
  }, [open, businessId, search]);

  return (
    <Popover
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (!next) setQuery("");
      }}
    >
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          role="combobox"
          aria-expanded={open}
          aria-label={label}
          disabled={disabled}
          className="h-9 w-full justify-between gap-2 px-3 font-normal"
        >
          <span className={`truncate text-left ${hasValue ? "" : "text-muted-foreground"}`}>
            {hasValue ? (selected?.name ?? "Selected product") : "Choose your product"}
          </span>
          <ChevronsUpDown className="h-3.5 w-3.5 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-[360px] p-0">
        <Command shouldFilter={false}>
          <CommandInput
            placeholder="Search your catalogue"
            value={query}
            onValueChange={setQuery}
          />
          <CommandList>
            {error ? (
              <p role="alert" className="p-3 text-sm text-destructive">
                {error}
              </p>
            ) : (
              <CommandEmpty>
                {loading ? "Searching…" : "No matching product in your catalogue."}
              </CommandEmpty>
            )}
            {rows.map((p) => (
              <CommandItem
                key={p.id}
                value={p.id}
                onSelect={() => {
                  onPick(p);
                  setOpen(false);
                  setQuery("");
                }}
              >
                <span className="flex-1 truncate">{p.name}</span>
                <span className="ml-2 shrink-0 text-xs tabular-nums text-muted-foreground">
                  {p.stock} in stock
                </span>
              </CommandItem>
            ))}
          </CommandList>
          {hasValue && (
            <div className="border-t p-1">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="w-full justify-start text-muted-foreground"
                onClick={() => {
                  onPick(null);
                  setOpen(false);
                }}
              >
                Not quoting this line
              </Button>
            </div>
          )}
        </Command>
      </PopoverContent>
    </Popover>
  );
}
