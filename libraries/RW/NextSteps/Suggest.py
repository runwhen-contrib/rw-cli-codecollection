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
OBJECT_HINT_SYMBOL: str = ":"

THIS_DIR: str = "/".join(__file__.split("/")[:-1])


def _load_mapping(platform: str) -> dict:
    data: dict = {}
    with open(f"{THIS_DIR}/{platform}/mapping.yaml", "r") as fh:
        data = yaml.safe_load(fh)
    return data


def format(suggestions: str, expand_arrays: bool = True, **kwargs) -> str:
    reformatted_suggestions: list[str] = []
    suggestions = suggestions.split("\n")
    formatted_kwargs: dict = {}
    for k, v in kwargs.items():
        if type(v) is str:
            kwargs[k] = v.strip("\n")
        # create consistent key naming for dynamic hint types (lowercase all)
        # eg: Pod_name -> pod_name
        formatted_kwargs[k.lower()] = v
    logger.info(f"Formatting with prepared kwargs: {formatted_kwargs}")
    # for array values, multiplies them against matching object hint lines
    # allowing nextsteps to point to multiple objects, like a labeled group of pods
    if expand_arrays:
        reformatted_kwargs: dict = {}
        for line in suggestions:
            for k, v in formatted_kwargs.items():
                if k in line and OBJECT_HINT_SYMBOL in line and type(v) is list:
                    line_parts = line.split(OBJECT_HINT_SYMBOL)
                    if len(line_parts) != 2:
                        logger.info(f"The object hint line is malformed: {line_parts}")
                        continue
                    object_type = line_parts[0]
                    object_var_name = line_parts[1]
                    new_lines: list[str] = []
                    # eg: kwargs[pod_name] = ["myapp-0303", "myapp-3221"] -> kwargs[pod_name0] = "myapp-0303", etc
                    for index, subval in enumerate(v):
                        reformatted_kwargs[f"{k}{index}"] = subval
                    new_lines = [f"{object_type}{index}" for index, subval in enumerate(v)]
                    reformatted_suggestions += new_lines
                else:
                    reformatted_kwargs[k] = v
                    reformatted_suggestions.append(line)
        formatted_kwargs = reformatted_kwargs
    suggestions = "\n".join(suggestions)
    suggestions = Template(suggestions).safe_substitute(formatted_kwargs)
    # remove any object hints that didn't get values, de-duplicate
    # and re-order to allow joining of multiple nextsteps blocks
    object_hints: list[str] = []
    ordered_suggestions: list[str] = []
    for line in suggestions.split("\n"):
        if line and not line.isspace() and OBJECT_HINT_SYMBOL not in line and line not in ordered_suggestions:
            ordered_suggestions.append(line)
        elif (
            line and not line.isspace() and OBJECT_HINT_SYMBOL in line and "$" not in line and line not in object_hints
        ):
            object_hints.append(line)
    object_hints = "\n".join(object_hints)
    ordered_suggestions = "\n".join(ordered_suggestions)
    suggestions = f"{ordered_suggestions}\n\n{object_hints}"
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
            if OBJECT_HINT_SYMBOL in suggestion and suggestion not in object_hints:
                object_hints.append(f"{suggestion}")
            elif OBJECT_HINT_SYMBOL not in suggestion and suggestion not in titles:
                titles.append(f"{suggestion}")
        object_hints = "\n".join(object_hints)
        titles = ", ".join(titles)
        results = f"{titles}\n\n{object_hints}"
    return results
