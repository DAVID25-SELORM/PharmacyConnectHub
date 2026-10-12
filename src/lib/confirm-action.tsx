import { useSyncExternalStore } from "react";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogCancel,
  AlertDialogAction,
} from "@/components/ui/alert-dialog";

type Request = { message: string; resolve: (answer: boolean) => void };
let current: Request | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((listener) => listener());
/** Fail closed when another confirmation is already pending. Never replace its action. */
export function confirmAction(message: string): Promise<boolean> {
  if (current) return Promise.resolve(false);
  return new Promise((resolve) => {
    current = { message, resolve };
    emit();
  });
}
function finish(answer: boolean) {
  const request = current;
  current = null;
  emit();
  request?.resolve(answer);
}
export function ConfirmationHost() {
  const request = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    () => current,
    () => null,
  );
  return (
    <AlertDialog
      open={!!request}
      onOpenChange={(open) => {
        if (!open) finish(false);
      }}
    >
      <AlertDialogContent className="z-[100]">
        <AlertDialogHeader>
          <AlertDialogTitle>Confirm action</AlertDialogTitle>
          <AlertDialogDescription>{request?.message}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel onClick={() => finish(false)}>Keep working</AlertDialogCancel>
          <AlertDialogAction onClick={() => finish(true)}>Continue</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
