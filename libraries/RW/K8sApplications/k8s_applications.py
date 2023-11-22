import logging, hashlib
from dataclasses import dataclass, field
from thefuzz import process as fuzzprocessor
from datetime import datetime

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
MAX_LOG_LINES: int = 1025

RUNWHEN_ISSUE_KEYWORD: str = "[RunWhen]"


def format_process_list(proc_list: str) -> list:
    if proc_list:
        proc_list = proc_list.split("\n")
    else:
        proc_list = []
    return proc_list


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


def get_test_data():
    data = ""
    with open(f"{THIS_DIR}/test_logs.txt", "r") as fh:
        data = fh.read()
    return data


def parse_exceptions(
    logs: str,
    debug_info: bool = False,
) -> [StackTraceData]:
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
        st_data: StackTraceData = None
        for parser in parsers:
            st_data = parser.parse_log(log)
            if st_data and st_data.has_results:
                exception_data.append(st_data)
                # got a successful parse, move onto next log line
                break
            elif debug_info:
                logger.info(f"parser {parser} returned {st_data}")
    return exception_data


def clone_repo(git_uri, git_token, number_of_commits_history: int = 10) -> Repository:
    repo = Repository(source_uri=git_uri, auth_token=git_token)
    repo.clone_repo(number_of_commits_history)
    return repo


def _hash_string_md5(input_string):
    return hashlib.md5(input_string.encode()).hexdigest()


def troubleshoot_application(
    repos: list[Repository],
    exceptions: list[StackTraceData],
    env: dict = {},
    process_list: list[str] = [],
) -> dict:
    logger.info(f"Received following repo(s) to troubleshoot: {repos}")
    logger.info(f"Received following parsed exceptions to troubleshoot: {exceptions}")
    search_words: list[str] = []
    exception_occurences: dict = {}
    most_common_exception: str = ""
    report: str = ""
    for repo in repos:
        results: list[RepositorySearchResult] = []
        for excep in exceptions:
            if excep is not None and excep.has_results:
                search_words += excep.endpoints
                search_words += excep.urls
                search_words += excep.error_messages
                results += repo.search(
                    search_words=search_words, search_files=excep.files
                )
                # we hash the exception strings to shorten them for dict searches
                hashed_exception = _hash_string_md5(excep.raw)
                if hashed_exception not in exception_occurences:
                    exception_occurences[hashed_exception] = {
                        "count": 1,
                        "content": excep.raw,
                    }
                elif hashed_exception in exception_occurences:
                    exception_occurences[hashed_exception]["count"] += 1
        rsr_report = ""
        files_already_added = []
        for rsr in results:
            if rsr.source_file.git_file_url in files_already_added:
                continue
            rsr_report += f"\n{rsr.source_file.git_file_url}\n"
            for commit in rsr.related_commits:
                rsr_report += f"\t{repo.repo_url}/commit/{commit.sha}\n"
            files_already_added.append(rsr.source_file.git_file_url)

        src_files_title = (
            "## Found associated files in exception stacktrace data:"
            if rsr_report
            else "## No relevant source code or diffs could be found in the exception data."
        )
        report += f"""
# Repository URL(s): {repo.source_uri}

{src_files_title}
{rsr_report}

"""
    # get most common exception
    max_count = -1
    for hashed_exception in exception_occurences:
        count = exception_occurences[hashed_exception]["count"]
        if count > max_count:
            max_count = count
            most_common_exception = exception_occurences[hashed_exception]["content"]
    report += (
        f"""
## This is the most common exception found:
```
{most_common_exception}
```
"""
        if most_common_exception
        else "## No common exceptions could be parsed. Try running the log command provided."
    )
    return {
        "report": report,
        "found_exceptions": (True if most_common_exception else False),
    }


def create_github_issue(repo: Repository, content: str) -> str:
    already_open: bool = False
    issues = repo.list_issues()
    report_url = None
    for issue in issues:
        title = issue["title"]
        url = issue["html_url"]
        if RUNWHEN_ISSUE_KEYWORD in title:
            already_open = True
            report_url = url
    if not already_open:
        data = repo.create_issue(
            title=f"{RUNWHEN_ISSUE_KEYWORD} Application Issue",
            body=content,
        )
        if "html_url" in data:
            report_url = data["html_url"]
    if report_url:
        return f"Here's a link to an open GitHub issue for application exceptions: {report_url}"
    else:
        return "No related GitHub issue could be found."
