"""Render the SLX and taskset templates the way runwhen-local does, and assert
on what comes out.

Why this exists as a separate tier: the offline tier is pure shell and checks
templates by grepping for expressions. That catches a regression whose exact
shape is already known, but it cannot catch the class of bug that put it here.
`match_resource.resource.name` looks like a safe fallback and is not --
runwhen-local's CustomUndefined subclasses plain jinja2.Undefined, whose
__getattr__ RAISES, so reaching through an absent .resource aborts the entire
render with UndefinedError instead of falling through to the next candidate.
No amount of grepping finds that. Rendering it does, immediately.

Mirrors src/template.py from runwhen-local: SandboxedEnvironment with
trim_blocks, lstrip_blocks and CustomUndefined. CustomUndefined's __str__
returns a placeholder string rather than "", which is why one case below
asserts that placeholder never reaches a config value.

    python3 check.py <templates-dir>
"""
import sys

import yaml
from jinja2 import BaseLoader, Undefined
from jinja2.sandbox import SandboxedEnvironment

TPL = sys.argv[1] if len(sys.argv) > 1 else "../../.runwhen/templates"
NAME = "gcp-apigee-traffic-health"


class CustomUndefined(Undefined):
    """Copy of runwhen-local's. The placeholder return is the point."""

    def __str__(self):
        return "missing_workspaceInfo_custom_variable"


# The shared includes live in runwhen-local, so they are stubbed: this tier
# tests THIS bundle's logic, not theirs. Two trailing newlines because jinja
# strips one from every template source and trim_blocks eats the one after the
# {% include %} tag.
STUBS = {
    "common-labels.yaml": "    app: test\n\n",
    "common-annotations.yaml": "    note: test\n\n",
    "gcp-tags.yaml": "    - name: platform\n      value: gcp\n\n",
    "gcp-hierarchy.yaml": "    hierarchy: gcp/test-project/test-org\n\n",
    "gcp-auth.yaml": "    - name: gcp_credentials\n      workspaceKey: gcp\n\n",
}


class Loader(BaseLoader):
    def get_source(self, environment, template):
        if template in STUBS:
            return STUBS[template], template, lambda: True
        with open(f"{TPL}/{template}") as fh:
            return fh.read(), template, lambda: True


env = SandboxedEnvironment(trim_blocks=True, lstrip_blocks=True,
                           undefined=CustomUndefined, loader=Loader())

PASS = FAIL = 0


def check(label, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"    PASS {label}")
    else:
        FAIL += 1
        print(f"    FAIL {label} (expected {want!r}, got {got!r})")


def base_vars(**over):
    v = {
        "slx_name": "gcp-apigee-traffic-health-abc123",
        "project": {"name": "test-project"},
        "workspace": {"owner_email": "owner@example.com"},
        "default_location": "location-01",
        "repo_url": "", "ref": "", "wb_version": "",
        "match_resource": {
            "resource": {"name": "test-org", "project_id": "test-project"},
            "name": "test-org",
            "qualified_name": "gcp/test-project/test-org",
        },
        "qualifiers": {"resource": "test-org"},
        "custom": {},
    }
    v.update(over)
    return v


class RenderFailed:
    """A render that raised. Kept as a value rather than propagating, because
    raising IS the bug this tier exists to catch -- a traceback would abort the
    remaining cases and report nothing about them."""

    def __init__(self, exc):
        self.exc = exc

    def __repr__(self):
        return f"<render raised {type(self.exc).__name__}: {self.exc}>"

    def splitlines(self):
        return [repr(self)]


def render(kind, **over):
    try:
        out = env.get_template(f"{NAME}-{kind}.yaml").render(**base_vars(**over))
        doc = yaml.safe_load(out)  # also proves the render is valid YAML
        cfg = {c["name"]: c["value"] for c in doc["spec"]["configProvided"]}
        return cfg.get("APIGEE_ORG"), doc, out
    except Exception as exc:  # noqa: BLE001 -- any failure is a failed render
        failed = RenderFailed(exc)
        return failed, {"spec": {"alias": "", "description": "", "tags": []}}, failed


for kind in ("slx", "taskset"):
    print(f"\n== {kind} ==")

    org, doc, out = render(kind)
    check(f"{kind}: indexed org wins", org, "test-org")
    check(f"{kind}: renders starting at apiVersion",
          out.splitlines()[0], "apiVersion: runwhen.com/v1")

    # The defect this bundle shipped with: {{match_resource.resource_name}}.
    # runwhen-local never builds a `resource_name` attribute, and
    # CustomUndefined.__str__ returns a placeholder rather than "", so the
    # config value, the alias and the description all rendered the literal
    # string `missing_workspaceInfo_custom_variable` on a FULLY POPULATED
    # workspace. Nothing was undefined-looking about the output; it just named
    # an org that does not exist. Checked across every VALUE in the render --
    # not just APIGEE_ORG -- because the placeholder reached the alias an
    # operator reads as well as the value every API call uses.
    #
    # Asserted against the PARSED document, not the raw text. The template's own
    # commentary names the placeholder while explaining the bug, so matching the
    # rendered source would fail on the documentation rather than on any real
    # output -- and, worse, would keep failing after a fix.
    check(f"{kind}: no undefined placeholder in any rendered value",
          "missing_workspaceInfo" in yaml.safe_dump(doc), False)

    # The sibling security bundle set APIGEE_ORG from {{project.name}}. That
    # works by coincidence on Apigee X, where the org ID IS the project ID,
    # which is exactly why it survives testing in a normal workspace and fails
    # on any divergence -- an explicit override, hybrid, or legacy Edge. Here
    # the two differ on purpose.
    org, _, _ = render(kind, project={"name": "runwhen-nonprod-sandbox"},
                       match_resource={"resource": {"name": "sandbox-org"},
                                       "name": "sandbox-org",
                                       "qualified_name": "q"},
                       qualifiers={"resource": "sandbox-org"})
    check(f"{kind}: org is the org, not the project, when they differ",
          org, "sandbox-org")

    # workspaceInfo declaring the key but leaving it blank. Plain default()
    # substitutes only for UNDEFINED, so this is what rendered APIGEE_ORG empty
    # on a live workspace while the resource_name tag stayed populated.
    org, _, _ = render(kind, custom={"apigee_org": ""})
    check(f"{kind}: blank override falls through", org, "test-org")

    org, _, _ = render(kind, custom={"apigee_org": "override-org"})
    check(f"{kind}: explicit override wins", org, "override-org")

    # An SLX generated before the org-gated rule: no indexed org payload. Must
    # degrade to the source gcp-tags.yaml uses, NOT raise UndefinedError.
    org, _, _ = render(kind, match_resource={"qualified_name": "q"})
    check(f"{kind}: no indexed payload degrades to qualifiers.resource",
          org, "test-org")

    # Nothing resolvable anywhere. The value may be empty, but it must never be
    # CustomUndefined's placeholder -- that string would land in task titles.
    org, _, _ = render(kind, match_resource={"qualified_name": "q"}, qualifiers={})
    check(f"{kind}: placeholder never leaks into a config value",
          "missing_workspaceInfo" in str(org), False)

print("\n== org anchoring ==")
_, doc, _ = render("slx")
check("alias names the org", "test-org" in doc["spec"]["alias"], True)
check("scope tag is the organization",
      {t["name"]: t["value"] for t in doc["spec"]["tags"]}.get("scope"), "organization")
_, doc, _ = render("taskset")
check("taskset description names the org",
      "test-org" in doc["spec"]["description"], True)

print(f"\n  {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
