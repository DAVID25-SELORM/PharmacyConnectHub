import { authDiagnostic, withAuthTimeout } from "@/lib/auth-diagnostics";
import { useSyncExternalStore } from "react";
import type { Session, User } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";

export type AppRole = "admin" | "pharmacy" | "wholesaler";
export type BusinessStaffRole =
  "owner" | "manager" | "cashier" | "assistant" | "warehouse" | "finance" | "accountant";

export type Business = {
  id: string;
  type: "pharmacy" | "wholesaler";
  name: string;
  license_number: string | null;
  owner_is_superintendent: boolean;
  superintendent_name: string | null;
  city: string | null;
  region: string | null;
  phone: string | null;
  address: string | null;
  public_email: string | null;
  working_hours: string | null;
  location_description: string | null;
  verification_status: "pending" | "approved" | "rejected";
  rejection_reason: string | null;
  staff_role: BusinessStaffRole;
};

export type SessionState = {
  authStatus?: "loading" | "authenticated" | "unauthenticated" | "recoverable-error";
  authorizationStatus?: "loading" | "authorized" | "unauthorized" | "recoverable-error";
  loading: boolean;
  session: Session | null;
  user: User | null;
  roles: AppRole[];
  business: Business | null;
  businesses: Business[];
  /** True when roles/business memberships could not be resolved. Callers must fail closed. */
  loadError?: boolean;
};

type QueryError = {
  code?: string | null;
  details?: string | null;
  hint?: string | null;
  message?: string | null;
  status?: number | null;
};

type BusinessesQueryResult = {
  businesses: Business[];
  error: QueryError | null;
};

type RolesQueryResult = {
  error: QueryError | null;
  roles: AppRole[];
};

type WorkspaceQueryResult = {
  business: Business | null;
  businesses: Business[];
  roles: AppRole[];
  failed: boolean;
};

type BusinessMembershipRow = {
  business: Omit<Business, "staff_role"> | null;
  invited_at: string;
  joined_at: string | null;
  role: BusinessStaffRole;
};

const ACTIVE_BUSINESS_STORAGE_KEY = "pharmahub.active_business_id";

const initialState: SessionState = {
  authStatus: "loading",
  authorizationStatus: "loading",
  loading: true,
  session: null,
  user: null,
  roles: [],
  business: null,
  businesses: [],
};

const listeners = new Set<() => void>();

let sessionState: SessionState = initialState;
let hasInitializedSessionStore = false;
let hydrationSequence = 0;
let pendingSessionRefresh: Promise<Session | null> | null = null;

function emitSessionState() {
  for (const listener of listeners) {
    listener();
  }
}

function setSessionState(next: SessionState | ((current: SessionState) => SessionState)) {
  sessionState = typeof next === "function" ? next(sessionState) : next;
  sessionState.authStatus = sessionState.session
    ? "authenticated"
    : sessionState.loading
      ? "loading"
      : sessionState.loadError
        ? "recoverable-error"
        : "unauthenticated";
  sessionState.authorizationStatus = sessionState.loading
    ? "loading"
    : sessionState.loadError
      ? "recoverable-error"
      : sessionState.business?.verification_status === "approved" ||
          sessionState.roles.includes("admin")
        ? "authorized"
        : "unauthorized";
  emitSessionState();
}

function getSessionState() {
  return sessionState;
}

function subscribeToSessionState(listener: () => void) {
  initializeSessionStore();
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function readStoredBusinessId() {
  if (typeof window === "undefined") {
    return null;
  }

  try {
    return window.localStorage.getItem(ACTIVE_BUSINESS_STORAGE_KEY);
  } catch {
    return null;
  }
}

function writeStoredBusinessId(businessId: string | null) {
  if (typeof window === "undefined") {
    return;
  }

  try {
    if (businessId) {
      window.localStorage.setItem(ACTIVE_BUSINESS_STORAGE_KEY, businessId);
    } else {
      window.localStorage.removeItem(ACTIVE_BUSINESS_STORAGE_KEY);
    }
  } catch {
    // Ignore storage failures and keep the session usable.
  }
}

function sortBusinesses(left: Business, right: Business) {
  const roleOrder: Record<BusinessStaffRole, number> = {
    owner: 0,
    manager: 1,
    cashier: 2,
    warehouse: 3,
    finance: 4,
    accountant: 5,
    assistant: 6,
  };

  const leftRole = roleOrder[left.staff_role] ?? 99;
  const rightRole = roleOrder[right.staff_role] ?? 99;
  if (leftRole !== rightRole) {
    return leftRole - rightRole;
  }

  if (left.type !== right.type) {
    return left.type.localeCompare(right.type);
  }

  return left.name.localeCompare(right.name);
}

function chooseActiveBusiness(businesses: Business[]) {
  if (businesses.length === 0) {
    writeStoredBusinessId(null);
    return null;
  }

  const storedBusinessId = readStoredBusinessId();
  if (storedBusinessId) {
    const storedBusiness = businesses.find((business) => business.id === storedBusinessId);
    if (storedBusiness) {
      return storedBusiness;
    }
  }

  if (businesses.length === 1) {
    writeStoredBusinessId(businesses[0].id);
    return businesses[0];
  }

  writeStoredBusinessId(null);
  return null;
}

function isSessionExpiring(session: Session) {
  if (!session.expires_at) return false;
  return session.expires_at <= Math.floor(Date.now() / 1000) + 30;
}

class SessionRefreshError {
  constructor(
    readonly session: Session,
    readonly cause: unknown,
  ) {}
}

async function resolveSession(
  preferredSession: Session | null | undefined,
  forceRefresh = false,
): Promise<Session | null> {
  const currentSession =
    preferredSession !== undefined
      ? preferredSession
      : await (async () => {
          const { data, error } = await supabase.auth.getSession();
          authDiagnostic("session.restore", error, { hasSession: Boolean(data.session) });
          if (error) throw error;
          return data.session;
        })();

  if (!currentSession) {
    return null;
  }

  if (!forceRefresh && !isSessionExpiring(currentSession)) {
    return currentSession;
  }

  if (pendingSessionRefresh) {
    return pendingSessionRefresh;
  }

  pendingSessionRefresh = (async () => {
    const { data, error } = await supabase.auth.refreshSession();
    authDiagnostic("session.refresh", error, { hasSession: Boolean(data.session) });
    if (error) throw error;
    if (!data.session) throw { code: "refresh_session_missing" };
    return data.session;
  })();

  try {
    return await pendingSessionRefresh;
  } catch (error) {
    throw new SessionRefreshError(currentSession, error);
  } finally {
    pendingSessionRefresh = null;
  }
}

async function loadOwnerBusinessFallback(userId: string): Promise<BusinessesQueryResult> {
  const { data, error, status } = await supabase
    .from("businesses")
    .select(
      "id,type,name,license_number,owner_is_superintendent,superintendent_name,city,region,phone,address,public_email,working_hours,location_description,verification_status,rejection_reason",
    )
    .eq("owner_id", userId)
    .order("created_at", { ascending: false });

  authDiagnostic("workspace.owner_lookup", error ? { ...error, status } : undefined, {
    count: data?.length ?? 0,
  });
  if (error) {
    return {
      businesses: [],
      error,
    };
  }

  if (!data || data.length === 0) {
    return {
      businesses: [],
      error: null,
    };
  }

  return {
    businesses: (data as Omit<Business, "staff_role">[]).map((business) => ({
      ...business,
      staff_role: "owner",
    })),
    error: null,
  };
}

async function loadBusinessMemberships(userId: string): Promise<BusinessesQueryResult> {
  const { data, error, status } = await supabase
    .from("business_staff")
    .select(
      "role, invited_at, joined_at, business:businesses!business_staff_business_id_fkey(id,type,name,license_number,owner_is_superintendent,superintendent_name,city,region,phone,address,public_email,working_hours,location_description,verification_status,rejection_reason)",
    )
    .eq("user_id", userId)
    .eq("status", "active");

  authDiagnostic("workspace.memberships", error ? { ...error, status } : undefined, {
    count: data?.length ?? 0,
  });
  if (error) {
    return {
      businesses: [],
      error,
    };
  }

  const businesses = ((data ?? []) as BusinessMembershipRow[])
    .flatMap((membership) =>
      membership.business
        ? [
            {
              ...membership.business,
              staff_role: membership.role,
            },
          ]
        : [],
    )
    .sort(sortBusinesses);

  return {
    businesses,
    error: null,
  };
}

async function loadBusinessContexts(userId: string): Promise<BusinessesQueryResult> {
  const [membershipResult, ownerFallbackResult] = await Promise.all([
    loadBusinessMemberships(userId),
    loadOwnerBusinessFallback(userId),
  ]);

  if (membershipResult.error) {
    return membershipResult;
  }

  if (ownerFallbackResult.error) {
    return ownerFallbackResult;
  }

  const merged = new Map<string, Business>();

  for (const business of membershipResult.businesses) {
    merged.set(business.id, business);
  }

  for (const business of ownerFallbackResult.businesses) {
    if (!merged.has(business.id)) {
      merged.set(business.id, business);
    }
  }

  return {
    businesses: Array.from(merged.values()).sort(sortBusinesses),
    error: null,
  };
}

async function loadRoles(userId: string): Promise<RolesQueryResult> {
  const { data, error, status } = await supabase
    .from("user_roles")
    .select("role")
    .eq("user_id", userId);

  authDiagnostic("workspace.roles", error ? { ...error, status } : undefined, {
    count: data?.length ?? 0,
  });
  return {
    error,
    roles: (data ?? []).map((row) => row.role as AppRole),
  };
}

async function loadWorkspace(userId: string): Promise<WorkspaceQueryResult> {
  const [rolesResult, businessesResult] = await Promise.all([
    loadRoles(userId),
    loadBusinessContexts(userId),
  ]);

  return {
    business: null,
    businesses: businessesResult.businesses,
    roles: rolesResult.roles,
    failed: Boolean(rolesResult.error || businessesResult.error),
  };
}

function applyLoadedSession(loadId: number, session: Session, workspace: WorkspaceQueryResult) {
  if (loadId !== hydrationSequence) {
    return;
  }

  setSessionState({
    loading: false,
    session,
    user: session.user,
    roles: workspace.roles,
    business: workspace.failed ? null : chooseActiveBusiness(workspace.businesses),
    businesses: workspace.businesses,
    loadError: workspace.failed,
  });
}

async function hydrateSessionState(
  preferredSession?: Session | null,
  forceRefresh = false,
): Promise<void> {
  const loadId = ++hydrationSequence;
  let resolvedSession = preferredSession ?? sessionState.session;
  try {
    resolvedSession = await withAuthTimeout(resolveSession(preferredSession, forceRefresh));
    if (loadId !== hydrationSequence) return;
    authDiagnostic("session.established", undefined, { hasSession: Boolean(resolvedSession) });
    if (!resolvedSession?.user) {
      setSessionState({ ...initialState, loading: false });
      return;
    }
    // Authentication is established independently of authorization lookup success.
    setSessionState((current) => ({
      ...(current.user?.id === resolvedSession!.user.id ? current : initialState),
      loading: true,
      session: resolvedSession,
      user: resolvedSession!.user,
    }));
    const workspace = await withAuthTimeout(loadWorkspace(resolvedSession.user.id));
    applyLoadedSession(loadId, resolvedSession, workspace);
  } catch (error) {
    if (loadId !== hydrationSequence) return;
    if (error instanceof SessionRefreshError) resolvedSession = error.session;
    authDiagnostic(
      "session.recoverable_error",
      error instanceof SessionRefreshError ? error.cause : error,
      { hasSession: Boolean(resolvedSession) },
    );
    setSessionState({
      ...initialState,
      loading: false,
      session: resolvedSession,
      user: resolvedSession?.user ?? null,
      loadError: true,
    });
  }
}

function initializeSessionStore() {
  if (hasInitializedSessionStore || typeof window === "undefined") return;
  hasInitializedSessionStore = true;
  supabase.auth.onAuthStateChange((event, session) => {
    const eventSequence = ++hydrationSequence;
    authDiagnostic(`auth.event.${event}`, undefined, { hasSession: Boolean(session) });
    if (!session) {
      setSessionState({ ...initialState, loading: false });
      return;
    }
    setSessionState((current) => ({
      ...(current.user?.id === session.user.id ? current : initialState),
      loading: true,
      session,
      user: session.user,
    }));
    // Leave the Supabase auth callback before issuing database requests.
    setTimeout(() => {
      if (eventSequence === hydrationSequence) void hydrateSessionState(session);
    }, 0);
  });
  void hydrateSessionState();
}

async function refreshSessionState() {
  setSessionState((current) => ({ ...current, loading: true }));
  // Retry authorization without needlessly rotating a healthy session's refresh token.
  await hydrateSessionState();
}

function setActiveBusinessSelection(businessId: string | null) {
  writeStoredBusinessId(businessId);

  setSessionState((current) => ({
    ...current,
    business: businessId
      ? (current.businesses.find((business) => business.id === businessId) ?? null)
      : chooseActiveBusiness(current.businesses),
  }));
}

export function useSession(): SessionState & {
  refresh: () => Promise<void>;
  setActiveBusiness: (businessId: string | null) => void;
} {
  const snapshot = useSyncExternalStore(
    subscribeToSessionState,
    getSessionState,
    () => sessionState,
  );

  return {
    ...snapshot,
    refresh: refreshSessionState,
    setActiveBusiness: setActiveBusinessSelection,
  };
}
