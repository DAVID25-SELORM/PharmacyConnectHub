-- Accountant staff role, part 1: the enum value.
--
-- Unlike 'warehouse'/'finance' (wholesaler-only), 'accountant' is valid on BOTH pharmacy and
-- wholesaler businesses -- the procurement/credit/RFQ expansion needs an accountant on each side.
-- enforce_staff_role_business_type() only restricts 'warehouse'/'finance', so no trigger change
-- is needed to allow that; see the companion migration for the read-tier permission wiring.
--
-- ALTER TYPE ... ADD VALUE cannot run in the same transaction as anything that references the
-- new value, so this is its own migration file/transaction, matching this repo's established
-- pattern (see e.g. 20260927100000_wholesaler_staff_roles_enum.sql).

ALTER TYPE public.staff_role ADD VALUE IF NOT EXISTS 'accountant';
