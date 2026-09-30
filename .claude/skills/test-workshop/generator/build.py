# Builds the run-dashboard templates in ../templates/ from source-rows.json, the
# page-by-page rows of the 2026-09-29 full-cycle self-paced run.
#   python3 build.py                        # rewrite the seven templates
#   python3 build.py --preview <file.html>  # also write the browser preview
import json, os, copy, sys
SP = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(SP, "..", "templates")
rows = json.load(open(os.path.join(SP, "source-rows.json")))
rows.sort(key=lambda r: r["order"])

KEEP = ("track", "trackLabel", "code", "step", "sub", "does", "cmd", "expected", "browser")
def clean(r):
    o = {k: r[k] for k in KEEP if r.get(k) not in (None, "")}
    o.setdefault("step", r.get("step", ""))
    o.setdefault("sub", r.get("sub", ""))
    o["state"] = "queued"
    o["proof"] = []
    return o
def skip(o, label, why):
    if label == "Read, not executed":
        why = "read, not executed — " + why
    o["state"] = "na"; o["proof"] = [{"label": "Why", "value": why}]; return o
def row(track, code, step, sub, does, cmd, expected=None, browser=None):
    o = {"track": track, "code": code, "step": step, "sub": sub, "does": does, "cmd": cmd, "state": "queued", "proof": []}
    if expected: o["expected"] = expected
    if browser: o["browser"] = True
    return o

base = []
for r in rows:
    o = clean(r)
    if o["code"] == "Run Pre-flight Checks" and o["step"].startswith("Step 2") and "\n" in o["cmd"]:
        clone, pre = o["cmd"].split("\n", 1)
        a = dict(o, sub="Clone the repo", cmd=clone.replace("cd ~ &&", "cd ~/Documents &&", 1),
                 does="The workshop code is on your machine and you are inside it; safe to re-run if it is already there.")
        b = dict(o, sub="Run the pre-flight script", cmd=pre)
        base += [a, b]; continue
    base.append(o)
# Row 14's `does` carried run-specific narration (an IP rotation re-run); keep only the page's claim.
for o in base:
    if o["code"] == "Deploy — Self-paced" and o["step"].startswith("Step 3"):
        o["does"] = ("The identity layer the whole workshop leans on is up — Vault holding credentials and "
                     "IBM Verify handling sign-in — both served on a certificate a browser will trust.")
phase1_sp = [o for o in base if o["track"] == "A"]
CS_TAB = ("Open CloudShell", "Make the Downloads folder", "Upload the Vault Enterprise licence",
          "CloudShell: point kubectl at 1.34", "Install bc, self-paced only")
for o in phase1_sp:
    if o["code"] == "Run Pre-flight Checks" and o["sub"] in CS_TAB:
        o["state"] = "na"
        o["proof"] = [{"label": "Why", "value": "CloudShell tab — self-paced runs in your IDE terminal"}]
shared    = [o for o in base if o["track"] in ("B", "C", "D", "E")]
cleanup   = [o for o in base if o["track"] == "F"]

# ---------- Phase 0 (self-paced full cycle only) ----------
P0 = "Clean slate"
phase0 = [
  row("P0", P0, "Tear down", "",
      "All three tiers are gone and the account is back to nothing. Every self-paced run ends with Cleanup, "
      "so this normally finds nothing and proves it.",
      "bash infrastructure/scripts/teardown.sh --yes",
      "Exit 0 and no FAIL lines in the script's own zero-residual check."),
  row("P0", P0, "Wipe the local state", "Terraform state",
      "The next deploy starts from nothing, not from stale local state.",
      "# in each of infrastructure, infrastructure/services, infrastructure/workloads, infrastructure/vault-config\nrm -f terraform.tfstate* && rm -rf .terraform/"),
  row("P0", P0, "Wipe the local state", "Tier-2 files",
      "No certificate state or Vault root token from a torn-down Vault is left to mislead the run.",
      "rm -f infrastructure/.acme-state ~/vault-init.json"),
]
phase0[0]["trackLabel"] = "Phase 0 — Clean slate"
phase0[0]["trackNoteTitle"] = "Hard rule: tear down tier 2 and tier 3 MUST be redeployed"
phase0[0]["trackNote"] = ("Whatever Phase 0 removes, Phase 1 redeploys. teardown.sh has no --tier option yet, so Phase 0 removes "
                          "all three tiers and Phase 1 redeploys all three.")
# ---------- Phase 1, at an event ----------
AE, PF, DA, CK = "At an Event", "Run Pre-flight Checks", "Deploy — At an Event", "Configure kubectl"
def phase1_ae(env):
    cs = env == "cs"
    out = [
      row("A", AE, "Step 1 — Open the join link", "",
          "You reach this event's Workshop Studio sign-in page.",
          "Open the join URL, or enter the 12-digit event code at https://catalog.us-east-1.prod.workshops.aws/join", browser=True),
      row("A", AE, "Step 2 — Sign in with Email OTP", "",
          "You are signed in to Workshop Studio as yourself.",
          "Enter your email, click Send passcode, then enter the 6-digit passcode from your inbox.", browser=True),
      row("A", AE, "Step 3 — Join the event and open the AWS console", "Open the AWS console",
          "A console session in the event account as WSParticipantRole.",
          "Click Join event, then Open AWS console.", browser=True),
      row("A", AE, "Step 3 — Join the event and open the AWS console", "Open CloudShell",
          "A terminal that already carries the workshop identity, in the workshop region.",
          "Click Open CloudShell (opens CloudShell in us-east-1).", browser=True),
      row("A", AE, "Step 4 — Confirm the region", "",
          "Everything you open in the console is in the region the workshop deployed into.",
          "Check the console's region selector (top right) shows us-east-1.", "us-east-1", browser=True),
      row("A", AE, "Step 5 — If you prefer your own terminal", "Paste the CLI credentials",
          "Your own terminal carries the event account's short-term WSParticipantRole credentials.",
          "Left nav, bottom: AWS account access → Get AWS CLI credentials → paste the block for your shell.", browser=True),
      row("A", AE, "Step 5 — If you prefer your own terminal", "Confirm the workshop identity",
          "The CLI is using the workshop identity, which holds EKS access and can read the staged Tier-1 state.",
          "aws sts get-caller-identity", "The Arn contains WSParticipantRole."),
    ]
    if cs:
        skip(out[5], "Not this cell", "CloudShell carries the console session's credentials — nothing to paste")
        skip(out[6], "Not this cell", "the page runs this check only for your own terminal")
    else:
        skip(out[3], "Not this cell", "this run uses your own terminal, not CloudShell")
    # Pre-flight, reusing the self-paced rows and re-deciding each skip for this cell.
    pf = [copy.deepcopy(o) for o in phase1_sp if o["code"] == PF]
    for o in pf:
        o["state"], o["proof"] = "queued", []
        s = o["sub"]
        if s in ("Open CloudShell", "Make the Downloads folder", "Upload the Vault Enterprise licence", "CloudShell: point kubectl at 1.34"):
            if not cs: skip(o, "Not this cell", "CloudShell tab — this run uses your own terminal")
        if s == "Install bc, self-paced only":
            skip(o, "Not this cell", "the page marks it self-paced only")
        if o["step"].startswith("Self-paced only"):
            skip(o, "Not this cell", "self-paced only — Workshop Studio's CodeBuild already built and pushed the images")
    # The event-account re-run the page gives in Step 2's alert.
    i = next(k for k, o in enumerate(pf) if o["step"].startswith("Step 2"))
    pf.insert(i + 1, row("A", PF, "Step 2 — Clone the repo and run the pre-flight script",
        "Re-run with the IAM simulation skipped",
        "The pre-flight summary is free of the simulator's false denials, which an event account always produces.",
        "bash infrastructure/scripts/check-prerequisites.sh --skip-iam-sim --skip-quotas",
        "No implicitDeny failures in the summary."))
    out += pf
    out += [
      row("A", DA, "Step 1 — Clone the repository", "",
          "You are inside the workshop repository; safe to re-run if it is already cloned.",
          "cd ~ && { [ -d sample-agentic-runtime-security-on-aws-with-vault ] || git clone https://github.com/aws-samples/sample-agentic-runtime-security-on-aws-with-vault.git; } && cd sample-agentic-runtime-security-on-aws-with-vault && pwd"),
      row("A", DA, "Step 2 — Bootstrap", "",
          "The config files tiers 2 and 3 read are written, pointing at the images CodeBuild already pushed to your ECR. Nothing is deployed.",
          "bash infrastructure/scripts/bootstrap.sh --skip-prereq-gate --image-source ecr"),
      row("A", DA, "Step 3 — Pull the Tier-1 state and config", "",
          "Tiers 2 and 3 can find the cluster, network and database Workshop Studio built for you.",
          "STATE_BUCKET=$(aws cloudformation describe-stacks --query \"Stacks[].Outputs[?OutputKey=='StateBucketName'].OutputValue|[]|[0]\" --output text) && aws s3 cp \"s3://${STATE_BUCKET}/tier1/terraform.tfstate\" infrastructure/terraform.tfstate && aws s3 cp \"s3://${STATE_BUCKET}/tier1/terraform.tfvars\" infrastructure/terraform.tfvars && test -s infrastructure/terraform.tfstate && echo \"State + config pulled OK\" || echo \"ERROR: pull failed\"",
          "State + config pulled OK"),
      row("A", DA, "Step 3 — Pull the Tier-1 state and config", "If the CloudFormation query returns empty",
          "You can still find the state bucket by name when the stack outputs are not visible yet.",
          "aws s3 ls | grep -i bootstrap-statebucket"),
      row("A", DA, "Step 4 — Deploy Tier 2 (Vault + IVIA)", "Export the two IBM secrets",
          "The deploy can run start to finish without stopping to ask for the two IBM secrets.",
          "export ICR_ENTITLEMENT_KEY=\"<value from your organizer>\"\nexport IVIA_MMFA_PUSH_CLIENT_SECRET=\"<value from your organizer>\""),
      row("A", DA, "Step 4 — Deploy Tier 2 (Vault + IVIA)", "Put the Vault licence where the deploy reads it",
          "The Vault Enterprise licence is at the path the deploy reads, so its preflight does not stop.",
          "cp /path/to/vault-ent.hclic ~/Downloads/vault-ent.hclic\n# ...or point the env var at wherever you saved it:\nexport VAULT_ENTERPRISE_LICENSE_PATH=/path/to/vault-ent.hclic"),
      row("A", DA, "Step 4 — Deploy Tier 2 (Vault + IVIA)", "Deploy Tier 2",
          "Vault holds credentials and IBM Verify handles sign-in, both served on a certificate a browser will trust.",
          "bash infrastructure/scripts/deploy-workshop.sh --tier 2"),
      row("A", DA, "Step 5 — Deploy Tier 3 (Use Case workloads)", "",
          "The three agents and the banking app are running, and the database and Knowledge Base hold the data the use cases read.",
          "bash infrastructure/scripts/deploy-workshop.sh --tier 3"),
    ]
    out += [copy.deepcopy(o) for o in phase1_sp if o["code"] == CK]
    for o in out:
        o["track"] = "A"
        # Clone blocks: CloudShell runs the page's `cd ~`; your own terminal clones under ~/Documents.
        if o.get("cmd", "").startswith(("cd ~ && {", "cd ~/Documents && {")):
            o["cmd"] = o["cmd"].replace("cd ~/Documents && {", "cd ~ && {", 1)
            if not cs:
                o["cmd"] = o["cmd"].replace("cd ~ && {", "cd ~/Documents && {", 1)
    out[0]["trackLabel"] = "Phase 1 — Deploy"
    out[0]["trackNoteTitle"] = "Not on this board, by design"
    out[0]["trackNote"] = ("The four attendee-denial checks (a 403 on tier2-private state, the sanitized tier-2 copy, its secret scan) "
                           "cannot run at an event as the code stands — CodeBuild never deploys tier 2 — so they are never reported as passing.")
    return out

def shared_for(env):
    out = [copy.deepcopy(o) for o in shared]
    for o in out:
        if o["sub"] == "Open the Vault Web UI" and env == "cs":
            skip(o, "Not this cell", "localhost:8200 is the CloudShell container, not your browser's machine — the page says to skip it")
    return out

def cleanup_for(reason):
    out = [skip(copy.deepcopy(o), "Not run", reason) for o in cleanup]
    return out

def hold_then_cleanup():
    hold = row("V", "Bear verifies", "", "Browser CIBA refund, and anything else Bear checks",
               "The run stops with everything still standing. Bear tests the CIBA refund in the browser with his own phone "
               "and checks whatever else he wants. If he finds something, the environment stays up, the fix is tested on it "
               "with a content or changed-pages pass, and the run comes back here.",
               "— no command; the run waits for Bear", "Bear says he is done verifying.", browser=True)
    out = [hold] + [copy.deepcopy(o) for o in cleanup]
    out[1]["trackNoteTitle"] = "Runs once Bear says he is done"
    out[1]["trackNote"] = ("Self-paced testing ends here — the teardown and all four spot-checks, verbatim — but only after Bear "
                           "says he is done verifying. Until then the environment stays up for fixes. The account is left empty.")
    return out

def seq(lst):
    for i, o in enumerate(lst, 1): o["order"] = i
    return lst


LABELS = {"P0": "Phase 0 — Clean slate", "A": "Phase 1 — Deploy", "B": "Phase 2 — Verify the foundation",
          "C": "Phase 3 — Use Case 1: Non-Personalized Read-Only", "D": "Phase 3 — Use Case 2: OAuth Personalized Read-Only",
          "E": "Phase 3 — Use Case 3: Privileged Action with CIBA", "V": "Hold — Bear verifies", "F": "Cleanup"}
def finish(lst):
    seen = set()
    for i, o in enumerate(lst, 1):
        o["order"] = i
        if o["track"] not in seen:
            seen.add(o["track"]); o["trackLabel"] = LABELS[o["track"]]
        else:
            o.pop("trackLabel", None)
    return lst

DEPLOY_PAGES = ("Deploy — Self-paced",)
def phase1_sp_content():
    out = [copy.deepcopy(o) for o in phase1_sp]
    for o in out:
        o.pop("trackNote", None); o.pop("trackNoteTitle", None)
        if o["code"] in DEPLOY_PAGES:
            skip(o, "Read, not executed", "the environment is already deployed — a content pass never re-runs a deploy")
        if o["sub"] == "Run the pre-flight script":
            skip(o, "Read, not executed", "tools and account were checked when this environment was deployed")
    return out

# The pages this branch changes: `git diff --name-only <baseline>...HEAD -- workshop/content`,
# each file mapped to its page title. Update this tuple whenever content changes.
CHANGED_PAGES = ("Verify Credentials and Enforcement", "OAuth Login Flow", "Verify Per-User Data Access",
                 "Credential Revocation", "Test the Refund Flow", "The Bypass Test", "Three-Plane Audit Correlation")
def changed(env):
    out = [copy.deepcopy(o) for o in shared_for(env) if o["code"] in CHANGED_PAGES]
    out[0]["trackNoteTitle"] = "Changed pages"
    out[0]["trackNote"] = ("A changed-pages board lists only the pages changed since the last tested run, in workshop order, "
                           "each run in full. These seven are the pages this branch changes.")
    return out

LOG_LOCAL = "~/Documents/sample-agentic-runtime-security-on-aws-with-vault/infrastructure/scripts/logs/walkthrough-<epoch>.log"
LOG_CS    = "~/sample-agentic-runtime-security-on-aws-with-vault/infrastructure/scripts/logs/walkthrough-<epoch>.log"
def run(title, stand, qtitle, q, cluster, ident):
    return {"label": title, "standfirst": stand, "questionTitle": qtitle, "question": q,
            "startedAt": "set at run start", "commit": "set at run start", "cluster": cluster,
            "identity": ident, "currentPhase": "Template — nothing has run",
            "logPath": LOG_CS if "CloudShell" in title else LOG_LOCAL}
SP_ID, AE_ID = "your account", "WSParticipantRole"
SP_CL, AE_CL = "set at run start", "tier-1 cluster from Workshop Studio"
MEASURED = "\n\nSelf-paced is measured, not repaired — a break is recorded and the run continues."
AE_START = "A fresh Workshop Studio account with tier 1 already built. "

templates = {
 "full-cycle/sp": {
  "run": run("Full Cycle · Self-paced · Your Account, IDE",
     "The account is taken back to nothing, all three tiers are redeployed from the pages, and every page is walked the way an attendee reaches it.",
     "Does a fresh deploy of the changed tiers still get someone on a laptop through the whole workshop?",
     "Set at run start: why this is a full cycle, the image source, and the Use Case 3 enrollment choice." + MEASURED, SP_CL, SP_ID),
  "phases": finish(phase0 + copy.deepcopy(phase1_sp) + shared_for("ide") + hold_then_cleanup())},
 "full-content/sp": {
  "run": run("Full Content Pass · Self-paced · Your Account, IDE",
     "Every page is walked, in order, against the environment already running. Nothing is torn down or redeployed; the deploy page is read, not executed.",
     "Does every page still work, as written, against the running environment?",
     "Set at run start: the baseline commit the environment was validated at, the image source, and the Use Case 3 enrollment choice.\n\nNo clean-slate deploy runs, so any Terraform change since the baseline is named as untested from a fresh init." + MEASURED, SP_CL, SP_ID),
  "phases": finish(phase1_sp_content() + shared_for("ide") + hold_then_cleanup())},
 "full-content/ae-cs": {
  "run": run("Full Content Pass · At an Event · CloudShell",
     AE_START + "Every page is walked in order in CloudShell, including the tier-2 and tier-3 deploy the attendee runs.",
     "Can an attendee get from a fresh Workshop Studio account to the end of Use Case 3?",
     "Set at run start: the event, the commit, and the Use Case 3 enrollment choice.\n\nThe account is never torn down.", AE_CL, AE_ID),
  "phases": finish(phase1_ae("cs") + shared_for("cs") + cleanup_for("Workshop Studio owns this account — it is never torn down"))},
 "full-content/ae-ide": {
  "run": run("Full Content Pass · At an Event · Own IDE",
     AE_START + "Every page is walked in order in your own terminal on the event's short-term credentials, including the tier-2 and tier-3 deploy the attendee runs.",
     "Can an attendee get from a fresh Workshop Studio account to the end of Use Case 3?",
     "Set at run start: the event, the commit, and the Use Case 3 enrollment choice.\n\nThe account is never torn down.", AE_CL, AE_ID),
  "phases": finish(phase1_ae("ide") + shared_for("ide") + cleanup_for("Workshop Studio owns this account — it is never torn down"))},
 "changed/sp": {
  "run": run("Changed-Pages Pass · Self-paced · Your Account, IDE",
     "Only the pages changed since the last tested run are walked, each in full, against the environment that run left standing.",
     "Do the pages that changed still work?",
     "Set at run start: the baseline commit and the list of changed pages.\n\nProves those pages and nothing else — no other page and no infrastructure." + MEASURED, SP_CL, SP_ID),
  "phases": finish(changed("ide") + hold_then_cleanup())},
 "changed/ae-cs": {
  "run": run("Changed-Pages Pass · At an Event · CloudShell",
     "Only the pages changed since the last tested run are walked, each in full, in CloudShell, against the Workshop Studio environment that run left standing.",
     "Do the pages that changed still work?",
     "Set at run start: the baseline commit and the list of changed pages.\n\nProves those pages and nothing else — no other page and no infrastructure.", AE_CL, AE_ID),
  "phases": finish(changed("cs"))},
 "changed/ae-ide": {
  "run": run("Changed-Pages Pass · At an Event · Own IDE",
     "Only the pages changed since the last tested run are walked, each in full, in your own terminal, against the Workshop Studio environment that run left standing.",
     "Do the pages that changed still work?",
     "Set at run start: the baseline commit and the list of changed pages.\n\nProves those pages and nothing else — no other page and no infrastructure.", AE_CL, AE_ID),
  "phases": finish(changed("ide"))},
}
for k, t in templates.items():
    with open(os.path.join(OUT, k.replace("/", "--") + ".json"), "w") as f:
        json.dump(t, f, ensure_ascii=False, indent=1)
if "--preview" in sys.argv:
    page = open(os.path.join(SP, "preview.tmpl.html")).read()
    data = json.dumps(templates, ensure_ascii=False).replace("</", "<\\/")
    with open(sys.argv[sys.argv.index("--preview") + 1], "w") as f:
        f.write(page.replace("__TEMPLATES__", data))
for k, t in templates.items():
    ph = t["phases"]; st = {}
    for o in ph: st[o["state"]] = st.get(o["state"], 0) + 1
    pages = []
    for o in ph:
        if (o["track"], o["code"]) not in pages: pages.append((o["track"], o["code"]))
    print(f"{k:22} {len(ph):3} rows {st} | {len(pages)} pages | tracks {[o['trackLabel'] for o in ph if o.get('trackLabel')]}")
