import { useEffect, useRef, useState } from "react";

export type KeysetCursor = { created_at: string; id: string } | null;

type Row = { created_at: string; id: string };

/**
 * Shared (created_at, id) keyset pager for record-level reports (pharmacy purchase list,
 * wholesaler sales list) — same mechanics as the platform Activity Log: the fetcher is asked for
 * `limit + 1` rows so "is there a next page" is known without a COUNT(*), and a `dependsOn` key
 * change (a filter changed) resets to the first page instead of reusing a stale cursor.
 */
export function useKeysetPager<T extends Row>(
  fetcher: (cursor: KeysetCursor, limit: number) => Promise<T[]>,
  dependsOn: string,
  limit = 50,
) {
  const [rows, setRows] = useState<T[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const cursorsRef = useRef<KeysetCursor[]>([null]);
  const [pageIndex, setPageIndex] = useState(0);
  const [reloadTick, setReloadTick] = useState(0);
  const requestId = useRef(0);

  useEffect(() => {
    cursorsRef.current = [null];
    setPageIndex(0);
  }, [dependsOn]);

  useEffect(() => {
    const id = ++requestId.current;
    setLoading(true);
    setError(false);
    fetcher(cursorsRef.current[pageIndex] ?? null, limit)
      .then((fetched) => {
        if (id !== requestId.current) return;
        const page = fetched.slice(0, limit);
        const more = fetched.length > limit;
        setRows(page);
        setHasMore(more);
        const last = page[page.length - 1];
        if (more && last && cursorsRef.current.length === pageIndex + 1) {
          cursorsRef.current = [
            ...cursorsRef.current,
            { created_at: last.created_at, id: last.id },
          ];
        }
        setLoading(false);
      })
      .catch(() => {
        if (id !== requestId.current) return;
        setError(true);
        setLoading(false);
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dependsOn, pageIndex, limit, reloadTick]);

  return {
    rows,
    loading,
    error,
    hasMore,
    pageNumber: pageIndex + 1,
    canGoBack: pageIndex > 0,
    next: () => hasMore && setPageIndex((i) => i + 1),
    previous: () => pageIndex > 0 && setPageIndex((i) => Math.max(0, i - 1)),
    retry: () => setReloadTick((t) => t + 1),
    forceReload: () => {
      cursorsRef.current = [cursorsRef.current[0]];
      setPageIndex(0);
    },
  };
}
