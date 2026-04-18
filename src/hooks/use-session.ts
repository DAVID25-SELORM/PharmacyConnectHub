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
  city: string | null;
  region: string | null;
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
};

type QueryError = {
  code?: string | null;
  details?: string | null;
  hint?: string | null;
  message?: string | null;
  status?: number | null;
};

type BusinessQueryResult = {
  business: Business | null;
  error: QueryError | null;
};

type RolesQueryResult = {
  error: QueryError | null;
  roles: AppRole[];
};

type WorkspaceQueryResult = {
  business: Business | null;
  roles: AppRole[];
  unauthorized: boolean;
};

const initialState: SessionState = {
  loading: true,
  session: null,
  user: null,
  roles: [],
  business: null,
};

const unavailableRpcNames = new Set<string>();
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

function isMissingRpcError(error: QueryError | null, rpcName: string) {
  if (!error) return false;

  const description = `${error.message ?? ""} ${error.details ?? ""}`.toLowerCase();
  return (
    error.code === "PGRST202" ||
    description.includes("could not find the function") ||
    description.includes("schema cache") ||
    description.includes(rpcName.toLowerCase())
  );
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

async function loadOwnerBusinessFallback(userId: string): Promise<BusinessQueryResult> {
  const { data, error } = await supabase
    .from("businesses")
    .select("id,type,name,license_number,city,region,verification_status,rejection_reason")
    .eq("owner_id", userId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    return {
      business: null,
      error,
    };
  }

  if (!data) {
    return {
      business: null,
      error: null,
    };
  }

  return {
    business: {
      ...(data as Omit<Business, "staff_role">),
      staff_role: "owner",
    },
    error: null,
  };
}

async function loadBusinessContext(userId: string): Promise<BusinessQueryResult> {
  const rpcName = "get_user_business_context";
  const ownerBusiness = await loadOwnerBusinessFallback(userId);

  if (ownerBusiness.error || ownerBusiness.business) {
    return ownerBusiness;
  }

  if (unavailableRpcNames.has(rpcName)) {
    return {
      business: null,
      error: null,
    };
  }

  const { data, error } = await supabase.rpc(rpcName).maybeSingle();

  if (isMissingRpcError(error, rpcName)) {
    unavailableRpcNames.add(rpcName);
    return {
      business: null,
      error: null,
    };
  }

  if (error) {
    return {
      business: null,
      error,
    };
  }

  return {
    business: (data as Business | null) ?? null,
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
  const [rolesResult, businessResult] = await Promise.all([
    loadRoles(userId),
    loadBusinessContext(userId),
  ]);

  const unauthorized =
    isUnauthorizedError(rolesResult.error) || isUnauthorizedError(businessResult.error);

  if (rolesResult.error && !isUnauthorizedError(rolesResult.error)) {
    console.error("Failed to load user roles.", rolesResult.error);
  }

  if (businessResult.error && !isUnauthorizedError(businessResult.error)) {
    console.error("Failed to load business context.", businessResult.error);
  }

  return {
    business: businessResult.business,
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

export function useSession(): SessionState & { refresh: () => Promise<void> } {
  const snapshot = useSyncExternalStore(
    subscribeToSessionState,
    getSessionState,
    () => sessionState,
  );

  return {
    ...snapshot,
    refresh: refreshSessionState,
  };
}
