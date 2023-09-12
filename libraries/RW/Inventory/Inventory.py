"""
Keywords for interacting with generic provider inventories, such as finding related services 

Scope: Global
"""
import logging, yaml
from string import Template
from datetime import datetime
from robot.libraries.BuiltIn import BuiltIn
from thefuzz import process as fuzzprocessor
from dataclasses import dataclass, field

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"
INVENTORY: list[str] = []
THIS_DIR: str = "/".join(__file__.split("/")[:-1])
ALLOWED_TYPES: list[str] = ["prefix", "in"]


@dataclass
class InventoryItem:
    item_type: str
    item_name: str
    item_full_name: str
    item_var_name: str
    result_score: float

    def __init__(
        self,
        item_type: str = "",
        item_name: str = "",
        item_full_name: str = "",
        item_var_name: str = "",
        result_score: float = 0,
        platform: str = "Kubernetes",
    ):
        self.item_type = item_type
        self.item_name = item_name
        self.item_full_name = item_full_name
        self.item_var_name = item_var_name
        self.result_score = result_score
        if platform == "Kubernetes":
            self._set_kubernetes_names()

    # TODO: refactor
    # very hacky - needs to be a strategy object so that inventory items dont know about platforms and naming conventions
    def _set_kubernetes_names(self) -> None:
        if not self.item_full_name:
            return
        var_lookup = {
            "satefulset.apps": "statefulset_name",
            "deployment.apps": "deployment_name",
            "deployment.apps": "deployment_name",
        }
        parts = self.item_full_name.split("/")
        self.item_type = parts[0]
        self.item_name = parts[1]
        if self.item_type in var_lookup.keys():
            self.item_var_name = var_lookup[self.item_type]
        else:
            self.item_var_name = f"{self.item_type}_name"


def _load_boosts(platform: str) -> list[dict]:
    data: list = []
    with open(f"{THIS_DIR}/boosts.yaml", "r") as fh:
        content = yaml.safe_load(fh)
        if platform in content.keys():
            data = content[platform]
        else:
            data = []
    return data


def set_inventory(iventory: list[str]) -> None:
    global INVENTORY
    INVENTORY = iventory


def get_inventory() -> list[str]:
    return INVENTORY


def add_to_inventory(item: str) -> None:
    global INVENTORY
    if item not in INVENTORY:
        INVENTORY.append(item)


# TODO: find home for this
# structure is specialized for nextsteps formatting so there's coupling
def to_kwargs(*args) -> dict:
    results: dict = {}
    items: list[InventoryItem] = []
    items = [item for arg_element in args for item in (arg_element if isinstance(arg_element, list) else [arg_element])]
    logging.info(f"items: {items}")
    for item in items:
        if type(item) is not InventoryItem:
            continue
        if not item.item_var_name:
            continue
        if item.item_var_name not in results.keys():
            results[item.item_var_name] = item.item_name
        elif item.item_var_name in results.keys() and type(results[item.item_var_name]) is str:
            results[item.item_var_name] = [results[item.item_var_name], item.item_name]
        elif item.item_var_name in results.keys() and type(results[item.item_var_name]) is list:
            results[item.item_var_name].append(item.item_name)
    return results


def related(search: str, k_nearest: int = 10, boost_from: str = "Kubernetes") -> list[InventoryItem]:
    boosts: list[dict] = _load_boosts(boost_from)
    logging.info(f"boost config: {boosts}")
    results = fuzzprocessor.extract(search.replace("\n", ""), get_inventory(), limit=k_nearest)
    logging.info(f"Pre-boost results: {results}")
    if boosts:
        boosted_results: list[tuple] = []
        for result in results:
            boosted: bool = False
            for boost in boosts:
                if boosted:
                    break
                if boost["type"] not in ALLOWED_TYPES:
                    continue
                if boost["type"] == "prefix" and result[0].startswith(boost["value"]):
                    boosted_results.append(tuple([result[0], result[1] * boost["boost"]]))
                    boosted = True
                elif boost["type"] == "in" and boost["value"] in result[0]:
                    boosted_results.append(tuple([result[0], result[1] * boost["boost"]]))
                    boosted = True
            if not boosted:
                boosted_results.append(tuple(result))
        results = boosted_results
    logging.info(f"{results}")
    results = sorted(results, key=lambda x: x[1], reverse=True)
    logging.info(f"Boosted (applied: {bool(boosts)}) results: {results}")
    results = [
        InventoryItem(item_full_name=result[0], result_score=result[1], platform=boost_from) for result in results
    ]
    return results
