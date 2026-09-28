-- Fulfillment status expansion, part 1: enum values + timestamp columns.
--
-- Expands the order lifecycle from pending/accepted/packed/dispatched/delivered/cancelled
-- to insert two intermediate, wholesaler-driven stages between "accepted" and "packed":
--   pending -> accepted -> picking -> packed -> ready_for_dispatch -> dispatched -> delivered
--   (cancelled remains a terminal state reachable from pending/accepted, unchanged)
--
-- ALTER TYPE ... ADD VALUE cannot run in the same transaction as anything that
-- references the new value, so this is its own migration file (own implicit
-- transaction), matching this repo's established pattern.

ALTER TYPE public.order_status ADD VALUE IF NOT EXISTS 'picking' AFTER 'accepted';
ALTER TYPE public.order_status ADD VALUE IF NOT EXISTS 'ready_for_dispatch' AFTER 'packed';

-- Lifecycle timestamps for the two new stages, mirroring the existing
-- accepted_at/packed_at/dispatched_at/delivered_at/cancelled_at columns.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS picking_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ready_for_dispatch_at TIMESTAMPTZ;
