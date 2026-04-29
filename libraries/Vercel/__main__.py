"""CLI for the Vercel library: ``python -m Vercel <subcommand> [...]``.

Bundle bash scripts call this instead of curl/jq for Vercel REST operations.
Each subcommand writes JSON to ``--out`` (or stdout) and exits non-zero on error.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from typing import Optional, Sequence

from .vercel import (
    VercelClient,
    VercelError,
    normalize_vercel_events,
    normalize_vercel_request_log_rows,
    normalize_vercel_runtime_rows,
)

logger = logging.getLogger("vercel.cli")


def _emit(args: argparse.Namespace, payload) -> None:
    """Write JSON to ``args.out`` (path or '-' for stdout)."""
    if args.out and args.out != "-":
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
            fh.write("\n")
    else:
        json.dump(payload, sys.stdout)
        sys.stdout.write("\n")


def _fail(args: argparse.Namespace, exc: VercelError, what: str) -> int:
    detail = exc.to_dict()
    sys.stderr.write(f"[vercel] {what}: {detail['message']}\n")
    if args.error_out:
        with open(args.error_out, "w", encoding="utf-8") as fh:
            json.dump(detail, fh)
            fh.write("\n")
    return 2 if exc.invalid_token else 1


def cmd_resolve_project_id(args: argparse.Namespace) -> int:
    try:
        result = VercelClient().resolve_project_id(args.project_id)
    except VercelError as exc:
        return _fail(args, exc, "resolve-project-id")
    _emit(args, result)
    return 0


def cmd_get_project(args: argparse.Namespace) -> int:
    try:
        result = VercelClient().get_project(args.project_id)
    except VercelError as exc:
        return _fail(args, exc, "get-project")
    _emit(args, result)
    return 0


def cmd_list_project_domains(args: argparse.Namespace) -> int:
    try:
        result = VercelClient().list_project_domains(
            args.project_id, production_only=args.production_only
        )
    except VercelError as exc:
        return _fail(args, exc, "list-project-domains")
    _emit(args, result)
    return 0


def cmd_get_deployment(args: argparse.Namespace) -> int:
    try:
        result = VercelClient().get_deployment(args.deployment_id)
    except VercelError as exc:
        return _fail(args, exc, "get-deployment")
    _emit(args, result)
    return 0


def cmd_list_deployments(args: argparse.Namespace) -> int:
    try:
        target = args.target if args.target in ("production", "preview") else None
        result = VercelClient().list_deployments(
            args.project_id,
            target=target,
            page_limit=args.page_limit,
            max_pages=args.max_pages,
        )
    except VercelError as exc:
        return _fail(args, exc, "list-deployments")
    _emit(args, result)
    return 0


def cmd_select_deployments(args: argparse.Namespace) -> int:
    with open(args.input, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    deps = data.get("deployments", []) if isinstance(data, dict) else (data or [])
    ids = VercelClient.select_deployments_for_window(
        deps,
        int(args.window_start_ms),
        int(args.window_end_ms),
        environment=args.environment,
        max_results=args.max_results,
    )
    _emit(args, {"deployment_ids": ids})
    return 0


def cmd_deployment_events(args: argparse.Namespace) -> int:
    try:
        events = VercelClient().deployment_events(
            args.deployment_id,
            since_ms=args.since_ms or None,
            until_ms=args.until_ms or None,
            limit=args.limit,
        )
    except VercelError as exc:
        return _fail(args, exc, "deployment-events")
    if args.normalize:
        events = [
            normalized
            for ev in events
            if (normalized := VercelClient.normalize_event(ev)) is not None
        ]
    _emit(args, events)
    return 0


def cmd_normalize_events(args: argparse.Namespace) -> int:
    out = normalize_vercel_events(args.input)
    _emit(args, out)
    return 0


def cmd_runtime_logs(args: argparse.Namespace) -> int:
    try:
        rows = VercelClient().runtime_logs(
            args.project_id,
            args.deployment_id,
            max_seconds=args.max_seconds,
            max_rows=args.max_rows,
            since_ms=args.since_ms or None,
            until_ms=args.until_ms or None,
            only_request_rows=not args.include_non_request,
        )
    except VercelError as exc:
        return _fail(args, exc, "runtime-logs")
    if args.normalize:
        rows = [
            n
            for r in rows
            if (n := VercelClient.normalize_runtime_row(r)) is not None
        ]
    _emit(args, rows)
    return 0


def cmd_normalize_runtime_rows(args: argparse.Namespace) -> int:
    out = normalize_vercel_runtime_rows(args.input)
    _emit(args, out)
    return 0


def cmd_request_logs(args: argparse.Namespace) -> int:
    sources = (
        [s.strip() for s in args.source.split(",") if s.strip()] if args.source else None
    )
    levels = (
        [s.strip() for s in args.level.split(",") if s.strip()] if args.level else None
    )
    try:
        rows = VercelClient().request_logs(
            args.project_id,
            args.owner_id,
            since_ms=int(args.since_ms),
            until_ms=int(args.until_ms),
            environment=args.environment or None,
            status_code=str(args.status_code) if args.status_code else None,
            source=sources,
            level=levels,
            deployment_id=args.deployment_id or None,
            branch=args.branch or None,
            max_rows=args.max_rows,
            max_pages=args.max_pages,
        )
    except VercelError as exc:
        return _fail(args, exc, "request-logs")
    if args.normalize:
        rows = [
            n
            for r in rows
            if (n := VercelClient.normalize_request_log_row(r)) is not None
        ]
    _emit(args, rows)
    return 0


def cmd_normalize_request_log_rows(args: argparse.Namespace) -> int:
    out = normalize_vercel_request_log_rows(args.input)
    _emit(args, out)
    return 0


def _common_parent() -> argparse.ArgumentParser:
    """Common ``--out`` / ``--error-out`` / ``-v`` available on every subcommand."""
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument(
        "--out",
        default="-",
        help="Path to write JSON output (default '-' = stdout).",
    )
    p.add_argument(
        "--error-out",
        default="",
        help="Optional path to write a structured error JSON on failure.",
    )
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def build_parser() -> argparse.ArgumentParser:
    common = _common_parent()
    parser = argparse.ArgumentParser(
        prog="python -m Vercel",
        description="Vercel REST API helpers for codebundles.",
        parents=[common],
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser(
        "resolve-project-id",
        help="Resolve project slug → prj_… id.",
        parents=[common],
    )
    sp.add_argument("--project-id", required=True)
    sp.set_defaults(func=cmd_resolve_project_id)

    sp = sub.add_parser(
        "get-project",
        help="GET /v9/projects/{idOrName}.",
        parents=[common],
    )
    sp.add_argument("--project-id", required=True)
    sp.set_defaults(func=cmd_get_project)

    sp = sub.add_parser(
        "list-project-domains",
        help="GET /v9/projects/{id}/domains. Pass --production-only to drop branch + custom-environment domains.",
        parents=[common],
    )
    sp.add_argument("--project-id", required=True)
    sp.add_argument(
        "--production-only",
        action="store_true",
        help="Drop preview-branch (gitBranch) and custom-environment domains so only production-bound hostnames remain.",
    )
    sp.set_defaults(func=cmd_list_project_domains)

    sp = sub.add_parser(
        "get-deployment",
        help="GET /v13/deployments/{idOrUrl}. Returns the full deployment record (errorMessage, errorCode, aliasError, regions, meta).",
        parents=[common],
    )
    sp.add_argument("--deployment-id", required=True, dest="deployment_id")
    sp.set_defaults(func=cmd_get_deployment)

    sp = sub.add_parser(
        "list-deployments",
        help="GET /v6/deployments paginated.",
        parents=[common],
    )
    sp.add_argument("--project-id", required=True)
    sp.add_argument(
        "--target",
        default="",
        help="production|preview|all (empty/all = no target filter).",
    )
    sp.add_argument("--page-limit", type=int, default=None)
    sp.add_argument("--max-pages", type=int, default=None)
    sp.set_defaults(func=cmd_list_deployments)

    sp = sub.add_parser(
        "select-deployments-for-window",
        help="Pick deployment uids overlapping a [start,end] ms window.",
        parents=[common],
    )
    sp.add_argument("--input", required=True, help="Path to list-deployments JSON.")
    sp.add_argument("--window-start-ms", required=True)
    sp.add_argument("--window-end-ms", required=True)
    sp.add_argument("--environment", default="production")
    sp.add_argument("--max-results", type=int, default=10)
    sp.set_defaults(func=cmd_select_deployments)

    sp = sub.add_parser(
        "deployment-events",
        help="GET /v3/deployments/{id}/events. Use --normalize to keep only HTTP rows.",
        parents=[common],
    )
    sp.add_argument("--deployment-id", required=True, dest="deployment_id")
    sp.add_argument("--since-ms", type=int, default=0, dest="since_ms")
    sp.add_argument("--until-ms", type=int, default=0, dest="until_ms")
    sp.add_argument("--limit", type=int, default=10000)
    sp.add_argument(
        "--normalize",
        action="store_true",
        help="Reduce to {ts,code,path,method} rows (drops non-HTTP events).",
    )
    sp.set_defaults(func=cmd_deployment_events)

    sp = sub.add_parser(
        "normalize-events",
        help="Transform a deployment-events JSON file to normalized HTTP rows.",
        parents=[common],
    )
    sp.add_argument("--input", required=True)
    sp.set_defaults(func=cmd_normalize_events)

    sp = sub.add_parser(
        "runtime-logs",
        help=(
            "Stream GET /v1/projects/{pid}/deployments/{depid}/runtime-logs "
            "(NDJSON). Same data the `vercel logs` CLI uses; available on every plan."
        ),
        parents=[common],
    )
    sp.add_argument("--project-id", required=True, dest="project_id")
    sp.add_argument("--deployment-id", required=True, dest="deployment_id")
    sp.add_argument(
        "--max-seconds",
        type=float,
        default=25.0,
        help="Wall-clock cap on the streaming read (the endpoint may stay open until it sends a delimiter row).",
    )
    sp.add_argument(
        "--max-rows",
        type=int,
        default=2000,
        help="Cap on rows returned per deployment.",
    )
    sp.add_argument("--since-ms", type=int, default=0, dest="since_ms")
    sp.add_argument("--until-ms", type=int, default=0, dest="until_ms")
    sp.add_argument(
        "--include-non-request",
        action="store_true",
        help="Keep rows without a requestPath (function stdout, delimiters, etc.).",
    )
    sp.add_argument(
        "--normalize",
        action="store_true",
        help="Reduce to {ts,code,path,method,source,domain,level} HTTP rows.",
    )
    sp.set_defaults(func=cmd_runtime_logs)

    sp = sub.add_parser(
        "normalize-runtime-rows",
        help="Transform a runtime-logs JSON file to normalized HTTP rows.",
        parents=[common],
    )
    sp.add_argument("--input", required=True)
    sp.set_defaults(func=cmd_normalize_runtime_rows)

    sp = sub.add_parser(
        "request-logs",
        help=(
            "GET https://vercel.com/api/logs/request-logs (paginated, historical). "
            "The dashboard's Logs page and `vercel logs` v2 use this endpoint. "
            "Supports time-range queries via --since-ms / --until-ms, plus "
            "server-side filtering by environment, statusCode, source, deploymentId, branch."
        ),
        parents=[common],
    )
    sp.add_argument("--project-id", required=True, dest="project_id",
                    help="Vercel project id (prj_...).")
    sp.add_argument("--owner-id", required=True, dest="owner_id",
                    help="Project's accountId — team_... for team projects, user_... for personal.")
    sp.add_argument("--since-ms", type=int, required=True, dest="since_ms",
                    help="Lookback window start in ms epoch.")
    sp.add_argument("--until-ms", type=int, required=True, dest="until_ms",
                    help="Lookback window end in ms epoch.")
    sp.add_argument("--environment", default="", help="production | preview | (empty = all).")
    sp.add_argument("--status-code", default="", dest="status_code",
                    help="Single status code, or codes the dashboard supports server-side.")
    sp.add_argument("--source", default="",
                    help="Comma-separated: serverless,edge-function,edge-middleware,static.")
    sp.add_argument("--level", default="",
                    help="Comma-separated: info,warning,error,fatal.")
    sp.add_argument("--deployment-id", default="", dest="deployment_id")
    sp.add_argument("--branch", default="")
    sp.add_argument("--max-rows", type=int, default=5000,
                    help="Stop after collecting this many rows total.")
    sp.add_argument("--max-pages", type=int, default=20,
                    help="Stop after walking this many pages even if hasMoreRows is true.")
    sp.add_argument(
        "--normalize",
        action="store_true",
        help="Reduce each row to {ts,code,path,method,source,domain,level,deployment_id,branch,...}.",
    )
    sp.set_defaults(func=cmd_request_logs)

    sp = sub.add_parser(
        "normalize-request-log-rows",
        help="Transform a request-logs JSON file to normalized HTTP rows.",
        parents=[common],
    )
    sp.add_argument("--input", required=True)
    sp.set_defaults(func=cmd_normalize_request_log_rows)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="[%(name)s] %(levelname)s %(message)s",
    )
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
