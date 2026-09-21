/**
 * DrugXone — Checkout Audit Attribution Staging Check
 *
 * File:
 *   tests/staging/checkout-audit.mjs
 *
 * Purpose:
 *   Verify that a staging checkout/order has:
 *   1. A generic audit event with trusted actor attribution.
 *   2. Inventory movement attribution preserved.
 *
 * This is intentionally NOT a Vitest file.
 * It is a standalone staging verification script.
 *
 * It performs READ-ONLY queries.
 * It does not:
 *   - create orders
 *   - alter stock
 *   - modify audit rows
 *   - modify users
 *   - update production
 *
 * Required environment variables:
 *
 *   STAGING_SUPABASE_URL
 *   STAGING_SUPABASE_SERVICE_ROLE_KEY
 *   STAGING_CHECKOUT_ORDER_ID
 *
 * Optional:
 *
 *   STAGING_EXPECTED_ACTOR_ID
 *   STAGING_EXPECTED_ACTOR_EMAIL
 *   STAGING_AUDIT_TABLE
 *   STAGING_MOVEMENT_TABLE
 *
 * Defaults:
 *
 *   STAGING_AUDIT_TABLE=audit_logs
 *   STAGING_MOVEMENT_TABLE=inventory_movements
 *
 * Example PowerShell:
 *
 *   $env:STAGING_SUPABASE_URL="https://xxxxx.supabase.co"
 *   $env:STAGING_SUPABASE_SERVICE_ROLE_KEY="..."
 *   $env:STAGING_CHECKOUT_ORDER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
 *   $env:STAGING_EXPECTED_ACTOR_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
 *   node tests/staging/checkout-audit.mjs
 */

import { createClient } from '@supabase/supabase-js'

const {
  STAGING_SUPABASE_URL,
  STAGING_SUPABASE_SERVICE_ROLE_KEY,
  STAGING_CHECKOUT_ORDER_ID,
  STAGING_EXPECTED_ACTOR_ID,
  STAGING_EXPECTED_ACTOR_EMAIL,
  STAGING_AUDIT_TABLE = 'audit_logs',
  STAGING_MOVEMENT_TABLE = 'inventory_movements',
} = process.env

function fail(message, details) {
  console.error(`\n❌ FAIL: ${message}`)

  if (details) {
    console.error(details)
  }

  process.exit(1)
}

function pass(message) {
  console.log(`✅ ${message}`)
}

function info(message) {
  console.log(`ℹ️  ${message}`)
}

function requireEnvironmentVariable(name, value) {
  if (!value || !String(value).trim()) {
    fail(`Missing required environment variable: ${name}`)
  }
}

requireEnvironmentVariable('STAGING_SUPABASE_URL', STAGING_SUPABASE_URL)
requireEnvironmentVariable(
  'STAGING_SUPABASE_SERVICE_ROLE_KEY',
  STAGING_SUPABASE_SERVICE_ROLE_KEY,
)
requireEnvironmentVariable(
  'STAGING_CHECKOUT_ORDER_ID',
  STAGING_CHECKOUT_ORDER_ID,
)

if (
  !STAGING_SUPABASE_URL.includes('localhost') &&
  !STAGING_SUPABASE_URL.includes('127.0.0.1') &&
  !STAGING_SUPABASE_URL.includes('supabase.co')
) {
  fail(
    'STAGING_SUPABASE_URL does not look like a recognized Supabase URL.',
  )
}

/**
 * Safety guard.
 *
 * A staging script should not casually be pointed at an environment explicitly
 * labelled production.
 */
const urlLower = STAGING_SUPABASE_URL.toLowerCase()

if (
  urlLower.includes('production') ||
  urlLower.includes('-prod.') ||
  urlLower.includes('_prod.')
) {
  fail(
    'The supplied Supabase URL appears to be a production environment. Aborting.',
  )
}

const supabase = createClient(
  STAGING_SUPABASE_URL,
  STAGING_SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  },
)

function containsOrderId(row) {
  try {
    return JSON.stringify(row)
      .toLowerCase()
      .includes(STAGING_CHECKOUT_ORDER_ID.toLowerCase())
  } catch {
    return false
  }
}

function getActorCandidates(row) {
  const result = []

  for (const [key, value] of Object.entries(row ?? {})) {
    if (
      value !== null &&
      value !== undefined &&
      value !== '' &&
      /(actor|performed_by|initiated_by|created_by|user_id|user_email|email)/i.test(
        key,
      )
    ) {
      result.push({
        key,
        value: String(value),
      })
    }
  }

  return result
}

function matchesExpectedActor(actorCandidates) {
  if (!STAGING_EXPECTED_ACTOR_ID && !STAGING_EXPECTED_ACTOR_EMAIL) {
    return actorCandidates.length > 0
  }

  const values = actorCandidates.map(({ value }) =>
    value.trim().toLowerCase(),
  )

  if (STAGING_EXPECTED_ACTOR_ID) {
    const expectedId = STAGING_EXPECTED_ACTOR_ID.trim().toLowerCase()

    if (!values.includes(expectedId)) {
      return false
    }
  }

  if (STAGING_EXPECTED_ACTOR_EMAIL) {
    const expectedEmail = STAGING_EXPECTED_ACTOR_EMAIL
      .trim()
      .toLowerCase()

    if (!values.includes(expectedEmail)) {
      return false
    }
  }

  return true
}

function summarizeRow(row) {
  const safe = {}

  const interestingKeys = [
    'id',
    'action',
    'event',
    'event_type',
    'resource_type',
    'resource_id',
    'entity_type',
    'entity_id',
    'table_name',
    'record_id',
    'order_id',
    'actor_id',
    'actor_user_id',
    'actor_email',
    'user_id',
    'created_by',
    'performed_by',
    'movement_type',
    'quantity_delta',
    'quantity_before',
    'quantity_after',
    'created_at',
  ]

  for (const key of interestingKeys) {
    if (
      Object.prototype.hasOwnProperty.call(row, key) &&
      row[key] !== null &&
      row[key] !== undefined
    ) {
      safe[key] = row[key]
    }
  }

  return safe
}

async function readRecentRows(table, limit = 1000) {
  const { data, error } = await supabase
    .from(table)
    .select('*')
    .order('created_at', {
      ascending: false,
      nullsFirst: false,
    })
    .limit(limit)

  if (!error) {
    return data ?? []
  }

  /**
   * Some historical tables may not contain created_at.
   * Fall back to an unordered read rather than failing solely because of that.
   */
  const fallback = await supabase
    .from(table)
    .select('*')
    .limit(limit)

  if (fallback.error) {
    fail(
      `Unable to read staging table "${table}".`,
      fallback.error,
    )
  }

  return fallback.data ?? []
}

async function verifyAuditAttribution() {
  info(
    `Checking ${STAGING_AUDIT_TABLE} for order ${STAGING_CHECKOUT_ORDER_ID}`,
  )

  const rows = await readRecentRows(STAGING_AUDIT_TABLE)

  const orderRows = rows.filter(containsOrderId)

  if (orderRows.length === 0) {
    fail(
      `No audit records referencing order ${STAGING_CHECKOUT_ORDER_ID} were found.`,
      [
        '',
        'Create a fresh staging checkout after the audit-actor migration',
        'has been applied, then rerun this script with that order ID.',
      ].join('\n'),
    )
  }

  info(`Found ${orderRows.length} order-related audit record(s).`)

  const attributed = orderRows
    .map((row) => ({
      row,
      actors: getActorCandidates(row),
    }))
    .filter(({ actors }) => matchesExpectedActor(actors))

  if (attributed.length === 0) {
    console.error('\nOrder-related audit records found:')

    for (const row of orderRows) {
      console.error(JSON.stringify(summarizeRow(row), null, 2))
    }

    fail(
      'Order audit records exist, but no matching trusted actor attribution was found.',
    )
  }

  pass('Generic order audit event contains actor attribution.')

  if (STAGING_EXPECTED_ACTOR_ID) {
    pass(
      `Audit attribution contains expected actor ID ${STAGING_EXPECTED_ACTOR_ID}.`,
    )
  }

  if (STAGING_EXPECTED_ACTOR_EMAIL) {
    pass(
      `Audit attribution contains expected actor email ${STAGING_EXPECTED_ACTOR_EMAIL}.`,
    )
  }

  return attributed
}

async function verifyMovementAttribution() {
  info(
    `Checking ${STAGING_MOVEMENT_TABLE} for checkout movement attribution`,
  )

  const rows = await readRecentRows(STAGING_MOVEMENT_TABLE)

  const orderRows = rows.filter(containsOrderId)

  if (orderRows.length === 0) {
    fail(
      `No inventory movement referencing order ${STAGING_CHECKOUT_ORDER_ID} was found.`,
    )
  }

  info(
    `Found ${orderRows.length} order-related inventory movement record(s).`,
  )

  const attributed = orderRows
    .map((row) => ({
      row,
      actors: getActorCandidates(row),
    }))
    .filter(({ actors }) => actors.length > 0)

  if (attributed.length === 0) {
    console.error('\nOrder-related movement records found:')

    for (const row of orderRows) {
      console.error(JSON.stringify(summarizeRow(row), null, 2))
    }

    fail(
      'Inventory movement exists, but its actor attribution could not be identified.',
    )
  }

  pass('Checkout inventory movement attribution is preserved.')

  return attributed
}

async function verifyNoUnexpectedAnonymousAuditRows() {
  const rows = await readRecentRows(STAGING_AUDIT_TABLE)

  const matching = rows.filter(containsOrderId)

  if (matching.length === 0) {
    return
  }

  const anonymousRows = matching.filter(
    (row) => getActorCandidates(row).length === 0,
  )

  if (anonymousRows.length > 0) {
    console.warn(
      `⚠️  ${anonymousRows.length} order-related audit row(s) contain no obvious actor field.`,
    )

    console.warn(
      'This may be legitimate for system-only events, but should be manually reviewed.',
    )

    for (const row of anonymousRows.slice(0, 5)) {
      console.warn(JSON.stringify(summarizeRow(row), null, 2))
    }

    return
  }

  pass('No unattributed order-related audit rows detected.')
}

async function main() {
  console.log('')
  console.log('DrugXone Checkout Audit Attribution Check')
  console.log('=========================================')
  console.log('')

  info(`Supabase: ${STAGING_SUPABASE_URL}`)
  info(`Order: ${STAGING_CHECKOUT_ORDER_ID}`)
  info(`Audit table: ${STAGING_AUDIT_TABLE}`)
  info(`Movement table: ${STAGING_MOVEMENT_TABLE}`)

  if (!STAGING_EXPECTED_ACTOR_ID && !STAGING_EXPECTED_ACTOR_EMAIL) {
    console.warn('')
    console.warn(
      '⚠️  No expected actor ID/email supplied. The script will verify that',
    )
    console.warn(
      '    actor attribution exists, but it cannot prove the exact expected actor.',
    )
    console.warn('')
  }

  await verifyAuditAttribution()
  await verifyMovementAttribution()
  await verifyNoUnexpectedAnonymousAuditRows()

  console.log('')
  console.log('=========================================')
  console.log('✅ CHECKOUT AUDIT ATTRIBUTION: PASS')
  console.log('=========================================')
  console.log('')

  process.exit(0)
}

main().catch((error) => {
  console.error('')
  console.error('❌ Unexpected staging verification failure:')
  console.error(error)
  process.exit(1)
})