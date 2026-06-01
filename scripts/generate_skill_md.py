#!/usr/bin/env python3
"""Generate SKILL-TEMPLATE.md manifests for CodeBundles from runbook.robot / sli.robot."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

OUTPUT_FILENAME = "SKILL-TEMPLATE.md"
LEGACY_FILENAME = "SKILL.md"


@dataclass
class ImportField:
    name: str
    kind: str  # "variable" | "secret"
    type_: str = "string"
    description: str = ""
    default: str | None = None

    @property
    def required(self) -> bool:
        if self.kind == "secret":
            return True
        return self.default is None or self.default == ""


@dataclass
class RobotTask:
    name: str
    robot_file: str
    documentation: str = ""
    tags: list[str] = field(default_factory=list)
    bash_file: str | None = None
    sub_metric: str | None = None
    pass_condition: str | None = None
    json_writes: list[str] = field(default_factory=list)
    env_reads: set[str] = field(default_factory=set)


@dataclass
class RobotFile:
    path: Path
    documentation: str = ""
    display_name: str = ""
    supports: list[str] = field(default_factory=list)
    tasks: list[RobotTask] = field(default_factory=list)
    imports: list[ImportField] = field(default_factory=list)


SECTION_RE = re.compile(r"^\*\*\* (.+?) \*\*\*$")
METADATA_RE = re.compile(r"^Metadata\s+(\S+)\s+(.*)$")
DOC_LINE_RE = re.compile(r"^\s+\[Documentation\]\s+(.*)$")
TAGS_RE = re.compile(r"^\s+\[Tags\]\s+(.*)$")
BASH_FILE_RE = re.compile(r"^\s+\.\.\.\s+bash_file=([^\s]+)")
SUB_NAME_RE = re.compile(r"RW\.Core\.Push Metric.*sub_name=([^\s\]]+)")
PASS_EVAL_RE = re.compile(
    r"\$\{[^}]+\}=\s+Evaluate\s+1 if (.+?) else 0", re.IGNORECASE
)
CAT_JSON_RE = re.compile(r"cat\s+([a-zA-Z0-9_.-]+\.json)")
ENV_VAR_RE = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
IMPORT_VAR_RE = re.compile(r"RW\.Core\.Import User Variable\s+(\S+)")
IMPORT_SECRET_RE = re.compile(r"RW\.Core\.Import Secret\s+(\S+)")
CONTINUATION_KV = re.compile(r"^\s+\.\.\.\s+(\w+)=(.*)$")


def _split_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current = "_preamble"
    sections[current] = []
    for line in text.splitlines():
        m = SECTION_RE.match(line.strip())
        if m:
            current = m.group(1)
            sections.setdefault(current, [])
        else:
            sections.setdefault(current, []).append(line)
    return sections


def _parse_settings(lines: list[str]) -> tuple[str, str, list[str]]:
    documentation = ""
    display_name = ""
    supports: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("Documentation"):
            documentation = stripped.split("Documentation", 1)[-1].strip()
            continue
        if not stripped.startswith("Metadata"):
            continue
        rest = stripped[len("Metadata") :].strip()
        if rest.startswith("Display Name"):
            display_name = rest[len("Display Name") :].strip()
        elif rest.startswith("Supports"):
            raw = rest[len("Supports") :].strip()
            if "," in raw:
                supports = [s.strip() for s in raw.split(",") if s.strip()]
            else:
                supports = [s for s in raw.split() if s]
    return documentation, display_name, supports


def _parse_import_blocks(lines: list[str]) -> list[ImportField]:
    imports: list[ImportField] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        var_m = IMPORT_VAR_RE.search(line)
        sec_m = IMPORT_SECRET_RE.search(line)
        if not var_m and not sec_m:
            i += 1
            continue
        name = (var_m or sec_m).group(1)
        kind = "variable" if var_m else "secret"
        type_ = "string"
        description = ""
        default: str | None = None
        i += 1
        while i < len(lines):
            cont = CONTINUATION_KV.match(lines[i])
            if not cont:
                break
            key, val = cont.group(1), cont.group(2).strip()
            if key == "type":
                type_ = val
            elif key == "description":
                description = val
            elif key == "default":
                default = val
            i += 1
        imports.append(
            ImportField(
                name=name,
                kind=kind,
                type_=type_,
                description=description,
                default=default,
            )
        )
    return imports


def _parse_tasks(lines: list[str], robot_file: str) -> list[RobotTask]:
    tasks: list[RobotTask] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if (
            not stripped
            or stripped.startswith("[")
            or stripped.startswith("IF")
            or stripped.startswith("FOR")
            or stripped.startswith("END")
            or stripped.startswith("${")
            or stripped.startswith("...")
            or stripped.startswith("#")
            or stripped.startswith("RW.")
            or stripped.startswith("Run ")
            or stripped.startswith("Log")
            or stripped.startswith("Set ")
            or stripped.startswith("RETURN")
        ):
            i += 1
            continue
        if line.startswith(" ") or line.startswith("\t"):
            i += 1
            continue
        if SECTION_RE.match(stripped):
            i += 1
            continue

        task_name = stripped
        doc = ""
        tags: list[str] = []
        bash_file: str | None = None
        sub_metric: str | None = None
        pass_condition: str | None = None
        json_writes: list[str] = []
        env_reads: set[str] = set()
        i += 1
        block: list[str] = []
        while i < len(lines):
            nxt = lines[i]
            if (
                nxt.strip()
                and not nxt.startswith(" ")
                and not nxt.startswith("\t")
                and not SECTION_RE.match(nxt.strip())
                and not nxt.strip().startswith("[")
            ):
                break
            block.append(nxt)
            i += 1

        block_text = "\n".join(block)
        for bline in block:
            dm = DOC_LINE_RE.match(bline)
            if dm:
                doc = dm.group(1).strip()
            tm = TAGS_RE.match(bline)
            if tm:
                tags = [t.strip() for t in tm.group(1).split() if t.strip()]
            bm = BASH_FILE_RE.match(bline)
            if bm:
                bash_file = bm.group(1)
            pm = PASS_EVAL_RE.search(bline)
            if pm:
                pass_condition = pm.group(1).strip()
            for jm in CAT_JSON_RE.findall(bline):
                if jm not in json_writes:
                    json_writes.append(jm)
            env_reads.update(ENV_VAR_RE.findall(bline))
        sm = SUB_NAME_RE.search(block_text)
        if sm:
            sub_metric = sm.group(1)

        tasks.append(
            RobotTask(
                name=task_name,
                robot_file=robot_file,
                documentation=doc,
                tags=tags,
                bash_file=bash_file,
                sub_metric=sub_metric,
                pass_condition=pass_condition,
                json_writes=json_writes,
                env_reads=env_reads,
            )
        )
    return tasks


def parse_robot(path: Path) -> RobotFile:
    text = path.read_text(encoding="utf-8", errors="replace")
    sections = _split_sections(text)
    settings = sections.get("Settings", [])
    doc, display, supports = _parse_settings(settings)
    keywords = sections.get("Keywords", [])
    tasks_lines = sections.get("Tasks", [])
    imports = _parse_import_blocks(keywords + settings)
    tasks = _parse_tasks(tasks_lines, path.name)
    return RobotFile(
        path=path,
        documentation=doc,
        display_name=display,
        supports=supports,
        tasks=tasks,
        imports=imports,
    )


def _infer_resource_types(bundle_name: str, supports: list[str]) -> list[str]:
    name = bundle_name.lower()
    mapping = [
        ("aks", "aks_cluster"),
        ("eks", "eks_cluster"),
        ("gke", "gke_cluster"),
        ("deployment", "deployment"),
        ("namespace", "namespace"),
        ("ingress", "ingress"),
        ("statefulset", "statefulset"),
        ("daemonset", "daemonset"),
        ("pvc", "persistent_volume_claim"),
        ("pod", "pod"),
        ("lambda", "lambda_function"),
        ("sqs", "sqs_queue"),
        ("elasticache", "elasticache_cluster"),
        ("s3", "s3_bucket"),
        ("ec2", "ec2_instance"),
        ("keyvault", "key_vault"),
        ("key-vault", "key_vault"),
        ("kv-", "key_vault"),
        ("appservice", "app_service"),
        ("appgateway", "application_gateway"),
        ("loadbalancer", "load_balancer"),
        ("servicebus", "service_bus"),
        ("storage", "storage_account"),
        ("acr", "container_registry"),
        ("adf", "data_factory"),
        ("databricks", "databricks_workspace"),
        ("devops", "azure_devops"),
        ("subscription", "subscription"),
        ("vm-", "virtual_machine"),
        ("virtual-machine", "virtual_machine"),
    ]
    found: list[str] = []
    for needle, rtype in mapping:
        if needle in name and rtype not in found:
            found.append(rtype)
    if not found:
        if any(p.lower() in ("kubernetes", "aks", "eks", "gke", "openshift") for p in supports):
            found.append("kubernetes_resource")
        elif any(p.lower() == "azure" for p in supports):
            found.append("azure_resource")
        elif any(p.lower() == "aws" for p in supports):
            found.append("aws_resource")
        elif any(p.lower() == "gcp" for p in supports):
            found.append("gcp_resource")
    return found[:3]


def _infer_access(all_tags: list[list[str]]) -> str:
    flat = [t for tags in all_tags for t in tags]
    if not flat:
        return "read-only"
    if any("access:read-write" in t or "access:write" in t for t in flat):
        return "read-write"
    if any("access:read-only" in t for t in flat):
        return "read-only"
    return "read-write" if any("write" in t.lower() for t in flat) else "read-only"


def _readme_summary(readme: Path) -> str:
    if not readme.exists():
        return ""
    lines = readme.read_text(encoding="utf-8", errors="replace").splitlines()
    body: list[str] = []
    for line in lines:
        if line.startswith("#"):
            continue
        if line.strip():
            body.append(line.strip())
        if len(body) >= 2:
            break
    return " ".join(body)[:500]


def _build_description(
    bundle_name: str,
    display_name: str,
    robot_doc: str,
    readme_summary: str,
    supports: list[str],
) -> str:
    base = robot_doc or (readme_summary[:120] if readme_summary else "") or display_name
    base = re.sub(r"\s+", " ", base).strip()
    if len(base) > 120:
        base = base[:117].rsplit(" ", 1)[0] + "..."
    if base and not base.endswith("."):
        base += "."
    platform_hint = ", ".join(supports[:3]) if supports else "RunWhen"
    trigger = (
        f"Use when triaging or monitoring {platform_hint} workloads "
        f"with skill template `{bundle_name}`."
    )
    desc = f"{base} {trigger}".strip()
    if len(desc) > 200:
        desc = desc[:197] + "..."
    return desc


def _robot_name_field(task_name: str) -> str:
    escaped = task_name.replace("|", "\\|")
    return f'<code>{escaped}</code>'


def _dedupe_imports(imports: list[ImportField]) -> list[ImportField]:
    seen: set[str] = set()
    out: list[ImportField] = []
    for imp in imports:
        if imp.name in seen:
            continue
        seen.add(imp.name)
        out.append(imp)
    return out


def _collect_json_outputs(runbook: RobotFile | None, monitor: RobotFile | None) -> list[str]:
    files: list[str] = []
    for rf in (runbook, monitor):
        if not rf:
            continue
        for task in rf.tasks:
            for j in task.json_writes:
                if j not in files:
                    files.append(j)
    return files


def _list_shell_scripts(bundle_dir: Path) -> list[Path]:
    return sorted(
        p
        for p in bundle_dir.iterdir()
        if p.is_file()
        and p.suffix == ".sh"
        and p.name != "auth.sh"
    )


def _script_purpose(name: str) -> str:
    return f"Bash helper script `{name}`."


def _format_tool(task: RobotTask, import_names: set[str]) -> str:
    reads = sorted(task.env_reads & import_names) or sorted(task.env_reads)
    writes = ", ".join(f"`{j}`" for j in task.json_writes) or "—"
    tags = ", ".join(f"`{t}`" for t in task.tags) or "—"
    script_line = (
        f"- **Underlying script**: `{task.bash_file}`\n"
        if task.bash_file
        else ""
    )
    return (
        f"### {task.name}\n\n"
        f"{task.documentation or '_No task documentation in Robot source._'}\n\n"
        f"- **Robot task name**: {_robot_name_field(task.name)}\n"
        f"- **Robot file**: `{task.robot_file}`\n"
        f"{script_line}"
        f"- **Tags**: {tags}\n"
        f"- **Reads**: {', '.join(f'`{r}`' for r in reads) or '—'}\n"
        f"- **Writes**: {writes}\n"
        f"- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail\n"
    )


def _format_monitor_subcheck(task: RobotTask, import_names: set[str]) -> str:
    reads = sorted(task.env_reads & import_names) or sorted(task.env_reads)
    tags = ", ".join(f"`{t}`" for t in task.tags) or "—"
    script_line = (
        f"- **Underlying script**: `{task.bash_file}`\n"
        if task.bash_file
        else ""
    )
    pass_line = (
        f"- **Pass condition**: `{task.pass_condition}`\n"
        if task.pass_condition
        else ""
    )
    sub = task.sub_metric or "—"
    return (
        f"#### {task.name}\n\n"
        f"{task.documentation or '_No sub-check documentation in Robot source._'}\n\n"
        f"- **Robot task name**: {_robot_name_field(task.name)}\n"
        f"- **Sub-metric name**: `{sub}`\n"
        f"{script_line}"
        f"- **Tags**: {tags}\n"
        f"- **Reads**: {', '.join(f'`{r}`' for r in reads) or '—'}\n"
        f"{pass_line}"
    )


def generate_skill_md(bundle_dir: Path) -> str | None:
    bundle_name = bundle_dir.name
    runbook_path = bundle_dir / "runbook.robot"
    monitor_path = bundle_dir / "sli.robot"

    if not runbook_path.exists() and not monitor_path.exists():
        return None

    runbook = parse_robot(runbook_path) if runbook_path.exists() else None
    monitor = parse_robot(monitor_path) if monitor_path.exists() else None

    display_name = (
        (runbook.display_name if runbook else "")
        or (monitor.display_name if monitor else "")
        or bundle_name.replace("-", " ").title()
    )
    supports = (runbook.supports if runbook else []) or (
        monitor.supports if monitor else []
    )
    robot_doc = (runbook.documentation if runbook else "") or (
        monitor.documentation if monitor else ""
    )
    readme_summary = _readme_summary(bundle_dir / "README.md")
    if readme_summary and len(readme_summary) > 400:
        readme_summary = readme_summary[:397].rsplit(" ", 1)[0] + "..."
    description = _build_description(
        bundle_name, display_name, robot_doc, readme_summary, supports
    )

    all_imports = _dedupe_imports(
        (runbook.imports if runbook else []) + (monitor.imports if monitor else [])
    )
    import_names = {i.name for i in all_imports}

    all_tags: list[list[str]] = []
    if runbook:
        all_tags.extend(t.tags for t in runbook.tasks)
    if monitor:
        all_tags.extend(t.tags for t in monitor.tasks)

    platforms = supports or ["RunWhen"]
    resource_types = _infer_resource_types(bundle_name, supports)
    access = _infer_access(all_tags)

    lines: list[str] = [
        "---",
        f"name: {bundle_name}",
        "kind: skill-template",
        f"description: {description}",
        "runtime:",
    ]
    if runbook_path.exists():
        lines.append("  runbook: runbook.robot")
    if monitor_path.exists():
        lines.append("  monitor: sli.robot")
    lines.extend(
        [
            "  runner: ro",
            f"platforms: [{', '.join(platforms)}]",
            f"resource_types: [{', '.join(resource_types)}]",
            f"access: {access}",
            "---",
            "",
            f"# {display_name}",
            "",
            "## Summary",
            "",
            (readme_summary.split(". ")[0] + "." if readme_summary else "")
            or robot_doc
            or f"Skill template `{bundle_name}` for RunWhen agents.",
            "",
            "See [README.md](README.md) for additional context.",
            "",
        ]
    )

    if runbook and runbook.tasks:
        lines.append("## Tools")
        lines.append("")
        for task in runbook.tasks:
            lines.append(_format_tool(task, import_names))
            lines.append("")

    if monitor:
        lines.extend(["## Monitor", ""])
        if monitor.documentation:
            lines.append(monitor.documentation)
            lines.append("")
        lines.extend(
            [
                "- **Robot file**: `sli.robot`",
                "- **Score range**: `0.0` (failing) to `1.0` (healthy)",
                "- **Aggregation**: arithmetic mean of the sub-checks below",
                "- **Recommended interval**: `180s`",
                "",
                "### Sub-checks",
                "",
            ]
        )
        subchecks = [
            t
            for t in monitor.tasks
            if t.sub_metric or "Push Metric" in " ".join([t.documentation, t.name])
        ]
        if not subchecks:
            subchecks = [
                t
                for t in monitor.tasks
                if t.documentation or t.tags or t.bash_file
            ]
        for task in subchecks:
            if not task.sub_metric:
                # skip aggregate score task (no sub_name)
                if "Generate" in task.name and "Score" in task.name:
                    continue
            lines.append(_format_monitor_subcheck(task, import_names))
            lines.append("")
        if not subchecks:
            lines.append(
                "_Monitor tasks are defined in `sli.robot`; see source for sub-check details._\n"
            )

    lines.extend(["## Inputs", ""])
    if all_imports:
        lines.extend(
            [
                "| Name | Type | Description | Default | Required |",
                "|---|---|---|---|---|",
            ]
        )
        for imp in all_imports:
            if imp.kind != "variable":
                continue
            default = f"`{imp.default}`" if imp.default is not None else "—"
            req = "no" if not imp.required else "yes"
            desc = imp.description.replace("|", "\\|")
            lines.append(
                f"| `{imp.name}` | {imp.type_} | {desc} | {default} | {req} |"
            )
    else:
        lines.append("_No user variables imported in Robot source._")
    lines.append("")

    lines.extend(["## Secrets", ""])
    secrets = [i for i in all_imports if i.kind == "secret"]
    if secrets:
        lines.extend(
            ["| Name | Description | Required |", "|---|---|---|"]
        )
        for imp in secrets:
            desc = imp.description.replace("|", "\\|") or "—"
            lines.append(f"| `{imp.name}` | {desc} | yes |")
    else:
        lines.append("_No secrets imported in Robot source._")
    lines.append("")

    outputs = _collect_json_outputs(runbook, monitor)
    lines.extend(["## Outputs", ""])
    if monitor:
        lines.append("- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`")
    for j in outputs:
        lines.append(f"- `{j}`")
    if not outputs and not monitor:
        lines.append("_See Robot run output and platform report artifacts._")
    lines.append("")

    lines.extend(
        [
            "## How to invoke",
            "",
            "### Preferred: Robot Framework runner (`ro`)",
            "",
            "```bash",
            f"cd codebundles/{bundle_name}",
        ]
    )
    for imp in all_imports[:6]:
        if imp.kind == "variable":
            lines.append(f"export {imp.name}=...")
    if runbook_path.exists():
        lines.append("ro runbook.robot")
    elif monitor_path.exists():
        lines.append("ro sli.robot")
    lines.extend(["```", "", "### Standalone scripts (no Robot)", "", ""])
    scripts = _list_shell_scripts(bundle_dir)
    if scripts:
        lines.append(
            "Set the input variables above, then run the matching script:"
        )
        lines.append("")
        lines.append("```bash")
        lines.append(f"cd codebundles/{bundle_name}")
        for imp in all_imports[:4]:
            if imp.kind == "variable":
                lines.append(f"export {imp.name}=...")
        for script in scripts[:12]:
            lines.append(f"bash {script.name}")
        if len(scripts) > 12:
            lines.append(f"# ... and {len(scripts) - 12} more scripts")
        lines.append("```")
    else:
        lines.append("_No standalone shell scripts in this bundle._")
    lines.append("")

    lines.extend(["## Source files", ""])
    if runbook_path.exists():
        lines.append("- `runbook.robot` — orchestrates tools and raises issues")
    if monitor_path.exists():
        lines.append("- `sli.robot` — monitor scoring (`sli.robot` runtime file)")
    for script in scripts:
        lines.append(f"- `{script.name}` — {_script_purpose(script.name)}")
    lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "codecollection",
        type=Path,
        nargs="?",
        default=Path("/home/runwhen/codecollection"),
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--bundle", action="append", help="Only process named bundles")
    args = parser.parse_args()

    root = args.codecollection / "codebundles"
    if not root.is_dir():
        print(f"Not found: {root}", file=sys.stderr)
        return 1

    bundles = sorted(
        d for d in root.iterdir() if d.is_dir() and d.name != "CURSOR_RULES_README.md"
    )
    if args.bundle:
        names = set(args.bundle)
        bundles = [d for d in bundles if d.name in names]

    written = skipped = errors = 0
    for bundle_dir in bundles:
        try:
            content = generate_skill_md(bundle_dir)
            if content is None:
                skipped += 1
                continue
            out = bundle_dir / OUTPUT_FILENAME
            legacy = bundle_dir / LEGACY_FILENAME
            if args.dry_run:
                print(f"would write {out} ({len(content)} bytes)")
                if legacy.exists():
                    print(f"would remove legacy {legacy}")
            else:
                out.write_text(content, encoding="utf-8")
                if legacy.exists() and legacy != out:
                    legacy.unlink()
                print(f"wrote {out}")
            written += 1
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR {bundle_dir.name}: {exc}", file=sys.stderr)
            errors += 1

    print(f"\nDone: {written} written, {skipped} skipped, {errors} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
