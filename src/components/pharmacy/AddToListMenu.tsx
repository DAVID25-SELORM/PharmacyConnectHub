import { useState } from "react";
import { ListPlus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import type { ReorderListsApi } from "@/hooks/use-reorder-lists";

/** "Add to list" on a catalogue medicine: pick an existing list or create one. */
export function AddToListMenu({
  masterProductId,
  name,
  lists,
}: {
  masterProductId: string;
  name: string;
  lists: ReorderListsApi;
}) {
  const [newName, setNewName] = useState("");

  const add = async (listId: string, listName: string) => {
    const already = lists.lists
      .find((list) => list.id === listId)
      ?.items.some((item) => item.master_product_id === masterProductId);
    if (already) return toast.info(`${name} is already on "${listName}".`);
    if (await lists.addItem(listId, { masterProductId, name, quantity: 1 })) {
      toast.success(`Added to "${listName}"`);
    }
  };

  const createAndAdd = async () => {
    const id = await lists.createList(newName);
    if (!id) return;
    setNewName("");
    await add(id, newName.trim());
  };

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="outline" size="sm" aria-label={`Add ${name} to a reorder list`}>
          <ListPlus className="mr-1 h-4 w-4" aria-hidden="true" />
          Add to list
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64">
        <DropdownMenuLabel>Reorder lists</DropdownMenuLabel>
        {lists.lists.length === 0 && (
          <div className="px-2 py-1.5 text-sm text-muted-foreground">No lists yet.</div>
        )}
        {lists.lists.map((list) => (
          <DropdownMenuItem key={list.id} onSelect={() => void add(list.id, list.name)}>
            {list.name}
            <span className="ml-auto text-xs text-muted-foreground">{list.items.length}</span>
          </DropdownMenuItem>
        ))}
        <DropdownMenuSeparator />
        <form
          className="flex gap-2 p-2"
          onSubmit={(event) => {
            event.preventDefault();
            void createAndAdd();
          }}
          onKeyDown={(event) => event.stopPropagation()}
        >
          <Input
            value={newName}
            onChange={(event) => setNewName(event.target.value)}
            placeholder="New list name"
            maxLength={60}
            aria-label="New list name"
          />
          <Button type="submit" size="sm" disabled={newName.trim().length === 0}>
            Create
          </Button>
        </form>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
