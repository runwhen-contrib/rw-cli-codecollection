import logging
from dataclasses import dataclass, field
from thefuzz import process as fuzzprocessor

from .parsers import (
    StackTraceData,
    BaseStackTraceParse,
    PythonStackTraceParse,
    DRFStackTraceParse,
    GoogleDRFStackTraceParse,
)
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
MAX_LOG_LINES: int = 100


def serialize_env(printenv: str) -> dict:
    k8s_env: dict = {}
    for line in printenv.split("\n"):
        if "=" in line:
            key, value = line.split("=", 1)
            k8s_env[key] = value
    return k8s_env


def test(git_uri, git_token, k8s_env, process_list, *args, **kwargs):
    repo = Repository(source_uri=git_uri, auth_token=git_token)
    repo.clone_repo()
    logger.info(repo)
    fake_excep = None
    with open(f"{THIS_DIR}/test_logs.txt", "r") as fh:
        fake_excep = fh.read()
    repo_issues = repo.list_issues()
    exceptions = parse_exceptions(fake_excep)
    report = troubleshoot_application([repo], exceptions)
    return report


def parse_exceptions(logs: str) -> []:
    logs = logs.split("\n")
    if len(logs) > MAX_LOG_LINES:
        logger.warning(
            f"Length of logs provided for parsing exceptions is greater than {MAX_LOG_LINES}, be aware this could effect performance"
        )
    exception_data: list[StackTraceData] = []
    # Add more parser types here and they will be attempted in-order until first success, per log line
    parsers: list[BaseStackTraceParse] = [
        GoogleDRFStackTraceParse,
        PythonStackTraceParse,
    ]
    # TODO: support multiline parsing
    for log in logs:
        logger.info(f"On logline: {log}")
        st_data: StackTraceData = None
        for parser in parsers:
            logger.info(f"Trying parser: {parser}")
            st_data = parser.parse_log(log)
            logger.info(f"got parse result: {st_data}")
            if st_data and st_data.has_results:
                exception_data.append(st_data)
                # got a successful parse, move onto next log line
                break
    return exception_data


def troubleshoot_application(
    repos: list[Repository], exceptions: list[StackTraceData]
) -> str:
    logger.info(f"Received following repo(s) to troubleshoot: {repos}")
    logger.info(f"Received following parsed exceptions to troubleshoot: {exceptions}")
    search_words: list[str] = []
    results: list[RepositorySearchResult] = []

    for excep in exceptions:
        if excep is not None and excep.has_results:
            search_words += excep.endpoints
            search_words += excep.urls
            search_words += excep.error_messages
            for repo in repos:
                results += repo.search(
                    search_words=search_words, search_files=excep.files
                )

                # find file paths that are in source repo that showed up in exception extractions

            # search_results = fuzzprocessor.extract(
            #     single_search.replace("\n", ""), mapping.keys(), limit=k_nearest
            # )
    logger.info("SEARCH RESULTS")
    logger.info(results)
    return "REPORT"
