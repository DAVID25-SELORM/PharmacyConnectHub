import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useEffectEvent, useState } from "react";
import { Loader2, Pencil, Trash2, UserPlus, Users } from "lucide-react";
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
import { useSession, type BusinessStaffRole } from "@/hooks/use-session";
import { timeAgo } from "@/lib/format";
import {
  inviteBusinessStaff,
  listBusinessStaff,
  resendBusinessStaffInvite,
  updateBusinessStaffMember,
  type StaffMember,
  type StaffStatus,
} from "@/lib/staff-actions";

export const Route = createFileRoute("/staff")({
  head: () => ({
    meta: [{ title: "Team - PharmaHub GH" }],
  }),
  component: StaffManagement,
});

type ManageableStaffRole = Exclude<BusinessStaffRole, "owner">;

const roleLabels: Record<BusinessStaffRole, string> = {
  owner: "Owner",
  manager: "Manager",
  cashier: "Cashier",
  assistant: "Assistant",
};

const roleColors: Record<BusinessStaffRole, string> = {
  owner: "bg-purple-100 text-purple-800",
  manager: "bg-blue-100 text-blue-800",
  cashier: "bg-green-100 text-green-800",
  assistant: "bg-gray-100 text-gray-800",
};

const statusLabels: Record<StaffStatus, string> = {
  active: "Active",
  inactive: "Inactive",
  pending: "Pending",
};

const statusColors: Record<StaffStatus, string> = {
  active: "bg-green-100 text-green-800",
  inactive: "bg-slate-100 text-slate-700",
  pending: "bg-amber-100 text-amber-800",
};

type StaffEditForm = {
  fullName: string;
  email: string;
  phone: string;
  role: BusinessStaffRole;
  status: StaffStatus;
};

const emptyEditForm: StaffEditForm = {
  fullName: "",
  email: "",
  phone: "",
  role: "assistant",
  status: "active",
};

function createEditForm(member: StaffMember): StaffEditForm {
  return {
    fullName: member.full_name ?? "",
    email: member.user_email ?? "",
    phone: member.phone ?? "",
    role: member.role,
    status: member.status,
  };
}

function getEditableStatuses(member: StaffMember): StaffStatus[] {
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

function StaffManagement() {
  const navigate = useNavigate();
  const { loading, user, business, businesses, roles } = useSession();
  const [staff, setStaff] = useState<StaffMember[]>([]);
  const [loadingStaff, setLoadingStaff] = useState(true);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState<ManageableStaffRole>("assistant");
  const [inviting, setInviting] = useState(false);
  const [resendingStaffId, setResendingStaffId] = useState<string | null>(null);
  const [editingMember, setEditingMember] = useState<StaffMember | null>(null);
  const [editForm, setEditForm] = useState<StaffEditForm>(emptyEditForm);
  const [savingEdit, setSavingEdit] = useState(false);
  const businessId = business?.id ?? null;

  const canManageTeam = business?.staff_role === "owner" || roles.includes("admin");

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (!business && businesses.length > 1) {
      navigate({ to: "/dashboard" });
      return;
    }
    if (!business) {
      if (roles.includes("admin")) {
        navigate({ to: "/admin" });
        return;
      }
      navigate({ to: "/onboarding" });
      return;
    }
  }, [loading, user, business, businesses, roles, navigate]);

  const loadStaff = useEffectEvent(async () => {
    if (!business) return;
    setLoadingStaff(true);
    try {
      setStaff(await listBusinessStaff(business.id));
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to load team members";
      toast.error(message);
    } finally {
      setLoadingStaff(false);
    }
  });

  useEffect(() => {
    if (businessId) {
      void loadStaff();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [businessId]);

  const handleInvite = async () => {
    if (!business || !inviteEmail.trim()) return;
    if (!canManageTeam) {
      toast.error("Only the business owner or an admin can add team members.");
      return;
    }

    setInviting(true);
    try {
      const result = await inviteBusinessStaff({
        businessId: business.id,
        email: inviteEmail.trim().toLowerCase(),
        role: inviteRole,
      });
      toast.success(
        result.mode === "invited"
          ? "Invitation email sent! They'll receive a link to set up their account."
          : "Team member added successfully!",
      );
      setInviteOpen(false);
      setInviteEmail("");
      setInviteRole("assistant");
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to add team member";
      toast.error(message);
    } finally {
      setInviting(false);
    }
  };

  const saveStaffChanges = async (
    member: StaffMember,
    overrides: Partial<StaffEditForm>,
  ): Promise<void> => {
    if (!business) {
      throw new Error("Business context is unavailable.");
    }

    const email = (overrides.email ?? member.user_email ?? "").trim().toLowerCase();
    if (!email) {
      throw new Error("Staff email is required.");
    }

    await updateBusinessStaffMember({
      businessId: business.id,
      staffId: member.id,
      fullName: overrides.fullName ?? member.full_name ?? "",
      email,
      phone: overrides.phone ?? member.phone ?? "",
      role: (overrides.role ?? member.role) as BusinessStaffRole,
      status: (overrides.status ?? member.status) as StaffStatus,
    });
  };

  const openEditDialog = (member: StaffMember) => {
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
    if (!canManageTeam) {
      toast.error("Only the business owner or an admin can edit team members.");
      return;
    }

    setSavingEdit(true);
    try {
      await saveStaffChanges(editingMember, editForm);
      toast.success("Team member details updated.");
      closeEditDialog(false);
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to update team member";
      toast.error(message);
      setSavingEdit(false);
    }
  };

  const handleDeactivate = async (member: StaffMember) => {
    if (!canManageTeam) {
      toast.error("Only the business owner or an admin can remove team members.");
      return;
    }

    try {
      await saveStaffChanges(member, { status: "inactive" });
      toast.success(member.status === "pending" ? "Invite cancelled." : "Team member deactivated.");
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to update team member";
      toast.error(message);
    }
  };

  const handleActivate = async (member: StaffMember) => {
    if (!canManageTeam) {
      toast.error("Only the business owner or an admin can activate team members.");
      return;
    }

    try {
      await saveStaffChanges(member, { status: "active" });
      toast.success(
        member.status === "inactive" ? "Team member reactivated." : "Team member activated.",
      );
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to update team member";
      toast.error(message);
    }
  };

  const handleResendInvite = async (member: StaffMember) => {
    if (!business) return;
    if (!canManageTeam) {
      toast.error("Only the business owner or an admin can resend access emails.");
      return;
    }
    if (member.status === "inactive") {
      toast.error("Reactivate this staff member before sending an access email.");
      return;
    }

    setResendingStaffId(member.id);
    try {
      await resendBusinessStaffInvite({
        businessId: business.id,
        staffId: member.id,
      });
      toast.success(
        member.user_email
          ? member.status === "pending"
            ? `Access email resent to ${member.user_email}.`
            : `Reset email sent to ${member.user_email}.`
          : member.status === "pending"
            ? "Access email resent successfully."
            : "Reset email sent successfully.",
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to resend access email";
      toast.error(message);
    } finally {
      setResendingStaffId(null);
    }
  };

  if (loading || !user || !business) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  const activeStaff = staff.filter((member) => member.status === "active");
  const otherStaff = staff.filter((member) => member.status !== "active");
  const editableStatuses: StaffStatus[] = editingMember
    ? getEditableStatuses(editingMember)
    : ["active"];

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle={business.name} showNav={true} isAdmin={roles.includes("admin")} />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="flex items-center gap-2 font-display text-3xl font-bold">
              <Users className="h-8 w-8" />
              Team Members
            </h1>
            <p className="mt-1 text-muted-foreground">
              Manage who can access your business workspace.
            </p>
          </div>
          {canManageTeam && (
            <Button onClick={() => setInviteOpen(true)}>
              <UserPlus className="mr-2 h-4 w-4" />
              Add Staff
            </Button>
          )}
        </div>

        {canManageTeam ? (
          <Card className="mt-6 border-dashed p-4 text-sm text-muted-foreground">
            Pending invites appear under Other Access Records. Active staff can also receive a reset
            email from the roster. Use Edit to update name, email, phone, role, or status.
          </Card>
        ) : (
          <Card className="mt-6 border-dashed p-4 text-sm text-muted-foreground">
            You can view the team roster, but only the business owner or an admin can add members or
            change access.
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
              <p className="py-12 text-center text-muted-foreground">No active team members yet.</p>
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
                        {canManageTeam ? (
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
                        ) : (
                          "-"
                        )}
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
                      <TableCell className="text-muted-foreground">
                        <Badge className={statusColors[member.status]}>
                          {statusLabels[member.status]}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {timeAgo(member.invited_at)}
                      </TableCell>
                      <TableCell>
                        {canManageTeam ? (
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
                            {member.status !== "inactive" && (
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() => handleDeactivate(member)}
                              >
                                Cancel
                              </Button>
                            )}
                          </div>
                        ) : (
                          "-"
                        )}
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
              <DialogTitle>Edit Team Member</DialogTitle>
              <DialogDescription>
                {editingMember?.status === "pending"
                  ? "Update this pending invite before resending the access email."
                  : "Update the member's contact details and workspace access."}
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
                      placeholder="staff@example.com"
                      value={editForm.email}
                      onChange={(event) =>
                        setEditForm((current) => ({ ...current, email: event.target.value }))
                      }
                    />
                  </div>

                  <div className="grid gap-4 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label htmlFor="edit-role">Role</Label>
                      {editingMember.role === "owner" ? (
                        <div className="space-y-2 rounded-md border p-3">
                          <Badge className={roleColors.owner}>{roleLabels.owner}</Badge>
                          <p className="text-xs text-muted-foreground">
                            The business owner keeps the owner role.
                          </p>
                        </div>
                      ) : (
                        <Select
                          value={editForm.role}
                          onValueChange={(value) =>
                            setEditForm((current) => ({
                              ...current,
                              role: value as ManageableStaffRole,
                            }))
                          }
                        >
                          <SelectTrigger id="edit-role">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            <SelectItem value="manager">Manager</SelectItem>
                            <SelectItem value="cashier">Cashier</SelectItem>
                            <SelectItem value="assistant">Assistant</SelectItem>
                          </SelectContent>
                        </Select>
                      )}
                    </div>

                    <div className="space-y-2">
                      <Label htmlFor="edit-status">Status</Label>
                      {editingMember.role === "owner" ? (
                        <div className="space-y-2 rounded-md border p-3">
                          <Badge className={statusColors.active}>{statusLabels.active}</Badge>
                          <p className="text-xs text-muted-foreground">
                            The business owner must stay active.
                          </p>
                        </div>
                      ) : (
                        <Select
                          value={editForm.status}
                          onValueChange={(value) =>
                            setEditForm((current) => ({
                              ...current,
                              status: value as StaffStatus,
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
                      send a fresh invite.
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
              <DialogTitle>Add Team Member</DialogTitle>
              <DialogDescription>
                Enter the staff member's email address. If they already have a PharmaHub account,
                they'll be added immediately. Otherwise, they'll receive an email invitation to set
                up their account.
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="email">Email Address</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="staff@example.com"
                  value={inviteEmail}
                  onChange={(event) => setInviteEmail(event.target.value)}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="role">Role</Label>
                <Select
                  value={inviteRole}
                  onValueChange={(value) => setInviteRole(value as ManageableStaffRole)}
                >
                  <SelectTrigger id="role">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="manager">Manager - full business access</SelectItem>
                    <SelectItem value="cashier">Cashier - process orders</SelectItem>
                    <SelectItem value="assistant">Assistant - view only</SelectItem>
                  </SelectContent>
                </Select>
              </div>
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
