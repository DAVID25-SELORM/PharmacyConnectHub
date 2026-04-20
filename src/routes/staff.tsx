import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useEffectEvent, useState } from "react";
import { Loader2, Trash2, UserPlus, Users } from "lucide-react";
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
import { supabase } from "@/integrations/supabase/client";
import { timeAgo } from "@/lib/format";
import {
  inviteBusinessStaff,
  listBusinessStaff,
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

function StaffManagement() {
  const navigate = useNavigate();
  const { loading, user, business, roles } = useSession();
  const [staff, setStaff] = useState<StaffMember[]>([]);
  const [loadingStaff, setLoadingStaff] = useState(true);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState<ManageableStaffRole>("assistant");
  const [inviting, setInviting] = useState(false);
  const businessId = business?.id ?? null;

  const canManageTeam = business?.staff_role === "owner" || roles.includes("admin");

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (!business) {
      navigate({ to: "/onboarding" });
    }
  }, [loading, user, business, navigate]);

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
      toast.error("Only the business owner can add team members.");
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

  const handleUpdateRole = async (staffId: string, newRole: ManageableStaffRole) => {
    if (!canManageTeam) {
      toast.error("Only the business owner can change roles.");
      return;
    }

    try {
      const { error } = await supabase
        .from("business_staff")
        .update({ role: newRole })
        .eq("id", staffId);

      if (error) throw error;

      toast.success("Role updated successfully.");
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to update role";
      toast.error(message);
    }
  };

  const handleDeactivate = async (staffId: string) => {
    if (!canManageTeam) {
      toast.error("Only the business owner can remove team members.");
      return;
    }

    try {
      const { error } = await supabase
        .from("business_staff")
        .update({ status: "inactive" })
        .eq("id", staffId);

      if (error) throw error;

      toast.success("Team member removed.");
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to remove team member";
      toast.error(message);
    }
  };

  const handleActivate = async (staffId: string) => {
    if (!canManageTeam) {
      toast.error("Only the business owner can activate team members.");
      return;
    }

    try {
      const { error } = await supabase
        .from("business_staff")
        .update({ status: "active", joined_at: new Date().toISOString() })
        .eq("id", staffId);

      if (error) throw error;

      toast.success("Team member activated.");
      void loadStaff();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to activate team member";
      toast.error(message);
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

        {!canManageTeam && (
          <Card className="mt-6 border-dashed p-4 text-sm text-muted-foreground">
            You can view the team roster, but only the business owner can add members or change
            access.
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
                        {member.role === "owner" || !canManageTeam ? (
                          <Badge className={roleColors[member.role]}>
                            {roleLabels[member.role]}
                          </Badge>
                        ) : (
                          <Select
                            value={member.role}
                            onValueChange={(value) =>
                              handleUpdateRole(member.id, value as ManageableStaffRole)
                            }
                          >
                            <SelectTrigger className="w-32">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="manager">Manager</SelectItem>
                              <SelectItem value="cashier">Cashier</SelectItem>
                              <SelectItem value="assistant">Assistant</SelectItem>
                            </SelectContent>
                          </Select>
                        )}
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {member.joined_at ? timeAgo(member.joined_at) : "Not recorded"}
                      </TableCell>
                      <TableCell>
                        {canManageTeam && member.role !== "owner" ? (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => handleDeactivate(member.id)}
                          >
                            <Trash2 className="h-4 w-4" />
                          </Button>
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
                    <TableHead>Email</TableHead>
                    <TableHead>Role</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead>Added</TableHead>
                    <TableHead>Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {otherStaff.map((member) => (
                    <TableRow key={member.id}>
                      <TableCell>{member.user_email || "-"}</TableCell>
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
                          <div className="flex gap-1">
                            {member.status === "pending" && (
                              <Button
                                variant="outline"
                                size="sm"
                                onClick={() => handleActivate(member.id)}
                              >
                                Activate
                              </Button>
                            )}
                            {member.status !== "inactive" && (
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() => handleDeactivate(member.id)}
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
