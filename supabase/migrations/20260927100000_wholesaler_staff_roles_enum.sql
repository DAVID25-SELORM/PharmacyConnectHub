-- Add two wholesaler-only staff roles: 'warehouse' (fulfilment: accept/pack/dispatch/deliver
-- orders, record deliveries, pick batches) and 'finance' (payments: confirm payment received,
-- send receipts). Kept in its own migration file/transaction because ALTER TYPE ... ADD VALUE
-- cannot be used in the same transaction as a statement that references the new value.
ALTER TYPE public.staff_role ADD VALUE IF NOT EXISTS 'warehouse';
ALTER TYPE public.staff_role ADD VALUE IF NOT EXISTS 'finance';
