import { toast } from "sonner";

export const MODULE_LOAD_MESSAGE =
  "This screen could not load. Check your connection, then refresh. Save any unfinished work first.";

/** Keep drafts intact: recovery only reloads when the user chooses it. */
export function installChunkRecovery(
  target: Window = window,
  reload: () => void = () => target.location.reload(),
) {
  const onError = (event: Event) => {
    const error = (event as Event & { payload?: unknown }).payload;
    if (error instanceof Error) error.message = MODULE_LOAD_MESSAGE;
    toast.error(MODULE_LOAD_MESSAGE, {
      id: "module-load-recovery",
      duration: Infinity,
      action: { label: "Refresh app", onClick: reload },
    });
    // Do not preventDefault: callers must reject and run their cleanup, rather
    // than continuing with an undefined module or claiming an export succeeded.
  };
  target.addEventListener("vite:preloadError", onError);
  return () => target.removeEventListener("vite:preloadError", onError);
}
