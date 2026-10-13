import { ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

/** The buyer's status actions for a published request. Each one that needs a reason or a date asks for it first. */
export function RfqManageMenu({
  status,
  busy,
  onExtend,
  onEvaluate,
  onCloseRemaining,
  onComplete,
  onCancel,
}: {
  status: string;
  busy: boolean;
  onExtend: () => void;
  onEvaluate: () => void;
  onCloseRemaining: () => void;
  onComplete: () => void;
  onCancel: () => void;
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button type="button" variant="outline" className="gap-1" disabled={busy}>
          Manage request <ChevronDown className="h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64">
        <DropdownMenuItem onSelect={onExtend}>Extend the quotation deadline…</DropdownMenuItem>
        <DropdownMenuItem disabled={status !== "open"} onSelect={onEvaluate}>
          Begin evaluation
        </DropdownMenuItem>
        <DropdownMenuItem onSelect={onCloseRemaining}>
          Close remaining requirements…
        </DropdownMenuItem>
        <DropdownMenuItem onSelect={onComplete}>
          Mark the resolved request complete
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem className="text-destructive focus:text-destructive" onSelect={onCancel}>
          Cancel the request…
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
