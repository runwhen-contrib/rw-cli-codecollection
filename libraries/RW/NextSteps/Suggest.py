"""
Utility library for suggesting next steps based on a static troubleshooting yaml database

See https://github.com/seatgeek/thefuzz

Scope: Global
"""
import logging, yaml
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn
from thefuzz import process as fuzzprocessor

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"

THIS_DIR: str = "/".join(__file__.split("/")[:-1])


def _load_mapping(platform: str) -> dict:
    data: dict = {}
    with open(f"{THIS_DIR}/{platform}/mapping.yaml", "r") as fh:
        data = yaml.safe_load(fh)
    return data


def format_suggestions(suggestions: list) -> str:
    pass


def suggest(
    search_error: str,
    platform: str = "Kubernetes",
    pretty_answer: bool = True,
    k_nearest: int = 1,
    **kwargs,
):
    mapping = _load_mapping(platform)
    results: list[str] = []
    if not mapping:
        return results
    key_results = fuzzprocessor.extract(search_error, mapping.keys(), limit=k_nearest)
    next_steps_data = []
    for match_tuple in key_results:
        map_key = match_tuple[0]
        next_steps_data += mapping[map_key]
    if pretty_answer:
        titles: str = ""
        object_hints: str = ""
        for suggestion in suggestions:
            if ":" in suggestion:
                object_hints += f"\n{suggestion}"
        results = ", ".join(results)
    return results
