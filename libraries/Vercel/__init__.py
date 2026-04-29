"""Vercel — Vercel REST API helpers (Robot keyword library + CLI).

Importable from Robot via:    Library    Vercel
Callable from bash via:       python -m Vercel <subcommand> [...]

Endpoints used (per Vercel REST API reference):
- GET /v6/deployments
- GET /v9/projects/{idOrName}
- GET /v9/projects
- GET /v3/deployments/{idOrUrl}/events
"""
from .vercel import *  # re-export public surface for Robot
