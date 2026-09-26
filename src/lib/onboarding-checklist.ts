export type ChecklistState = "done" | "current" | "todo" | "attention";

export type ChecklistStep = {
  key: string;
  label: string;
  state: ChecklistState;
  detail?: string;
};

export type ChecklistBusiness = {
  type: "pharmacy" | "wholesaler";
  name: string;
  license_number: string | null;
  phone: string | null;
  public_email: string | null;
  city: string | null;
  region: string | null;
  address: string | null;
  owner_is_superintendent: boolean;
  superintendent_name: string | null;
  verification_status: "pending" | "approved" | "rejected";
  rejection_reason: string | null;
};

const filled = (value: string | null | undefined) => Boolean(value && value.trim());

export function missingBusinessDetails(business: ChecklistBusiness) {
  const missing: string[] = [];
  if (!filled(business.name)) missing.push("business name");
  if (!filled(business.license_number)) missing.push("licence number");
  if (!filled(business.phone)) missing.push("phone");
  if (!filled(business.public_email)) missing.push("email");
  if (!filled(business.city) || !filled(business.region)) missing.push("city and region");
  return missing;
}

/**
 * The owner's verification journey as a list of steps. The first unfinished step is marked
 * "current"; a rejected business gets "attention" steps carrying the reviewer's reason.
 */
export function buildVerificationChecklist(input: {
  business: ChecklistBusiness;
  uploadedDocTypes: string[];
  requiredDocs: Array<{ key: string; label: string }>;
}): ChecklistStep[] {
  const { business, uploadedDocTypes, requiredDocs } = input;
  const steps: ChecklistStep[] = [];

  const missing = missingBusinessDetails(business);
  steps.push({
    key: "details",
    label: "Business details",
    state: missing.length === 0 ? "done" : "todo",
    detail: missing.length === 0 ? undefined : `Missing: ${missing.join(", ")}`,
  });

  for (const doc of requiredDocs) {
    steps.push({
      key: `doc:${doc.key}`,
      label: doc.label,
      state: uploadedDocTypes.includes(doc.key) ? "done" : "todo",
      detail: uploadedDocTypes.includes(doc.key) ? undefined : "Not uploaded yet",
    });
  }

  if (business.type === "pharmacy") {
    const hasSuperintendent =
      business.owner_is_superintendent || filled(business.superintendent_name);
    steps.push({
      key: "superintendent",
      label: "Superintendent information",
      state: hasSuperintendent ? "done" : "todo",
      detail: hasSuperintendent ? undefined : "Add the superintendent pharmacist's name",
    });
  }

  const readyToSubmit = steps.every((step) => step.state === "done");
  const status = business.verification_status;

  if (status === "rejected") {
    steps.push({
      key: "submitted",
      label: "Submitted for review",
      state: "attention",
      detail: "Correction requested. Update what was flagged, then resubmit.",
    });
    steps.push({
      key: "review",
      label: "Admin review",
      state: "attention",
      detail: business.rejection_reason ? `Reviewer note: ${business.rejection_reason}` : undefined,
    });
  } else {
    steps.push({
      key: "submitted",
      label: "Submitted for review",
      state: status === "approved" || (status === "pending" && readyToSubmit) ? "done" : "todo",
      detail: readyToSubmit ? undefined : "Complete the steps above first",
    });
    steps.push({
      key: "review",
      label: "Admin review",
      state:
        status === "approved" ? "done" : status === "pending" && readyToSubmit ? "current" : "todo",
      detail:
        status === "pending" && readyToSubmit
          ? "Waiting for our team to review your documents"
          : undefined,
    });
  }

  if (status !== "rejected") {
    const firstTodo = steps.findIndex((step) => step.state === "todo");
    if (firstTodo >= 0) steps[firstTodo] = { ...steps[firstTodo], state: "current" };
  }
  return steps;
}

export function checklistProgress(steps: ChecklistStep[]) {
  const done = steps.filter((step) => step.state === "done").length;
  return {
    done,
    total: steps.length,
    percent: steps.length === 0 ? 0 : Math.round((done / steps.length) * 100),
  };
}
