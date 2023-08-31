"""
Utility library for suggesting next steps based on a static troubleshooting yaml database

See https://github.com/seatgeek/thefuzz

Scope: Global
"""
import logging, yaml
from string import Template
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn
from thefuzz import process as fuzzprocessor

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"
NO_RESULT_STRING: str = "No next steps found, contact your service owner."

THIS_DIR: str = "/".join(__file__.split("/")[:-1])


def _load_mapping(platform: str) -> dict:
    data: dict = {}
    with open(f"{THIS_DIR}/{platform}/mapping.yaml", "r") as fh:
        data = yaml.safe_load(fh)
    return data


def format(suggestions: str, **kwargs) -> str:
    for k, v in kwargs.items():
        if type(v) is str:
            kwargs[k] = v.strip("\n")
    suggestions = Template(suggestions).safe_substitute(kwargs)
    return suggestions


def suggest(
    search,
    platform: str = "Kubernetes",
    pretty_answer: bool = True,
    include_object_hints: bool = True,
    k_nearest: int = 1,
    minimum_match_score: int = 60,
    **kwargs,
):
    # allow search to be str or list, allowing combinations of K>1 and multi search
    if type(search) == str:
        search = [search]
    mapping = _load_mapping(platform)
    results: list[str] = []
    if not mapping:
        return results
    key_results: list = []
    for single_search in search:
        if not single_search:
            continue
        key_results += fuzzprocessor.extract(single_search.replace("\n", ""), mapping.keys(), limit=k_nearest)
    next_steps_data = []
    for match_tuple in key_results:
        # tuple structure: ('FailedMount', 67)
        logger.info(f"Fuzzy Match: {match_tuple}")
        if match_tuple[1] < minimum_match_score:
            continue
        map_key = match_tuple[0]
        next_steps_data += mapping[map_key]
    if not next_steps_data:
        return NO_RESULT_STRING
    if pretty_answer:
        titles: list = []
        object_hints: list = []
        for suggestion in next_steps_data:
            if ":" in suggestion and suggestion not in object_hints:
                object_hints.append(f"{suggestion}")
            elif ":" not in suggestion and suggestion not in titles:
                titles.append(f"{suggestion}")
        object_hints = "\n".join(object_hints)
        titles = ", ".join(titles)
        results = f"{titles}\n\n{object_hints}"
    return results
