import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

const staffRoleSchema = z.enum(["manager", "cashier", "assistant"]);
const sessionSchema = z.object({
  accessToken: z.string().min(1, "You must be signed in."),
});

const inviteStaffSchema = sessionSchema.extend({
  businessId: z.string().uuid("Invalid business id."),
  email: z.string().trim().email("Enter a valid email address.").max(255),
  role: staffRoleSchema,
  origin: z.string().url("Invalid app origin.").optional(),
});
const listStaffSchema = sessionSchema.extend({
  businessId: z.string().uuid("Invalid business id."),
});

function sortStaffMembers(left, right) {
  const roleOrder = {
    owner: 0,
    manager: 1,
    cashier: 2,
    assistant: 3,
  };

  const leftRole = roleOrder[left.role] ?? 99;
  const rightRole = roleOrder[right.role] ?? 99;
  if (leftRole !== rightRole) {
    return leftRole - rightRole;
  }

  const leftJoined = left.joined_at ?? left.invited_at;
  const rightJoined = right.joined_at ?? right.invited_at;
  return new Date(rightJoined).getTime() - new Date(leftJoined).getTime();
}

function getSupabaseAdmin() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error(
      "Missing Supabase server environment variables. Ensure SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are set.",
    );
  }

  return createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      storage: undefined,
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}

async function getAuthenticatedUser(accessToken) {
  const supabaseAdmin = getSupabaseAdmin();
  const { data, error } = await supabaseAdmin.auth.getUser(accessToken);

  if (error || !data.user) {
    throw new Error("Your session expired. Please sign in again.");
  }

  return { supabaseAdmin, user: data.user };
}

async function getAuthorizedBusiness(supabaseAdmin, businessId, requesterId) {
  const [{ data: business, error: businessError }, { data: adminRoles, error: rolesError }] =
    await Promise.all([
      supabaseAdmin
        .from("businesses")
        .select("id,name,owner_id,type")
        .eq("id", businessId)
        .maybeSingle(),
      supabaseAdmin.from("user_roles").select("id").eq("user_id", requesterId).eq("role", "admin"),
    ]);

  if (businessError) {
    throw new Error("Failed to verify the selected business.");
  }

  if (!business) {
    throw new Error("Business not found.");
  }

  if (rolesError) {
    throw new Error("Failed to verify your access.");
  }

  const isAdmin = (adminRoles?.length ?? 0) > 0;
  if (business.owner_id !== requesterId && !isAdmin) {
    throw new Error("Only the business owner can add staff.");
  }

  return business;
}

async function getTeamViewableBusiness(supabaseAdmin, businessId, requesterId) {
  const [
    { data: business, error: businessError },
    { data: adminRoles, error: rolesError },
    { data: activeMembership, error: membershipError },
  ] = await Promise.all([
    supabaseAdmin
      .from("businesses")
      .select("id,name,owner_id,type")
      .eq("id", businessId)
      .maybeSingle(),
    supabaseAdmin.from("user_roles").select("id").eq("user_id", requesterId).eq("role", "admin"),
    supabaseAdmin
      .from("business_staff")
      .select("id")
      .eq("business_id", businessId)
      .eq("user_id", requesterId)
      .eq("status", "active")
      .maybeSingle(),
  ]);

  if (businessError) {
    throw new Error("Failed to verify the selected business.");
  }

  if (!business) {
    throw new Error("Business not found.");
  }

  if (rolesError || membershipError) {
    throw new Error("Failed to verify your access.");
  }

  const isAdmin = (adminRoles?.length ?? 0) > 0;
  const isOwner = business.owner_id === requesterId;
  const isActiveStaff = Boolean(activeMembership);

  if (!isOwner && !isAdmin && !isActiveStaff) {
    throw new Error("Not authorized to view this team.");
  }

  return business;
}

async function findAuthUserByEmail(supabaseAdmin, email) {
  let page = 1;

  while (true) {
    const { data, error } = await supabaseAdmin.auth.admin.listUsers({
      page,
      perPage: 1000,
    });

    if (error) {
      throw new Error("Failed to look up that email in Supabase Auth.");
    }

    const matchedUser = data.users.find(
      (user) => user.email?.trim().toLowerCase() === email.toLowerCase(),
    );

    if (matchedUser) {
      return matchedUser;
    }

    if (!data.nextPage || data.users.length === 0) {
      return null;
    }

    page = data.nextPage;
  }
}

async function ensureBusinessRole(supabaseAdmin, userId, businessType) {
  const { error } = await supabaseAdmin.from("user_roles").upsert(
    {
      user_id: userId,
      role: businessType,
    },
    {
      onConflict: "user_id,role",
      ignoreDuplicates: true,
    },
  );

  if (error) {
    throw new Error("Failed to assign the correct workspace role.");
  }
}

async function upsertBusinessStaffMembership({
  businessId,
  invitedBy,
  joinedAt,
  role,
  status,
  supabaseAdmin,
  userId,
}) {
  const now = new Date().toISOString();
  const { error } = await supabaseAdmin.from("business_staff").upsert(
    {
      business_id: businessId,
      user_id: userId,
      role,
      status,
      invited_by: invitedBy,
      invited_at: now,
      joined_at: joinedAt,
    },
    {
      onConflict: "business_id,user_id",
    },
  );

  if (error) {
    throw new Error("Failed to save the staff membership.");
  }
}

function getInviteOrigin(origin, fallbackOrigin) {
  if (origin) {
    return origin;
  }

  if (fallbackOrigin) {
    return fallbackOrigin;
  }

  throw new Error("Failed to determine the invite link origin.");
}

async function inviteNewAuthUser({
  businessId,
  businessName,
  businessType,
  email,
  origin,
  role,
  supabaseAdmin,
}) {
  const redirectTo = new URL("/reset-password", origin).toString();
  const { data, error } = await supabaseAdmin.auth.admin.inviteUserByEmail(email, {
    redirectTo,
    data: {
      role: businessType,
      invited_business_id: businessId,
      invited_business_name: businessName,
      invited_staff_role: role,
    },
  });

  if (error || !data.user) {
    throw new Error(error?.message ?? "Failed to send the invitation email.");
  }

  return data.user;
}

function getJoinedAtForExistingUser(user, currentJoinedAt) {
  if (currentJoinedAt) {
    return currentJoinedAt;
  }

  return user.last_sign_in_at ? new Date().toISOString() : null;
}

export async function inviteBusinessStaff(input, fallbackOrigin) {
  const data = inviteStaffSchema.parse(input);
  const normalizedEmail = data.email.trim().toLowerCase();
  const { supabaseAdmin, user } = await getAuthenticatedUser(data.accessToken);
  const business = await getAuthorizedBusiness(supabaseAdmin, data.businessId, user.id);
  const existingAuthUser = await findAuthUserByEmail(supabaseAdmin, normalizedEmail);

  if (existingAuthUser?.id === business.owner_id) {
    throw new Error("That email belongs to the business owner, who already has full access.");
  }

  if (existingAuthUser) {
    const { data: existingMembership, error: membershipError } = await supabaseAdmin
      .from("business_staff")
      .select("joined_at")
      .eq("business_id", business.id)
      .eq("user_id", existingAuthUser.id)
      .maybeSingle();

    if (membershipError) {
      throw new Error("Failed to check the existing team membership.");
    }

    await ensureBusinessRole(supabaseAdmin, existingAuthUser.id, business.type);
    await upsertBusinessStaffMembership({
      supabaseAdmin,
      businessId: business.id,
      userId: existingAuthUser.id,
      role: data.role,
      status: "active",
      invitedBy: user.id,
      joinedAt: getJoinedAtForExistingUser(existingAuthUser, existingMembership?.joined_at ?? null),
    });

    return {
      mode: "existing-account",
    };
  }

  const invitedUser = await inviteNewAuthUser({
    supabaseAdmin,
    businessId: business.id,
    businessName: business.name,
    businessType: business.type,
    email: normalizedEmail,
    role: data.role,
    origin: getInviteOrigin(data.origin, fallbackOrigin),
  });

  await ensureBusinessRole(supabaseAdmin, invitedUser.id, business.type);
  await upsertBusinessStaffMembership({
    supabaseAdmin,
    businessId: business.id,
    userId: invitedUser.id,
    role: data.role,
    status: "pending",
    invitedBy: user.id,
    joinedAt: null,
  });

  return {
    mode: "invite-sent",
  };
}

export async function listBusinessStaff(input) {
  const data = listStaffSchema.parse(input);
  const { supabaseAdmin, user } = await getAuthenticatedUser(data.accessToken);
  await getTeamViewableBusiness(supabaseAdmin, data.businessId, user.id);

  const { data: staffRows, error: staffError } = await supabaseAdmin
    .from("business_staff")
    .select("id,user_id,role,status,invited_at,joined_at")
    .eq("business_id", data.businessId);

  if (staffError) {
    throw new Error("Failed to load the team members.");
  }

  const userIds = [...new Set((staffRows ?? []).map((staffMember) => staffMember.user_id))];
  const [{ data: profiles, error: profilesError }, emailEntries] = await Promise.all([
    userIds.length === 0
      ? Promise.resolve({ data: [], error: null })
      : supabaseAdmin.from("profiles").select("id,full_name,phone").in("id", userIds),
    Promise.all(
      userIds.map(async (userId) => {
        const { data: authData, error } = await supabaseAdmin.auth.admin.getUserById(userId);
        if (error) {
          return [userId, null];
        }

        return [userId, authData.user?.email ?? null];
      }),
    ),
  ]);

  if (profilesError) {
    throw new Error("Failed to load the staff profiles.");
  }

  const profilesById = new Map((profiles ?? []).map((profile) => [profile.id, profile]));
  const emailsById = new Map(emailEntries);

  return (staffRows ?? [])
    .map((staffMember) => {
      const profile = profilesById.get(staffMember.user_id);
      return {
        ...staffMember,
        full_name: profile?.full_name ?? null,
        phone: profile?.phone ?? null,
        user_email: emailsById.get(staffMember.user_id) ?? null,
      };
    })
    .sort(sortStaffMembers);
}

export async function markStaffMembershipJoined(input) {
  const data = sessionSchema.parse(input);
  const { supabaseAdmin, user } = await getAuthenticatedUser(data.accessToken);
  const joinedAt = new Date().toISOString();
  const { error } = await supabaseAdmin
    .from("business_staff")
    .update({ status: "active", joined_at: joinedAt })
    .eq("user_id", user.id)
    .in("status", ["active", "pending"])
    .is("joined_at", null);

  if (error) {
    throw new Error("Failed to finish setting up your staff access.");
  }

  return { ok: true };
}
