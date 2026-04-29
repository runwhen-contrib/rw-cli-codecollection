"""Vercel — Vercel REST API client for codebundles.

Exposes a small set of operations as both Robot keywords (via ``Library Vercel``)
and as a CLI (``python -m Vercel <subcommand>``). Bundle bash scripts use the CLI.

Endpoints used (current per https://vercel.com/docs/rest-api):
  GET https://api.vercel.com/v6/deployments                          — list deployments
  GET https://api.vercel.com/v9/projects/{idOrName}                  — find project by id or slug
  GET https://api.vercel.com/v9/projects                             — list projects (slug fallback)
  GET https://api.vercel.com/v3/deployments/{idOrUrl}/events         — deployment build events
  GET https://api.vercel.com/v1/projects/{pid}/deployments/{depid}/runtime-logs
                                                                     — live-tail runtime/access logs (NDJSON, no historical)
  GET https://vercel.com/api/logs/request-logs                       — historical request logs (paginated, dashboard-backing)

Note on the request-logs endpoint: It is not in the public REST API reference
but is the same one Vercel's dashboard "Logs" page and the `vercel logs` CLI
v2 (logs-v2.ts on main) call. Hosted on https://vercel.com (not api.vercel.com).
Same Bearer-token auth. Stable enough that the official CLI ships with it on
``main``, but technically undocumented and subject to change.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from typing import Any, Iterator, List, Optional
from urllib.parse import quote

import requests
from requests.adapters import HTTPAdapter

try:
    from urllib3.util.retry import Retry
except ImportError:  # pragma: no cover
    from urllib3 import Retry  # type: ignore

logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"

VERCEL_API_DEFAULT = "https://api.vercel.com"
VERCEL_DASHBOARD_API_DEFAULT = "https://vercel.com"


def _token_value() -> str:
    """Read token from VERCEL_TOKEN or Robot secret env (vercel_token)."""
    return os.environ.get("VERCEL_TOKEN") or os.environ.get("vercel_token") or ""


@dataclass
class VercelConfig:
    """Runtime configuration. Reads tunables from the standard Vercel env vars."""

    token: str
    api: str = VERCEL_API_DEFAULT
    dashboard_api: str = VERCEL_DASHBOARD_API_DEFAULT
    team_id: Optional[str] = None
    timeout: int = 90
    retry_attempts: int = 4
    page_limit: int = 50
    max_pages: int = 20

    runtime_logs_max_seconds: float = 25.0
    runtime_logs_max_rows: int = 2000

    request_logs_max_pages: int = 20
    request_logs_max_rows: int = 5000
    request_logs_timeout: int = 30

    @classmethod
    def from_env(cls) -> "VercelConfig":
        return cls(
            token=_token_value(),
            api=os.environ.get("VERCEL_API", VERCEL_API_DEFAULT),
            dashboard_api=os.environ.get(
                "VERCEL_DASHBOARD_API", VERCEL_DASHBOARD_API_DEFAULT
            ),
            team_id=os.environ.get("VERCEL_TEAM_ID") or None,
            timeout=int(os.environ.get("VERCEL_PAGE_MAX_TIME", "90")),
            retry_attempts=int(os.environ.get("VERCEL_PAGE_RETRY_ATTEMPTS", "4")),
            page_limit=int(os.environ.get("VERCEL_DEPLOYMENTS_PAGE_LIMIT", "50")),
            max_pages=int(os.environ.get("VERCEL_DEPLOYMENTS_MAX_PAGES", "20")),
            runtime_logs_max_seconds=float(
                os.environ.get("VERCEL_RUNTIME_LOGS_MAX_SECONDS", "25")
            ),
            runtime_logs_max_rows=int(
                os.environ.get("VERCEL_RUNTIME_LOGS_MAX_ROWS", "2000")
            ),
            request_logs_max_pages=int(
                os.environ.get("VERCEL_REQUEST_LOGS_MAX_PAGES", "20")
            ),
            request_logs_max_rows=int(
                os.environ.get("VERCEL_REQUEST_LOGS_MAX_ROWS", "5000")
            ),
            request_logs_timeout=int(
                os.environ.get("VERCEL_REQUEST_LOGS_TIMEOUT", "30")
            ),
        )


class VercelError(Exception):
    """API error with status code, body, and an `invalid_token` hint."""

    def __init__(
        self,
        message: str,
        *,
        http_code: Any = None,
        body: str = "",
        invalid_token: bool = False,
    ):
        super().__init__(message)
        self.http_code = str(http_code) if http_code is not None else "unknown"
        self.body = body or ""
        self.invalid_token = invalid_token

    def to_dict(self) -> dict:
        return {
            "message": str(self),
            "http_code": self.http_code,
            "body": self.body[:1500],
            "invalid_token": self.invalid_token,
        }


class VercelClient:
    """Thin wrapper around the Vercel REST API. HTTP/1.1, no keep-alive, urllib3 retries."""

    def __init__(self, config: Optional[VercelConfig] = None):
        self.config = config or VercelConfig.from_env()
        if not self.config.token:
            raise VercelError("VERCEL_TOKEN/vercel_token is not set")
        self.session = self._build_session()

    def _build_session(self) -> requests.Session:
        # urllib3 Retry handles transient 5xx + connection resets.
        retry = Retry(
            total=self.config.retry_attempts,
            backoff_factor=2,
            status_forcelist=(500, 502, 503, 504),
            allowed_methods=("GET",),
            raise_on_status=False,
        )
        adapter = HTTPAdapter(
            max_retries=retry,
            pool_connections=1,
            pool_maxsize=1,
        )
        s = requests.Session()
        s.mount("http://", adapter)
        s.mount("https://", adapter)
        s.headers.update(
            {
                "Authorization": f"Bearer {self.config.token}",
                "Accept": "application/json",
                "Accept-Encoding": "identity",
                "Connection": "close",
            }
        )
        return s

    def _team_param(self) -> dict:
        return {"teamId": self.config.team_id} if self.config.team_id else {}

    def _get(self, path: str, params: Optional[dict] = None) -> requests.Response:
        url = f"{self.config.api}{path}"
        merged: dict = {}
        merged.update(self._team_param())
        if params:
            merged.update(params)
        try:
            return self.session.get(url, params=merged, timeout=self.config.timeout)
        except requests.RequestException as exc:
            raise VercelError(f"GET {path} failed: {exc}", http_code="000") from exc

    @staticmethod
    def _detect_invalid_token(body: str) -> bool:
        if not body:
            return False
        try:
            data = json.loads(body)
            return bool(data.get("error", {}).get("invalidToken"))
        except (ValueError, AttributeError):
            return "invalidToken" in body

    def _raise_http_error(self, where: str, resp: requests.Response) -> None:
        body = resp.text[:1500] if resp.text else ""
        raise VercelError(
            f"{where} returned HTTP {resp.status_code}",
            http_code=resp.status_code,
            body=body,
            invalid_token=self._detect_invalid_token(body),
        )

    # -- projects -----------------------------------------------------------

    def get_project(self, id_or_name: str) -> dict:
        encoded = quote(id_or_name, safe="")
        r = self._get(f"/v9/projects/{encoded}")
        if r.status_code == 200:
            return r.json()
        self._raise_http_error(f"GET /v9/projects/{id_or_name}", r)
        return {}  # unreachable; satisfies type-checker

    def list_projects_paginated(self) -> Iterator[dict]:
        params: dict = {"limit": 100}
        for _ in range(20):
            r = self._get("/v9/projects", params=params)
            if r.status_code != 200:
                self._raise_http_error("GET /v9/projects", r)
            data = r.json()
            for p in data.get("projects", []):
                yield p
            nxt = data.get("pagination", {}).get("next")
            if not nxt:
                return
            params["until"] = nxt

    def resolve_project_id(self, raw: str) -> dict:
        """Return ``{id, name, resolved_from}``. ``resolved_from`` ∈ {id, name, list}."""
        if not raw:
            raise VercelError("project id/slug is empty")
        if raw.startswith("prj_"):
            return {"id": raw, "name": raw, "resolved_from": "id"}
        try:
            project = self.get_project(raw)
            if project.get("id"):
                return {
                    "id": project["id"],
                    "name": project.get("name") or raw,
                    "resolved_from": "name",
                }
        except VercelError as exc:
            if exc.invalid_token:
                raise
            logger.debug("get_project(%s) fell back to list: %s", raw, exc)
        for project in self.list_projects_paginated():
            name = (project.get("name") or "").lower()
            if name == raw.lower() or project.get("id") == raw:
                return {
                    "id": project["id"],
                    "name": project.get("name") or raw,
                    "resolved_from": "list",
                }
        raise VercelError(f"Project '{raw}' not found in /v9/projects")

    def list_project_domains(
        self,
        project_id: str,
        *,
        production_only: bool = False,
    ) -> List[dict]:
        """Return all domains attached to a project via ``GET /v9/projects/{id}/domains``.

        Each entry includes ``name``, ``apexName``, ``verified``, optional
        ``redirect`` / ``redirectStatusCode``, ``gitBranch`` (preview-bound
        domains), ``customEnvironmentId`` (custom-environment domains), and
        ``verification`` (the TXT/CNAME records the user must add when
        ``verified == false``).

        When ``production_only=True``, drops anything bound to a non-production
        target — branch-bound preview aliases (``gitBranch != null``) and
        custom-environment domains (``customEnvironmentId != null``) — leaving
        only the apex / canonical hostnames that should resolve in production.
        """
        encoded = quote(project_id, safe="")
        items: List[dict] = []
        params: dict = {"limit": 100}
        for _ in range(20):  # generous; most projects have < 10 domains
            r = self._get(f"/v9/projects/{encoded}/domains", params=params)
            if r.status_code != 200:
                self._raise_http_error(
                    f"GET /v9/projects/{project_id}/domains", r
                )
            try:
                data = r.json()
            except ValueError as exc:
                raise VercelError(
                    f"GET /v9/projects/{project_id}/domains returned non-JSON: {exc}",
                    http_code=r.status_code,
                    body=r.text[:1500],
                ) from exc
            items.extend(data.get("domains", []))
            nxt = data.get("pagination", {}).get("next") if isinstance(
                data.get("pagination"), dict
            ) else None
            if not nxt:
                break
            params["until"] = nxt
        if production_only:
            items = [
                d
                for d in items
                if not d.get("gitBranch") and not d.get("customEnvironmentId")
            ]
        return items

    # -- deployments --------------------------------------------------------

    def list_deployments(
        self,
        project_id: str,
        *,
        target: Optional[str] = None,
        page_limit: Optional[int] = None,
        max_pages: Optional[int] = None,
    ) -> dict:
        items: List[dict] = []
        params: dict = {
            "projectId": project_id,
            "limit": page_limit or self.config.page_limit,
        }
        if target in ("production", "preview"):
            params["target"] = target
        cap = max_pages or self.config.max_pages
        for _ in range(cap):
            r = self._get("/v6/deployments", params=params)
            if r.status_code != 200:
                self._raise_http_error("GET /v6/deployments", r)
            try:
                data = r.json()
            except ValueError:
                raise VercelError(
                    "GET /v6/deployments returned non-JSON",
                    http_code=r.status_code,
                    body=r.text[:1500],
                )
            items.extend(data.get("deployments", []))
            nxt = data.get("pagination", {}).get("next")
            if not nxt:
                break
            params["until"] = nxt
        return {"deployments": items}

    def get_deployment(self, deployment_id: str) -> dict:
        """Fetch a single deployment via ``GET /v13/deployments/{idOrUrl}``.

        Returns the full deployment record including ``readyState``,
        ``errorCode``, ``errorMessage``, ``aliasError``, ``aliasAssignedAt``,
        ``buildingAt``, ``ready``, ``regions``, ``meta``, and ``creator``.
        Used to enrich an ``ERROR``/``CANCELED`` entry from the deployments
        list with the actual build error reason.
        """
        if not deployment_id:
            raise VercelError("get_deployment: deployment_id is required")
        encoded = quote(deployment_id, safe="")
        r = self._get(f"/v13/deployments/{encoded}")
        if r.status_code == 200:
            try:
                return r.json()
            except ValueError as exc:
                raise VercelError(
                    f"GET /v13/deployments/{deployment_id} returned non-JSON: {exc}",
                    http_code=r.status_code,
                    body=r.text[:1500],
                ) from exc
        self._raise_http_error(f"GET /v13/deployments/{deployment_id}", r)
        return {}

    @staticmethod
    def select_deployments_for_window(
        deployments: List[dict],
        window_start_ms: int,
        window_end_ms: int,
        *,
        environment: str = "production",
        max_results: int = 10,
    ) -> List[str]:
        """Return uids of READY deployments whose active interval overlaps the window."""
        env = (environment or "production").lower()
        ready: List[dict] = []
        for d in deployments or []:
            ready_state = d.get("readyState") or d.get("state") or ""
            if ready_state != "READY":
                continue
            tgt = d.get("target") or "preview"
            if env == "production" and tgt != "production":
                continue
            if env == "preview" and tgt == "production":
                continue
            ready.append(d)

        def _start(d: dict) -> int:
            return int(d.get("createdAt") or d.get("created") or 0)

        ready.sort(key=_start)
        out: List[dict] = []
        for i, d in enumerate(ready):
            tgt = d.get("target") or "preview"
            start = _start(d)
            end = window_end_ms
            for j in range(i + 1, len(ready)):
                if (ready[j].get("target") or "preview") == tgt:
                    end = _start(ready[j]) or end
                    break
            if start < window_end_ms and end > window_start_ms:
                out.append({"uid": d.get("uid"), "start": start, "end": end})
        out.sort(key=lambda x: -x["start"])
        return [o["uid"] for o in out[:max_results] if o["uid"]]

    # -- events / runtime logs ---------------------------------------------

    def deployment_events(
        self,
        deployment_id: str,
        *,
        since_ms: Optional[int] = None,
        until_ms: Optional[int] = None,
        limit: int = 10000,
    ) -> List[dict]:
        params: dict = {
            "limit": limit,
            "direction": "backward",
            "builds": 0,
        }
        if since_ms is not None:
            params["since"] = since_ms
        if until_ms is not None:
            params["until"] = until_ms
        r = self._get(
            f"/v3/deployments/{quote(deployment_id, safe='')}/events",
            params=params,
        )
        if r.status_code != 200:
            self._raise_http_error(
                f"GET /v3/deployments/{deployment_id}/events", r
            )
        try:
            data = r.json()
        except ValueError:
            # The endpoint can return application/stream+json (NDJSON).
            data = []
            for line in r.text.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    data.append(json.loads(line))
                except ValueError:
                    continue
        if not isinstance(data, list):
            return []
        return data

    # -- runtime logs (HTTP/access logs) -----------------------------------

    def runtime_logs(
        self,
        project_id: str,
        deployment_id: str,
        *,
        max_seconds: Optional[float] = None,
        max_rows: Optional[int] = None,
        since_ms: Optional[int] = None,
        until_ms: Optional[int] = None,
        sources: Optional[List[str]] = None,
        only_request_rows: bool = True,
    ) -> List[dict]:
        """Stream the deployment's runtime logs (NDJSON) via
        ``GET /v1/projects/{pid}/deployments/{depid}/runtime-logs``.

        This is the same endpoint ``vercel logs`` uses; it returns up to
        roughly 24 hours of buffered request/function logs (3-day retention)
        for any plan and is the only public path to access HTTP request
        records by route. Each row carries ``requestPath``,
        ``requestMethod``, ``responseStatusCode``, ``timestampInMs``,
        ``domain``, ``source`` and ``level``.

        Termination conditions (any of):
        * ``max_rows`` rows collected.
        * ``max_seconds`` wall-clock elapsed (checked between read attempts;
          the read timeout below ensures we wake up frequently).
        * Server emits a row with ``source == "delimiter"`` (the documented
          schema enum value used as the end-of-buffer sentinel — without it,
          the endpoint stays open as if ``--follow`` were set).
        * Server closes the connection or the read times out.

        Server-side ``since``/``until``/``statusCode`` filtering is not
        supported by this endpoint, so it's done client-side here.
        """
        url = (
            f"{self.config.api}"
            f"/v1/projects/{quote(project_id, safe='')}"
            f"/deployments/{quote(deployment_id, safe='')}/runtime-logs"
        )
        params: dict = {}
        params.update(self._team_param())
        wall_max = float(
            max_seconds if max_seconds is not None else self.config.runtime_logs_max_seconds
        )
        deadline = time.monotonic() + wall_max
        # Short read timeout so iter_lines wakes up regularly and we can honour the wall-clock deadline.
        read_timeout = max(2.0, min(5.0, wall_max / 4.0))
        cap = int(max_rows if max_rows is not None else self.config.runtime_logs_max_rows)
        rows: List[dict] = []
        try:
            with self.session.get(
                url,
                params=params,
                stream=True,
                timeout=(15, read_timeout),
                headers={"Accept": "application/stream+json"},
            ) as resp:
                if resp.status_code != 200:
                    self._raise_http_error(
                        f"GET /v1/projects/{project_id}/deployments/{deployment_id}/runtime-logs",
                        resp,
                    )
                try:
                    for raw in resp.iter_lines(decode_unicode=True):
                        if time.monotonic() > deadline:
                            break
                        if not raw:
                            continue
                        line = raw.strip()
                        if not line:
                            continue
                        try:
                            row = json.loads(line)
                        except ValueError:
                            continue
                        if not isinstance(row, dict):
                            continue
                        # End-of-buffer sentinel emitted by the runtime-logs endpoint.
                        if row.get("source") == "delimiter":
                            break
                        if since_ms is not None or until_ms is not None:
                            ts_raw = row.get("timestampInMs")
                            try:
                                ts_int = int(ts_raw) if ts_raw is not None else None
                            except (TypeError, ValueError):
                                ts_int = None
                            if ts_int is None:
                                continue
                            if since_ms is not None and ts_int < since_ms:
                                continue
                            if until_ms is not None and ts_int > until_ms:
                                continue
                        if sources and row.get("source") not in sources:
                            continue
                        if only_request_rows and not row.get("requestPath"):
                            continue
                        rows.append(row)
                        if len(rows) >= cap:
                            break
                except (
                    requests.exceptions.ReadTimeout,
                    requests.exceptions.ChunkedEncodingError,
                    requests.exceptions.ConnectionError,
                ):
                    # Treat read-side hiccups as natural end-of-stream; we already collected what was buffered.
                    pass
        except requests.RequestException as exc:
            raise VercelError(
                f"runtime-logs stream failed for {deployment_id}: {exc}",
                http_code="000",
            ) from exc
        return rows

    @staticmethod
    def normalize_runtime_row(row: dict) -> Optional[dict]:
        """Reduce a runtime-logs row to ``{ts, code, path, method, source, domain, level}``.

        Returns ``None`` for rows missing a request path or status code
        (delimiters, function stdout without a request, etc.).
        """
        if not isinstance(row, dict):
            return None
        ts = row.get("timestampInMs")
        code = row.get("responseStatusCode")
        path = row.get("requestPath") or ""
        method = row.get("requestMethod") or "GET"
        try:
            ts_int = int(ts) if ts is not None else 0
            code_int = int(code) if code is not None else 0
        except (TypeError, ValueError):
            return None
        if not path or code_int <= 0:
            return None
        return {
            "ts": ts_int,
            "code": code_int,
            "path": path,
            "method": str(method).upper(),
            "source": row.get("source") or "",
            "domain": row.get("domain") or "",
            "level": row.get("level") or "",
        }

    # -- request logs (historical, paginated) ------------------------------

    def request_logs(
        self,
        project_id: str,
        owner_id: str,
        *,
        since_ms: int,
        until_ms: int,
        environment: Optional[str] = None,
        status_code: Optional[str] = None,
        source: Optional[List[str]] = None,
        level: Optional[List[str]] = None,
        deployment_id: Optional[str] = None,
        branch: Optional[str] = None,
        request_id: Optional[str] = None,
        search: Optional[str] = None,
        max_rows: Optional[int] = None,
        max_pages: Optional[int] = None,
    ) -> List[dict]:
        """Fetch historical request logs via
        ``GET https://vercel.com/api/logs/request-logs`` (the same endpoint the
        Vercel dashboard "Logs" page and ``vercel logs`` v2 use).

        This endpoint **does** support time-range queries (``startDate`` /
        ``endDate`` in ms epoch), pagination (``page``, ``hasMoreRows``),
        and server-side filtering by ``environment`` / ``statusCode`` /
        ``source`` / ``deploymentId`` / ``branch`` — unlike the public
        ``/v1/runtime-logs`` endpoint which is live-tail only.

        Walks pages until ``hasMoreRows`` is false, ``max_pages`` is reached,
        or ``max_rows`` rows are collected. Returns the raw row dicts; pass
        each through ``normalize_request_log_row`` for the canonical
        ``{ts, code, path, method, source, domain, level, ...}`` shape.

        Note: ``owner_id`` is the project's ``accountId`` (visible in the
        ``GET /v9/projects/{id}`` response). For team-owned projects this is
        ``team_...``; for personal projects it's ``user_...``.
        """
        if not project_id:
            raise VercelError("request_logs: project_id is required")
        if not owner_id:
            raise VercelError("request_logs: owner_id is required (project.accountId)")
        cap_rows = int(
            max_rows if max_rows is not None else self.config.request_logs_max_rows
        )
        cap_pages = int(
            max_pages if max_pages is not None else self.config.request_logs_max_pages
        )
        url = f"{self.config.dashboard_api}/api/logs/request-logs"
        rows: List[dict] = []
        page = 0
        while page < cap_pages and len(rows) < cap_rows:
            params: dict = {
                "projectId": project_id,
                "ownerId": owner_id,
                "page": str(page),
                "startDate": str(int(since_ms)),
                "endDate": str(int(until_ms)),
            }
            if environment:
                params["environment"] = environment
            if status_code:
                params["statusCode"] = str(status_code)
            if source:
                params["source"] = ",".join(source)
            if level:
                params["level"] = ",".join(level)
            if deployment_id:
                params["deploymentId"] = deployment_id
            if branch:
                params["branch"] = branch
            if request_id:
                params["requestId"] = request_id
            if search:
                params["search"] = search
            try:
                resp = self.session.get(
                    url,
                    params=params,
                    timeout=self.config.request_logs_timeout,
                    headers={"Accept": "application/json"},
                )
            except requests.RequestException as exc:
                raise VercelError(
                    f"request-logs page {page} failed: {exc}", http_code="000"
                ) from exc
            if resp.status_code != 200:
                self._raise_http_error(
                    f"GET {self.config.dashboard_api}/api/logs/request-logs (page={page})",
                    resp,
                )
            try:
                data = resp.json()
            except ValueError as exc:
                raise VercelError(
                    f"request-logs page {page} returned non-JSON: {exc}",
                    http_code=resp.status_code,
                    body=resp.text[:1500],
                ) from exc
            page_rows = data.get("rows") or []
            if not isinstance(page_rows, list):
                page_rows = []
            for row in page_rows:
                rows.append(row)
                if len(rows) >= cap_rows:
                    break
            has_more = bool(data.get("hasMoreRows"))
            if not has_more or not page_rows:
                break
            page += 1
        return rows

    @staticmethod
    def normalize_request_log_row(row: dict) -> Optional[dict]:
        """Reduce a request-logs row (dashboard schema) to a canonical shape.

        Output: ``{ts, code, path, method, source, domain, level,
        deployment_id, branch, environment, duration_ms, cache, region,
        error_code}``. Returns ``None`` for rows without ``requestPath``
        and a positive ``statusCode``.
        """
        if not isinstance(row, dict):
            return None
        path = row.get("requestPath") or ""
        try:
            code_int = int(row.get("statusCode") or 0)
        except (TypeError, ValueError):
            code_int = 0
        if not path or code_int <= 0:
            return None
        ts_raw = row.get("timestamp")
        ts_int = 0
        if isinstance(ts_raw, (int, float)):
            ts_int = int(ts_raw if ts_raw > 1e12 else ts_raw * 1000)
        elif isinstance(ts_raw, str) and ts_raw:
            # ISO 8601 string from the dashboard ("2026-04-28T01:39:04.630Z").
            try:
                from datetime import datetime, timezone

                ts_int = int(
                    datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
                    .astimezone(timezone.utc)
                    .timestamp()
                    * 1000
                )
            except ValueError:
                ts_int = 0
        events = row.get("events") if isinstance(row.get("events"), list) else []
        proxy_events = (
            row.get("proxyEvents") if isinstance(row.get("proxyEvents"), list) else []
        )
        first_source = ""
        for ev in events + proxy_events:
            if isinstance(ev, dict) and ev.get("source"):
                first_source = str(ev["source"])
                break
        # Highest-severity log level wins; rows without function logs default to "info".
        severity = {"info": 0, "warning": 1, "error": 2, "fatal": 3}
        level = "info"
        for entry in row.get("logs") or []:
            if not isinstance(entry, dict):
                continue
            lv = str(entry.get("level") or "").lower()
            if severity.get(lv, -1) > severity.get(level, -1):
                level = lv
        try:
            duration_ms = int(row.get("requestDurationMs") or 0)
        except (TypeError, ValueError):
            duration_ms = 0
        return {
            "ts": ts_int,
            "code": code_int,
            "path": path,
            "method": str(row.get("requestMethod") or "GET").upper(),
            "source": first_source,
            "domain": row.get("domain") or "",
            "level": level,
            "deployment_id": row.get("deploymentId") or "",
            "branch": row.get("branch") or "",
            "environment": row.get("environment") or "",
            "duration_ms": duration_ms,
            "cache": row.get("cache") or "",
            "region": row.get("clientRegion") or "",
            "error_code": row.get("errorCode") or "",
        }

    @staticmethod
    def normalize_event(ev: dict) -> Optional[dict]:
        """Extract ``{ts, code, path, method}`` from a deployment-event entry.

        Returns ``None`` for entries without HTTP request data (build stdout,
        deployment-state messages, etc.).
        """
        payload = ev.get("payload") or {}
        proxy = payload.get("proxy") or {}
        ts = (
            proxy.get("timestamp")
            or payload.get("date")
            or ev.get("created")
            or ev.get("timestampInMs")
            or ev.get("timestamp")
        )
        code = (
            proxy.get("statusCode")
            or payload.get("statusCode")
            or ev.get("responseStatusCode")
            or ev.get("status")
        )
        path = (
            proxy.get("path")
            or payload.get("path")
            or ev.get("requestPath")
            or ev.get("path")
        )
        method = (
            proxy.get("method")
            or payload.get("method")
            or ev.get("requestMethod")
            or ev.get("method")
            or "GET"
        )
        try:
            ts_int = int(ts) if ts else 0
            code_int = int(code) if code else 0
        except (TypeError, ValueError):
            return None
        if code_int <= 0 or not path:
            return None
        return {"ts": ts_int, "code": code_int, "path": path, "method": str(method).upper()}


# ---------------------------------------------------------------------------
# Module-level Robot keywords (snake_case → "Snake Case" automatically)
# ---------------------------------------------------------------------------


def _maybe_write(out_path: str, payload: Any) -> None:
    if not out_path:
        return
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)


def resolve_vercel_project_id(raw: str = "", out_path: str = "") -> dict:
    """Resolve a Vercel project slug to a ``prj_…`` id.

    Reads ``VERCEL_PROJECT_ID`` if ``raw`` is empty. Writes the result to
    ``out_path`` when provided. Returns ``{id, name, resolved_from}``.
    """
    raw = raw or os.environ.get("VERCEL_PROJECT_ID", "")
    result = VercelClient().resolve_project_id(raw)
    _maybe_write(out_path, result)
    return result


def get_vercel_project(id_or_name: str = "", out_path: str = "") -> dict:
    """``GET /v9/projects/{idOrName}``."""
    raw = id_or_name or os.environ.get("VERCEL_PROJECT_ID", "")
    result = VercelClient().get_project(raw)
    _maybe_write(out_path, result)
    return result


def list_vercel_deployments(
    project_id: str = "",
    target: str = "",
    out_path: str = "",
) -> dict:
    """``GET /v6/deployments`` with pagination + retries.

    Returns ``{"deployments": [...]}``. Reads ``VERCEL_PROJECT_ID`` and
    ``DEPLOYMENT_ENVIRONMENT`` if args are empty.
    """
    pid = project_id or os.environ.get("VERCEL_PROJECT_ID", "")
    tgt = (target or os.environ.get("DEPLOYMENT_ENVIRONMENT") or "").lower()
    if tgt == "all":
        tgt = ""
    result = VercelClient().list_deployments(pid, target=tgt or None)
    _maybe_write(out_path, result)
    return result


def select_vercel_deployments_for_window(
    deployments_path: str,
    window_start_ms: int,
    window_end_ms: int,
    environment: str = "production",
    max_results: int = 10,
    out_path: str = "",
) -> List[str]:
    """Pick READY deployment uids whose active interval overlaps the window."""
    with open(deployments_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    deps = data.get("deployments", []) if isinstance(data, dict) else (data or [])
    ids = VercelClient.select_deployments_for_window(
        deps,
        int(window_start_ms),
        int(window_end_ms),
        environment=environment,
        max_results=int(max_results),
    )
    _maybe_write(out_path, {"deployment_ids": ids})
    return ids


def fetch_vercel_deployment_events(
    deployment_id: str,
    since_ms: int = 0,
    until_ms: int = 0,
    limit: int = 10000,
    out_path: str = "",
) -> List[dict]:
    """``GET /v3/deployments/{id}/events`` with optional time bounds."""
    events = VercelClient().deployment_events(
        deployment_id,
        since_ms=int(since_ms) or None,
        until_ms=int(until_ms) or None,
        limit=int(limit),
    )
    _maybe_write(out_path, events)
    return events


def normalize_vercel_events(events_path: str, out_path: str = "") -> List[dict]:
    """Transform deployment-event entries into ``{ts, code, path, method}`` rows.

    Skips entries with no HTTP request data.
    """
    with open(events_path, "r", encoding="utf-8") as fh:
        events = json.load(fh)
    out: List[dict] = []
    for ev in events or []:
        normalized = VercelClient.normalize_event(ev)
        if normalized is not None:
            out.append(normalized)
    _maybe_write(out_path, out)
    return out


def fetch_vercel_runtime_logs(
    project_id: str,
    deployment_id: str,
    since_ms: int = 0,
    until_ms: int = 0,
    max_seconds: float = 60.0,
    max_rows: int = 5000,
    only_request_rows: bool = True,
    out_path: str = "",
) -> List[dict]:
    """Stream ``/v1/projects/{pid}/deployments/{depid}/runtime-logs``.

    Returns the raw NDJSON rows (filtered to those carrying a ``requestPath``
    by default). Use ``normalize_vercel_runtime_rows`` to reduce them to
    ``{ts, code, path, method, source, domain, level}``.
    """
    rows = VercelClient().runtime_logs(
        project_id,
        deployment_id,
        max_seconds=max_seconds,
        max_rows=max_rows,
        since_ms=int(since_ms) or None,
        until_ms=int(until_ms) or None,
        only_request_rows=bool(only_request_rows),
    )
    _maybe_write(out_path, rows)
    return rows


def normalize_vercel_runtime_rows(rows_path: str, out_path: str = "") -> List[dict]:
    """Transform raw runtime-logs rows to normalized HTTP rows."""
    with open(rows_path, "r", encoding="utf-8") as fh:
        rows = json.load(fh)
    out: List[dict] = []
    for row in rows or []:
        normalized = VercelClient.normalize_runtime_row(row)
        if normalized is not None:
            out.append(normalized)
    _maybe_write(out_path, out)
    return out


def fetch_vercel_request_logs(
    project_id: str,
    owner_id: str,
    since_ms: int,
    until_ms: int,
    *,
    environment: str = "",
    status_code: str = "",
    source: Optional[List[str]] = None,
    level: Optional[List[str]] = None,
    deployment_id: str = "",
    branch: str = "",
    max_rows: Optional[int] = None,
    max_pages: Optional[int] = None,
    out_path: str = "",
) -> List[dict]:
    """Fetch historical request logs (``GET vercel.com/api/logs/request-logs``).

    Returns the raw row dicts (the dashboard schema). Use
    ``normalize_vercel_request_log_rows`` (or pass ``--normalize`` to the CLI)
    to reduce them to the canonical ``{ts, code, path, method, source, ...}``
    shape used by the bucket aggregators.
    """
    rows = VercelClient().request_logs(
        project_id,
        owner_id,
        since_ms=int(since_ms),
        until_ms=int(until_ms),
        environment=environment or None,
        status_code=str(status_code) if status_code else None,
        source=source,
        level=level,
        deployment_id=deployment_id or None,
        branch=branch or None,
        max_rows=max_rows,
        max_pages=max_pages,
    )
    _maybe_write(out_path, rows)
    return rows


def normalize_vercel_request_log_rows(
    rows_path: str, out_path: str = ""
) -> List[dict]:
    """Transform raw request-logs rows to normalized HTTP rows."""
    with open(rows_path, "r", encoding="utf-8") as fh:
        rows = json.load(fh)
    out: List[dict] = []
    for row in rows or []:
        normalized = VercelClient.normalize_request_log_row(row)
        if normalized is not None:
            out.append(normalized)
    _maybe_write(out_path, out)
    return out


__all__ = [
    "VERCEL_API_DEFAULT",
    "VERCEL_DASHBOARD_API_DEFAULT",
    "VercelClient",
    "VercelConfig",
    "VercelError",
    "ROBOT_LIBRARY_SCOPE",
    "resolve_vercel_project_id",
    "get_vercel_project",
    "list_vercel_deployments",
    "select_vercel_deployments_for_window",
    "fetch_vercel_deployment_events",
    "normalize_vercel_events",
    "fetch_vercel_runtime_logs",
    "normalize_vercel_runtime_rows",
    "fetch_vercel_request_logs",
    "normalize_vercel_request_log_rows",
]
