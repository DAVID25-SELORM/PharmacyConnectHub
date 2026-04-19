import { useState } from "react";
import { Check, ChevronsUpDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { cn } from "@/lib/utils";

export type SearchableSelectOption = {
  value: string;
  label: string;
  description?: string;
  keywords?: string[];
  searchText?: string;
};

export function SearchableSelect({
  options,
  value,
  onValueChange,
  placeholder,
  searchPlaceholder,
  emptyLabel = "No option found.",
  className,
  popoverClassName,
}: {
  options: SearchableSelectOption[];
  value: string;
  onValueChange: (value: string) => void;
  placeholder: string;
  searchPlaceholder: string;
  emptyLabel?: string;
  className?: string;
  popoverClassName?: string;
}) {
  const [open, setOpen] = useState(false);
  const selectedOption = options.find((option) => option.value === value) ?? null;

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          role="combobox"
          aria-expanded={open}
          className={cn("w-full justify-between lg:w-56", className)}
        >
          <span className="truncate">{selectedOption?.label ?? placeholder}</span>
          <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent
        align="start"
        className={cn("w-[min(24rem,calc(100vw-2rem))] p-0", popoverClassName)}
      >
        <Command>
          <CommandInput placeholder={searchPlaceholder} />
          <CommandList>
            <CommandEmpty>{emptyLabel}</CommandEmpty>
            <CommandGroup>
              {options.map((option) => (
                <CommandItem
                  key={option.value}
                  value={option.searchText ?? option.label}
                  keywords={option.keywords}
                  onSelect={() => {
                    onValueChange(option.value);
                    setOpen(false);
                  }}
                >
                  <Check
                    className={cn("h-4 w-4", value === option.value ? "opacity-100" : "opacity-0")}
                  />
                  <div className="min-w-0">
                    <div className="truncate font-medium">{option.label}</div>
                    {option.description && (
                      <div className="truncate text-xs text-muted-foreground">
                        {option.description}
                      </div>
                    )}
                  </div>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
