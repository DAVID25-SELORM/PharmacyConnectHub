import { useEffect, useRef, useState } from "react";
import { Input } from "@/components/ui/input";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { supabase } from "@/integrations/supabase/client";
import { masterProductLabel, toIlikeTerm, type MasterProductSuggestion } from "@/lib/rfq";

/** Product-name input for an RFQ line: suggests medicines from the shared DrugXOne catalogue as the
 * pharmacy types, but never blocks free text -- a pharmacy can still request something that isn't
 * catalogued (e.g. a consumable). Picking a suggestion fills in the catalogue's own wording. */
export function MedicationPicker({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  const [suggestions, setSuggestions] = useState<MasterProductSuggestion[]>([]);
  const [open, setOpen] = useState(false);
  const picked = useRef<string | null>(null);
  const debounced = useDebouncedValue(value, 250);

  useEffect(() => {
    const term = toIlikeTerm(debounced);
    if (term.length < 2 || picked.current === debounced) {
      setSuggestions([]);
      return;
    }
    let cancelled = false;
    void supabase
      .from("master_products")
      .select("id, name, generic_name, brand_name, strength, dosage_form, pack_size")
      .eq("active", true)
      .or(`name.ilike.%${term}%,generic_name.ilike.%${term}%,brand_name.ilike.%${term}%`)
      .order("name")
      .limit(8)
      .then(({ data }) => {
        if (!cancelled) setSuggestions((data as MasterProductSuggestion[] | null) ?? []);
      });
    return () => {
      cancelled = true;
    };
  }, [debounced]);

  const showList = open && suggestions.length > 0;

  return (
    <div className="relative">
      <Input
        value={value}
        onChange={(e) => {
          picked.current = null;
          onChange(e.target.value);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onKeyDown={(e) => e.key === "Escape" && setOpen(false)}
        placeholder="Search medicines or type a name"
        aria-label="Product name"
        aria-autocomplete="list"
        autoComplete="off"
      />
      {showList && (
        <ul
          role="listbox"
          className="absolute z-50 mt-1 max-h-56 w-full overflow-y-auto rounded-md border border-border bg-popover text-sm shadow-md"
        >
          {suggestions.map((product) => {
            const label = masterProductLabel(product);
            return (
              <li
                key={product.id}
                role="option"
                aria-selected={false}
                className="cursor-pointer px-3 py-2 hover:bg-accent"
                // mousedown fires before the input's blur, so the pick isn't lost to the list closing.
                onMouseDown={(e) => {
                  e.preventDefault();
                  picked.current = label;
                  onChange(label);
                  setSuggestions([]);
                  setOpen(false);
                }}
              >
                <div className="font-medium">{label}</div>
                {(product.generic_name || product.brand_name) && (
                  <div className="text-xs text-muted-foreground">
                    {[product.generic_name, product.brand_name].filter(Boolean).join(" · ")}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
