import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useEffectEvent, useMemo, useState } from "react";
import { ArrowLeft, Loader2, Pencil, ShieldCheck, Trash2, UserPlus } from "lucide-react";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useSession } from "@/hooks/use-session";
import {
  invitePlatformStaff,
  listPlatformStaff,
  resendPlatformStaffInvite,
  updatePlatformStaffMember,
  type PlatformStaffMember,
  type PlatformStaffRole,
  type PlatformStaffStatus,
} from "@/lib/platform-staff-actions";
import { inviteBusinessStaff, type ManageableStaffRole } from "@/lib/staff-actions";
import { timeAgo } from "@/lib/format";
import { shouldShowPrivateTeamGuidance } from "@/lib/private-team-guidance";

export const Route = createFileRoute("/admin/staff")({
  head: () => ({
    meta: [{ title: "Platform Team - PharmaHub GH" }],
  }),
  component: PlatformStaffManagement,
});

type InviteTarget =
  | { kind: "platform"; label: string; value: "platform" }
  | { kind: "business"; label: string; value: `business:${string}`; businessId: string };

type PlatformStaffEditForm = {
  fullName: string;
  email: string;
  phone: string;
  role: PlatformStaffRole;
  status: PlatformStaffStatus;
};

const roleLabels: Record<PlatformStaffRole, string> = {
  owner: "Platform Owner",
  admin: "Platform Admin",
};

const roleColors: Record<PlatformStaffRole, string> = {
  owner: "bg-purple-100 text-purple-800",
  admin: "bg-blue-100 text-blue-800",
};

const statusLabels: Record<PlatformStaffStatus, string> = {
  active: "Active",
  inactive: "Inactive",
  pending: "Pending",
};

const statusColors: Record<PlatformStaffStatus, string> = {
  active: "bg-green-100 text-green-800",
  inactive: "bg-slate-100 text-slate-700",
  pending: "bg-amber-100 text-amber-800",
};

const emptyEditForm: PlatformStaffEditForm = {
  fullName: "",
  email: "",
  phone: "",
  role: "admin",
  status: "active",
};

function createEditForm(member: PlatformStaffMember): PlatformStaffEditForm {
  return {
    fullName: member.full_name ?? "",
    email: member.user_email ?? "",
    phone: member.phone ?? "",
    role: member.role,
    status: member.status,
  };
}

function getEditableStatuses(member: PlatformStaffMember): PlatformStaffStatus[] {
  if (member.role === "owner") {
    return ["active"];
  }

  if (member.status === "pending") {
    return ["pending", "active", "inactive"];
  }

  if (member.status === "inactive") {
    return ["inactive", "active"];
  }

  return ["active", "inactive"];
}

function PlatformStaffManagement() {
  const navigate = useNavigate();
  const { loading, user, roles, businesses, setActiveBusiness } = useSession();
  const [staff, setStaff] = useState<PlatformStaffMember[]>([]);
  const [loadingStaff, setLoadingStaff] = useState(true);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState<ManageableStaffRole>("assistant");
  const [inviteTarget, setInviteTarget] = useState<InviteTarget["value"]>("platform");
  const [inviting, setInviting] = useState(false);
  const [resendingStaffId, setResendingStaffId] = useState<string | null>(null);
  const [editingMember, setEditingMember] = useState<PlatformStaffMember | null>(null);
  const [editForm, setEditForm] = useState<PlatformStaffEditForm>(emptyEditForm);
  const [savingEdit, setSavingEdit] = useState(false);

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (!roles.includes("admin")) {
      navigate({ to: "/dashboard" });
    }
  }, [loading, user, roles, navigate]);

  const inviteTargets = useMemo<InviteTarget[]>(() => {
    const businessTargets = businesses.map((workspace) => ({
      kind: "business" as const,
      label: `${workspace.name} workspace`,
      value: `business:${workspace.id}` as const,
      businessId: workspace.id,
    }));

    return [{ kind: "platform", label: "PharmaHub Admin", value: "platform" }, ...businessTargets];
  }, [businesses]);

  useEffect(() => {
    if (!inviteTargets.some((target) => target.value === inviteTarget)) {
      setInviteTarget("platform");
    }
  }, [inviteTarget, inviteTargets]);

  const selectedInviteTarget =
    inviteTargets.find((target) => target.value === inviteTarget) ?? inviteTargets[0];
  const invitingToBusiness = selectedInviteTarget?.kind === "business";
  const canManageTeam = roles.includes("admin");
  const showPrivateTeamGuidance = shouldShowPrivateTeamGuidance(user?.email);
  const viewerIsPlatformOwner = useMemo(() => {
    if (!user) {
      return false;
    }

    return staff.some(
      (member) =>
        member.user_id === user.id && member.role === "owner" && member.status === "active",
    );
  }, [staff, user]);
  const visibleStaff = useMemo(
    () => (viewerIsPlatformOwner ? staff : staff.filter((member) => member.role !== "owner")),
    [staff, viewerIsPlatformOwner],
  );

  const loadStaff = useEffectEvent(async () => {
    setLoadingStaff(true);
    try {
      setStaff(await listPlatformStaff());
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to load platform staff";
      toast.error(message);
    } finally {
      setLoadingStaff(false);
    }
  });

  useEffect(() => {
    if (roles.includes("admin")) {
      void loadStaff();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roles]);

  const handleInvite = async () => {
    if (!selectedInviteTarget || !inviteEmail.trim()) return;
    if (!canManageTeam) {
      toast.error("Only platform admins can add platform staff.");
      return;
    }

    setInviting(true);
    try {
      if (selectedInviteTarget.kind === "platform") {
        const result = await invitePlatformStaff({
          email: inviteEmail.trim().toLowerCase(),
        });
        toast.success(
          result.mode === "invited"
            ? "Platform access email sent. They can finish setup from the admin side."
            : "Platform admin added successfully.",
        );
        void loadStaff();
      } else {
        const result = await inviteBusinessStaff({
          businessId: selectedInviteTarget.businessId,
          email: inviteEmail.trim().toLowerCase(),
          role: inviteRole,
        });
        toast.success(
          result.mode === "invited"
            ? `Business invite sent for ${selectedInviteTarget.label}.`
            : `Business staff added to ${selectedInviteTarget.label}.`,
        );
        setActiveBusiness(selectedInviteTarget.businessId);
        navigate({ to: "/staff" });
      }

      setInviteOpen(false);
      setInviteEmail("");
      setInviteRole("assistant");
      setInviteTarget("platform");
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to add staff";
      toast.error(message);
    } finally {
      setInviting(false);
    }
  };

  const saveStaffChanges = async (
    member: PlatformStaffMember,
    overrides: Partial<PlatformStaffEditForm>,
  ): Promise<void> => {
    const email = (overrides.email ?? member.user_email ?? "").trim().toLowerCase();
    if (!email) {
      throw new Error("Staff email is required.");
    }

    await updatePlatformStaffMember({
      staffId: member.id,
      fullName: overrides.fullName ?? member.full_name ?? "",
      email,
      phone: overrides.phone ?? member.phone ?? "",
      role: overrides.role ?? member.role,
      status: overrides.status ?? member.status,
    });
  };

  const openEditDialog = (member: PlatformStaffMember) => {
    if (member.role === "owner" && !viewerIsPlatformOwner) {
      toast.error("Only the platform owner can view or edit owner details.");
      return;
    }

    setEditingMember(member);
    setEditForm(createEditForm(member));
  };

  const closeEditDialog = (open: boolean) => {
    if (open) {
      return;
    }

    setEditingMember(null);
    setEditForm(emptyEditForm);
    setSavingEdit(false);
  };

  const handleSaveEdit = async () => {
    if (!editingMember) return;

    if (editingMember.role === "owner" && !viewerIsPlatformOwner) {
      toast.error("Only the platform owner can edit owner details.");
      return;
    }

    setSavingEdit(true);
    try {
      await saveStaffChanges(editingMember, editForm);
      toast.success("Platform staff details updated.");
      closeEditDialog(false);
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to update platform staff";
      toast.error(message);
      setSavingEdit(false);
    }
  };

  const handleDeactivate = async (member: PlatformStaffMember) => {
    try {
      await saveStaffChanges(member, { status: "inactive" });
      toast.success(
        member.status === "pending" ? "Invite cancelled." : "Platform admin deactivated.",
      );
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to update platform staff";
      toast.error(message);
    }
  };

  const handleActivate = async (member: PlatformStaffMember) => {
    try {
      await saveStaffChanges(member, { status: "active" });
      toast.success(
        member.status === "inactive" ? "Platform admin reactivated." : "Platform admin activated.",
      );
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to update platform staff";
      toast.error(message);
    }
  };

  const handleResendInvite = async (member: PlatformStaffMember) => {
    if (member.role === "owner" && !viewerIsPlatformOwner) {
      toast.error("Only the platform owner can manage owner access.");
      return;
    }

    if (member.status === "inactive") {
      toast.error("Reactivate this platform staff member before sending an access email.");
      return;
    }

    setResendingStaffId(member.id);
    try {
      await resendPlatformStaffInvite({ staffId: member.id });
      toast.success(
        member.user_email
          ? member.status === "pending"
            ? `Platform invite resent to ${member.user_email}.`
            : `Reset email sent to ${member.user_email}.`
          : member.status === "pending"
            ? "Platform invite resent successfully."
            : "Reset email sent successfully.",
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to resend access email";
      toast.error(message);
    } finally {
      setResendingStaffId(null);
    }
  };

  if (loading || !user || !roles.includes("admin")) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  const activeStaff = visibleStaff.filter((member) => member.status === "active");
  const otherStaff = visibleStaff.filter((member) => member.status !== "active");
  const editableStatuses: PlatformStaffStatus[] = editingMember
    ? getEditableStatuses(editingMember)
    : ["active"];

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Platform team" isAdmin={true} />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="flex items-center gap-2 font-display text-3xl font-bold">
              <ShieldCheck className="h-8 w-8" />
              Platform Team
            </h1>
            <p className="mt-1 text-muted-foreground">
              Manage who can access the PharmaHub Admin interface.
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => navigate({ to: "/admin" })}>
              <ArrowLeft className="mr-2 h-4 w-4" />
              Back to admin
            </Button>
            {canManageTeam && (
              <Button onClick={() => setInviteOpen(true)}>
                <UserPlus className="mr-2 h-4 w-4" />
                Add Staff
              </Button>
            )}
          </div>
        </div>

        {showPrivateTeamGuidance && (
          <Card className="mt-6 border-dashed p-4 text-sm text-muted-foreground">
            Platform staff stay on the admin side. Use the interface dropdown when inviting if you
            want to send someone into a business workspace instead.
          </Card>
        )}

        <div className="mt-8 grid gap-6">
          <Card className="p-6">
            <h2 className="mb-4 text-lg font-semibold">Active Members ({activeStaff.length})</h2>
            {loadingStaff ? (
              <div className="flex items-center justify-center py-12">
                <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
              </div>
            ) : activeStaff.length === 0 ? (
              <p className="py-12 text-center text-muted-foreground">
                No active platform staff yet.
              </p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Name</TableHead>
                    <TableHead>Email</TableHead>
                    <TableHead>Phone</TableHead>
                    <TableHead>Role</TableHead>
                    <TableHead>Joined</TableHead>
                    <TableHead>Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {activeStaff.map((member) => (
                    <TableRow key={member.id}>
                      <TableCell className="font-medium">{member.full_name || "-"}</TableCell>
                      <TableCell>{member.user_email || "-"}</TableCell>
                      <TableCell>{member.phone || "-"}</TableCell>
                      <TableCell>
                        <Badge className={roleColors[member.role]}>{roleLabels[member.role]}</Badge>
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {member.joined_at ? timeAgo(member.joined_at) : "Not recorded"}
                      </TableCell>
                      <TableCell>
                        <div className="flex flex-wrap gap-2">
                          {member.user_email && (
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => handleResendInvite(member)}
                              disabled={resendingStaffId === member.id}
                            >
                              {resendingStaffId === member.id ? "Sending..." : "Resend email"}
                            </Button>
                          )}
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => openEditDialog(member)}
                          >
                            <Pencil className="h-4 w-4" />
                            Edit
                          </Button>
                          {member.role !== "owner" && (
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() => handleDeactivate(member)}
                            >
                              <Trash2 className="h-4 w-4" />
                              Deactivate
                            </Button>
                          )}
                        </div>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </Card>

          {otherStaff.length > 0 && (
            <Card className="p-6">
              <h2 className="mb-4 text-lg font-semibold">
                Other Access Records ({otherStaff.length})
              </h2>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Name</TableHead>
                    <TableHead>Email</TableHead>
                    <TableHead>Phone</TableHead>
                    <TableHead>Role</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead>Added</TableHead>
                    <TableHead>Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {otherStaff.map((member) => (
                    <TableRow key={member.id}>
                      <TableCell className="font-medium">{member.full_name || "-"}</TableCell>
                      <TableCell>{member.user_email || "-"}</TableCell>
                      <TableCell>{member.phone || "-"}</TableCell>
                      <TableCell>
                        <Badge className={roleColors[member.role]}>{roleLabels[member.role]}</Badge>
                      </TableCell>
                      <TableCell>
                        <Badge className={statusColors[member.status]}>
                          {statusLabels[member.status]}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {timeAgo(member.invited_at)}
                      </TableCell>
                      <TableCell>
                        <div className="flex flex-wrap gap-2">
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => openEditDialog(member)}
                          >
                            <Pencil className="h-4 w-4" />
                            Edit
                          </Button>
                          {member.status !== "inactive" && member.user_email && (
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => handleResendInvite(member)}
                              disabled={resendingStaffId === member.id}
                            >
                              {resendingStaffId === member.id ? "Sending..." : "Resend email"}
                            </Button>
                          )}
                          {member.status === "pending" && (
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => handleActivate(member)}
                            >
                              Activate
                            </Button>
                          )}
                          {member.status === "inactive" && (
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => handleActivate(member)}
                            >
                              Reactivate
                            </Button>
                          )}
                          {member.status !== "inactive" && member.role !== "owner" && (
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() => handleDeactivate(member)}
                            >
                              Cancel
                            </Button>
                          )}
                        </div>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Card>
          )}
        </div>

        <Dialog open={Boolean(editingMember)} onOpenChange={closeEditDialog}>
          <DialogContent className="sm:max-w-lg">
            <DialogHeader>
              <DialogTitle>Edit Platform Staff</DialogTitle>
              <DialogDescription>
                {editingMember?.status === "pending"
                  ? "Update this pending invite before resending the access email."
                  : "Update the member's contact details and admin access."}
              </DialogDescription>
            </DialogHeader>
            {editingMember && (
              <>
                <div className="grid gap-4 py-4">
                  <div className="grid gap-4 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label htmlFor="edit-full-name">Full Name</Label>
                      <Input
                        id="edit-full-name"
                        placeholder="Jane Doe"
                        value={editForm.fullName}
                        onChange={(event) =>
                          setEditForm((current) => ({ ...current, fullName: event.target.value }))
                        }
                      />
                    </div>
                    <div className="space-y-2">
                      <Label htmlFor="edit-phone">Phone</Label>
                      <Input
                        id="edit-phone"
                        type="tel"
                        placeholder="+233..."
                        value={editForm.phone}
                        onChange={(event) =>
                          setEditForm((current) => ({ ...current, phone: event.target.value }))
                        }
                      />
                    </div>
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="edit-email">Email Address</Label>
                    <Input
                      id="edit-email"
                      type="email"
                      placeholder="admin@example.com"
                      value={editForm.email}
                      onChange={(event) =>
                        setEditForm((current) => ({ ...current, email: event.target.value }))
                      }
                    />
                  </div>

                  <div className="grid gap-4 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label>Role</Label>
                      <div className="space-y-2 rounded-md border p-3">
                        <Badge className={roleColors[editingMember.role]}>
                          {roleLabels[editingMember.role]}
                        </Badge>
                        <p className="text-xs text-muted-foreground">
                          {editingMember.role === "owner"
                            ? "The platform owner keeps full admin control."
                            : "Platform staff use the admin interface only."}
                        </p>
                      </div>
                    </div>

                    <div className="space-y-2">
                      <Label htmlFor="edit-status">Status</Label>
                      {editingMember.role === "owner" ? (
                        <div className="space-y-2 rounded-md border p-3">
                          <Badge className={statusColors.active}>{statusLabels.active}</Badge>
                          <p className="text-xs text-muted-foreground">
                            The platform owner must stay active.
                          </p>
                        </div>
                      ) : (
                        <Select
                          value={editForm.status}
                          onValueChange={(value) =>
                            setEditForm((current) => ({
                              ...current,
                              status: value as PlatformStaffStatus,
                            }))
                          }
                        >
                          <SelectTrigger id="edit-status">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {editableStatuses.map((status) => (
                              <SelectItem key={status} value={status}>
                                {statusLabels[status]}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    </div>
                  </div>

                  {editingMember.status === "pending" && (
                    <p className="text-xs text-muted-foreground">
                      Save any email changes first, then use the Resend email action in the table to
                      send a fresh platform invite.
                    </p>
                  )}
                </div>
                <DialogFooter>
                  <Button
                    variant="outline"
                    onClick={() => closeEditDialog(false)}
                    disabled={savingEdit}
                  >
                    Cancel
                  </Button>
                  <Button onClick={handleSaveEdit} disabled={savingEdit || !editForm.email.trim()}>
                    {savingEdit ? (
                      <>
                        <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                        Saving...
                      </>
                    ) : (
                      "Save changes"
                    )}
                  </Button>
                </DialogFooter>
              </>
            )}
          </DialogContent>
        </Dialog>

        <Dialog open={inviteOpen} onOpenChange={setInviteOpen}>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Add Staff</DialogTitle>
              <DialogDescription>
                {showPrivateTeamGuidance
                  ? "Choose the interface first. Platform staff stay inside PharmaHub Admin, while business staff stay inside the selected workspace."
                  : "Choose where this person should work, then complete the access details below."}
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="invite-interface">Interface</Label>
                <Select
                  value={inviteTarget}
                  onValueChange={(value) => setInviteTarget(value as InviteTarget["value"])}
                >
                  <SelectTrigger id="invite-interface">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {inviteTargets.map((target) => (
                      <SelectItem key={target.value} value={target.value}>
                        {target.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-2">
                <Label htmlFor="invite-email">Email Address</Label>
                <Input
                  id="invite-email"
                  type="email"
                  placeholder="staff@example.com"
                  value={inviteEmail}
                  onChange={(event) => setInviteEmail(event.target.value)}
                />
              </div>

              {invitingToBusiness ? (
                <div className="space-y-2">
                  <Label htmlFor="invite-role">Business Role</Label>
                  <Select
                    value={inviteRole}
                    onValueChange={(value) => setInviteRole(value as ManageableStaffRole)}
                  >
                    <SelectTrigger id="invite-role">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="manager">Manager - full business access</SelectItem>
                      <SelectItem value="cashier">Cashier - process orders</SelectItem>
                      <SelectItem value="assistant">Assistant - view only</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              ) : (
                <div className="space-y-2">
                  <Label>Platform Role</Label>
                  <Card className="border-dashed p-3 text-sm text-muted-foreground">
                    <div className="font-medium text-foreground">Platform Admin</div>
                    <div className="mt-1">
                      {showPrivateTeamGuidance ? (
                        <>
                          Platform invites add the person to the admin interface only. The
                          <span className="font-medium text-foreground"> Platform Owner </span>
                          role is reserved for you.
                        </>
                      ) : (
                        "This invite grants admin access to the platform."
                      )}
                    </div>
                  </Card>
                </div>
              )}
            </div>
            <DialogFooter>
              <Button variant="outline" onClick={() => setInviteOpen(false)} disabled={inviting}>
                Cancel
              </Button>
              <Button onClick={handleInvite} disabled={inviting || !inviteEmail.trim()}>
                {inviting ? (
                  <>
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    Adding...
                  </>
                ) : (
                  <>
                    <UserPlus className="mr-2 h-4 w-4" />
                    Add Staff
                  </>
                )}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </main>
    </div>
  );
}
