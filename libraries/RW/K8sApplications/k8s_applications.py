import logging
from .repository import (
    Repository,
    RepositoryFile,
    RepositoryFiles,
    RepositorySearchResult,
)
from RW import CLI
from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)
THIS_DIR: str = "/".join(__file__.split("/")[:-1])


def serialize_env(printenv: str) -> dict:
    k8s_env: dict = {}
    for line in printenv.split("\n"):
        if "=" in line:
            key, value = line.split("=", 1)
            k8s_env[key] = value
    return k8s_env


def test(git_uri, git_token, k8s_env):
    repo = Repository(source_uri=git_uri, auth_token=git_token)
    repo.clone_repo()
    logger.info(repo)
    fake_excep = None
    with open(f"{THIS_DIR}/fake_exception.txt", "r") as fh:
        fake_excep = fh.read()
    print(repo.list_issues())
