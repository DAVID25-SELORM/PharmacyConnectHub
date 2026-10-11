import { useCallback, useEffect, useState } from "react";

/** Keep filters shareable and restore them when a tab remounts or history changes. */
export function useOrderFilter(name: string, fallback: string) {
  const key = `orders_${name}`;
  const read = useCallback(
    () =>
      typeof window === "undefined"
        ? fallback
        : (new URLSearchParams(window.location.search).get(key) ?? fallback),
    [key, fallback],
  );
  const [value, setValue] = useState(read);
  useEffect(() => {
    const update = () => setValue(read());
    window.addEventListener("popstate", update);
    return () => window.removeEventListener("popstate", update);
  }, [read]);
  const update = (next: string) => {
    setValue(next);
    const url = new URL(window.location.href);
    if (next === fallback) url.searchParams.delete(key);
    else url.searchParams.set(key, next);
    window.history.replaceState(window.history.state, "", url);
  };
  return [value, update] as const;
}
