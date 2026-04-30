"""Vercel — Vercel REST API keyword library for Robot Framework.

Importable from Robot via::

    Library    Vercel

Then once at suite setup::

    Configure Vercel Client    vercel_token=${vercel_token}    vercel_team_id=${VERCEL_TEAM_ID}

Subsequent keywords (``Get Vercel Project``, ``List Vercel Project Domains``,
``Fetch Vercel Request Logs``, ``Get Vercel Deployment``,
``List Vercel Deployments``, ``Select Vercel Deployments For Window``,
``Resolve Vercel Project Id``, ``Normalize Vercel Request Log Rows``, …)
inherit the configured auth context.

This package no longer ships a CLI surface — bundle bash scripts receive
pre-fetched JSON from Robot via ``out_path=`` parameters and only do jq
aggregation / markdown rendering.
"""
from .vercel import *  # re-export public surface for Robot
