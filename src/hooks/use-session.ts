import { useSyncExternalStore } from "react";
import type { Session, User } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";

export type AppRole = "admin" | "pharmacy" | "wholesaler";
export type BusinessStaffRole = "owner" | "manager" | "cashier" | "assistant";

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
  loading: boolean;
  session: Session | null;
  user: User | null;
  roles: AppRole[];
  business: Business | null;
  businesses: Business[];
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
  unauthorized: boolean;
};

type BusinessMembershipRow = {
  business: Omit<Business, "staff_role"> | null;
  invited_at: string;
  joined_at: string | null;
  role: BusinessStaffRole;
};

const ACTIVE_BUSINESS_STORAGE_KEY = "pharmahub.active_business_id";

const initialState: SessionState = {
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
    assistant: 3,
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

function isUnauthorizedError(error: QueryError | null) {
  if (!error) return false;

  const description =
    `${error.message ?? ""} ${error.details ?? ""} ${error.hint ?? ""}`.toLowerCase();
  return (
    error.status === 401 ||
    error.code === "PGRST301" ||
    description.includes("401") ||
    description.includes("unauthorized") ||
    description.includes("jwt") ||
    description.includes("invalid token") ||
    description.includes("not authenticated")
  );
}

function isSessionExpiring(session: Session) {
  if (!session.expires_at) return false;
  return session.expires_at <= Math.floor(Date.now() / 1000) + 30;
}

async function resolveSession(
  preferredSession: Session | null | undefined,
  forceRefresh = false,
): Promise<Session | null> {
  const currentSession =
    preferredSession ?? (await supabase.auth.getSession()).data.session ?? null;

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
    if (error) {
      return null;
    }

    return data.session;
  })();

  try {
    return await pendingSessionRefresh;
  } finally {
    pendingSessionRefresh = null;
  }
}

async function loadOwnerBusinessFallback(userId: string): Promise<BusinessesQueryResult> {
  const { data, error } = await supabase
    .from("businesses")
    .select(
      "id,type,name,license_number,owner_is_superintendent,superintendent_name,city,region,phone,address,public_email,working_hours,location_description,verification_status,rejection_reason",
    )
    .eq("owner_id", userId)
    .order("created_at", { ascending: false });

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
  const { data, error } = await supabase
    .from("business_staff")
    .select(
      "role, invited_at, joined_at, business:businesses!business_staff_business_id_fkey(id,type,name,license_number,owner_is_superintendent,superintendent_name,city,region,phone,address,public_email,working_hours,location_description,verification_status,rejection_reason)",
    )
    .eq("user_id", userId)
    .eq("status", "active");

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

  if (ownerFallbackResult.error && membershipResult.businesses.length === 0) {
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
  const { data, error } = await supabase.from("user_roles").select("role").eq("user_id", userId);

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

  const unauthorized =
    isUnauthorizedError(rolesResult.error) || isUnauthorizedError(businessesResult.error);

  if (rolesResult.error && !isUnauthorizedError(rolesResult.error)) {
    console.error("Failed to load user roles.", rolesResult.error);
  }

  if (businessesResult.error && !isUnauthorizedError(businessesResult.error)) {
    console.error("Failed to load business contexts.", businessesResult.error);
  }

  return {
    business: chooseActiveBusiness(businessesResult.businesses),
    businesses: businessesResult.businesses,
    roles: rolesResult.roles,
    unauthorized,
  };
}

async function clearBrokenSession(loadId: number) {
  if (loadId !== hydrationSequence) {
    return;
  }

  setSessionState({
    loading: false,
    session: null,
    user: null,
    roles: [],
    business: null,
    businesses: [],
  });

  await supabase.auth.signOut().catch(() => undefined);
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
    business: workspace.business,
    businesses: workspace.businesses,
  });
}

async function hydrateSessionState(
  preferredSession?: Session | null,
  forceRefresh = false,
): Promise<void> {
  const loadId = ++hydrationSequence;
  const resolvedSession = await resolveSession(preferredSession, forceRefresh);

  if (loadId !== hydrationSequence) {
    return;
  }

  if (!resolvedSession?.user) {
    setSessionState({
      loading: false,
      session: null,
      user: null,
      roles: [],
      business: null,
      businesses: [],
    });
    return;
  }

  const workspace = await loadWorkspace(resolvedSession.user.id);

  if (loadId !== hydrationSequence) {
    return;
  }

  if (!workspace.unauthorized) {
    applyLoadedSession(loadId, resolvedSession, workspace);
    return;
  }

  if (forceRefresh) {
    await clearBrokenSession(loadId);
    return;
  }

  const refreshedSession = await resolveSession(resolvedSession, true);

  if (loadId !== hydrationSequence) {
    return;
  }

  if (!refreshedSession?.user) {
    await clearBrokenSession(loadId);
    return;
  }

  const refreshedWorkspace = await loadWorkspace(refreshedSession.user.id);

  if (refreshedWorkspace.unauthorized) {
    await clearBrokenSession(loadId);
    return;
  }

  applyLoadedSession(loadId, refreshedSession, refreshedWorkspace);
}

function initializeSessionStore() {
  if (hasInitializedSessionStore || typeof window === "undefined") {
    return;
  }

  hasInitializedSessionStore = true;

  supabase.auth.onAuthStateChange((_event, session) => {
    if (!session) {
      setSessionState({
        loading: false,
        session: null,
        user: null,
        roles: [],
        business: null,
        businesses: [],
      });
      return;
    }

    setSessionState((current) => ({
      ...current,
      loading: true,
      session,
    }));

    setTimeout(() => {
      void hydrateSessionState(session);
    }, 0);
  });

  void (async () => {
    const { data } = await supabase.auth.getSession();
    if (data.session) {
      setSessionState((current) => ({
        ...current,
        loading: true,
        session: data.session,
      }));
    }

    await hydrateSessionState(data.session);
  })();
}

async function refreshSessionState() {
  setSessionState((current) => ({
    ...current,
    loading: true,
  }));

  await hydrateSessionState(undefined, true);
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
