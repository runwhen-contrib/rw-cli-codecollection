import subprocess
import os
import logging
import json
import re
import dateutil.parser
import requests

from datetime import datetime
from typing import List, Optional
from pathlib import Path
from dataclasses import dataclass, field
from thefuzz import process as fuzzprocessor

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)
RUNWHEN_PR_KEYWORD: str = "[RunWhen]"


@dataclass
class GitCommit:
    sha: str
    author_name: str
    author_email: str
    message: str
    datetime_data: any
    _clone_directory: str
    _diff: str = field(default=None, repr=False, init=False)
    _changed_files: list = field(default=None, init=False, repr=False)

    @property
    def changed_files(self):
        if self._changed_files is not None:
            return self._changed_files
        changed_files_output = subprocess.run(
            ["git", "show", "--pretty=", "--name-only", f"{self.sha}"],
            text=True,
            capture_output=True,
            check=True,
            cwd=self._clone_directory,
        )
        changed_files_output = changed_files_output.stdout
        self._changed_files = changed_files_output.strip().split("\n")
        return self._changed_files

    @property
    def diff(self):
        # Check if the diff is already cached
        if self._diff is not None:
            return self._diff
        # Perform the subprocess call to get the diff
        diff_output = subprocess.run(
            ["git", "diff", self.sha + "^!", "--"],  # ^! gets the diff for the commit
            text=True,
            capture_output=True,
            check=True,
            cwd=self._clone_directory,
        ).stdout
        # Cache the diff
        self._diff = diff_output
        return diff_output

    def _parse_diff_changes(self):
        diff = self._get_diff()
        additions = []
        deletions = []
        current_file = None
        for line in diff.split("\n"):
            if line.startswith("+++ b/"):
                current_file = line[6:]
            elif line.startswith("+") and not line.startswith("++"):
                additions.append((current_file, line[1:]))
            elif line.startswith("-") and not line.startswith("--"):
                deletions.append((current_file, line[1:]))
        self._diff_additions = additions
        self._diff_deletions = deletions

    @property
    def diff_additions(self):
        if self._diff_additions is None:
            self._parse_diff_changes()
        return self._diff_additions

    @property
    def diff_deletions(self):
        if self._diff_deletions is None:
            self._parse_diff_changes()
        return self._diff_deletions


@dataclass
class RepositorySearchResult:
    source_file: "RepositoryFile"
    related_commits: list[GitCommit]
    line_num: Optional[int] = None


@dataclass
class RepositoryFile:
    git_file_url: str
    relative_file_path: str
    absolute_file_path: str
    basename: str
    line_count: int
    git_url_base: str
    filesystem_basepath: str
    branch: str
    content: str = field(repr=False)

    def __init__(
        self, absolute_filepath, filesystem_basepath, repo_base_url, branch="main"
    ) -> None:
        self.absolute_file_path = str(absolute_filepath)
        self.basename = os.path.basename(self.absolute_file_path)
        self.filesystem_basepath = filesystem_basepath
        self.git_url_base = str(repo_base_url)
        self.branch = branch
        self.relative_file_path = str(
            Path(self.absolute_file_path).relative_to(filesystem_basepath)
        )
        with open(self.absolute_file_path) as fh:
            self.content = fh.read()
        # logger.info(f"Counting: {self.absolute_file_path}")
        self.line_count = sum(
            1 for line in open(self.absolute_file_path) if line.strip()
        )
        self.git_file_url = (
            f"{self.git_url_base}/blob/{self.branch}/{self.relative_file_path}"
        )

    def search(self, search_term: str) -> RepositorySearchResult:
        # TODO: implement content search - look at how we accurately do this
        # avoids bad query strings submitted to fuzz lib
        # skip_regex = r"^[ \t\n\r#*,(){}\[\]\"\'\':]*$"
        return None

    def content_peek(self, line_num: int, before: int=44, after: int=6) -> str:
        lines = self.content.splitlines()
        start = max(0, line_num - before - 1)
        end = min(len(lines), line_num + after)
        peek_lines = lines[start:end]
        result = '\n'.join(peek_lines)
        return result

    def git_add(self):
        try:
            add_stdout = subprocess.run(
                ["git", "add", self.relative_file_path],
                text=True,
                capture_output=True,
                check=True,
                cwd=self.filesystem_basepath,
            ).stdout
            logger.info(f"File {self.relative_file_path} has been added to staging.")
        except subprocess.CalledProcessError as e:
            logger.error(f"An error occurred: {e}")

    def write_content(self) -> None:
        with open(self.absolute_file_path, "w") as fp:
            fp.write(self.content)


@dataclass
class RepositoryFiles:
    files: dict[str, RepositoryFile]

    def __init__(self) -> None:
        self.files = {}

    def add_source_file(self, src_file: RepositoryFile) -> None:
        self.files[src_file.relative_file_path] = src_file

    @property
    def file_paths(self) -> list[str]:
        return self.files.keys()

    @property
    def all_files(self) -> list[RepositoryFile]:
        return self.files.values()

    @property
    def all_basenames(self) -> list[str]:
        basenames: list[str] = []
        all_files = self.all_files
        for repo_file in all_files:
            basenames.append(repo_file.basename)
        return basenames


class Repository:
    EXCLUDE_PATHS: list[str] = [
        ".git",
        ".gitmodules",
    ]
    EXCLUDE_EXT: list[str] = [".png", ".jpg", ".jpeg", ".ico"]
    source_uri: str
    repo_url: str
    repo_owner: str
    repo_name: str
    auth_token: str
    files: RepositoryFiles
    clone_directory: str
    branch: str
    commit_history: list[GitCommit] = []
    local_branch_lookup: dict = {}

    def __str__(self):
        repo_summary = f"Repository: {self.repo_owner}/{self.repo_name}\nRepository URI: {self.source_uri}"
        file_summary = f"Number of files: {len(self.files.files)}"
        branch_summary = f"Branch: {self.branch}"
        commit_summary = "Recent Commits:\n"
        commit_seperator = "--------------\n"
        for commit in self.commit_history:  # Show the last 5 commits as an example
            commit_summary += f"{commit_seperator}{commit.sha[:7]} by {commit.author_name} on {commit.datetime_data}: {commit.message[:50]}{'...' if len(commit.message) > 50 else ''}\n"
        return f"{repo_summary}\n{branch_summary}\n{file_summary}\n{commit_summary}"

    def __init__(
        self, source_uri: str, auth_token: platform.Secret = None, branch="main"
    ) -> None:
        self.source_uri = source_uri
        self.repo_url = self.get_repo_base_url()
        # get owner and repo name from uri
        repo_path = self.repo_url.replace("https://github.com/", "").replace(
            "git@github.com:", ""
        )
        if repo_path.endswith(".git"):
            repo_path = repo_path[:-4]
        parts = repo_path.split("/")
        self.repo_owner = parts[0]
        self.repo_name = parts[1]
        if auth_token:
            self.auth_token = auth_token.value
        else:
            self.auth_token = None
        self.files = RepositoryFiles()
        self.branch = branch
    
    def find_file(self, filename: str) -> RepositoryFile:
        if not filename:
            return None
        for fn, obj in self.files.files.items():
            if obj.basename == filename:
                return obj
            elif obj.basename == os.path.basename(filename):
                return obj

    def clone_repo(
        self,
        num_commits_history: int = 10,
        cache: bool = False,
    ) -> str:
        repo_name = self.source_uri.split("/")[-1]
        if repo_name.endswith(".git"):
            repo_name = repo_name[:-4]
        self.clone_directory = f"/tmp/{repo_name}"

        # Ensure the target directory is clean or use cache
        if os.path.exists(self.clone_directory) and cache:
            pass
        elif os.path.exists(self.clone_directory):
            subprocess.run(["rm", "-rf", self.clone_directory], check=True)
            os.makedirs(self.clone_directory, exist_ok=True)

        # Modify the Git URI to include the token for authentication
        if "https://" in self.source_uri and self.auth_token:
            auth_uri = self.source_uri.replace(
                "https://", f"https://oauth2:{self.auth_token}@"
            )
        elif "https://":
            auth_uri = self.source_uri
        else:
            raise ValueError(
                "Unsupported Git URI. Please use HTTPS URL for cloning with a token."
            )
        # test = subprocess.run(["git", "--help"], check=True)
        # logger.info(f"{test.stdout}::{test.stderr}")
        if not os.path.exists(f"{self.clone_directory}/.git"):
            # Execute the Git clone command with the modified URI
            gitcmd = None
            try:
                gitcmd = subprocess.run(
                    [
                        "git",
                        "clone",
                        "--branch",
                        self.branch,
                        "--single-branch",
                        auth_uri,
                        self.clone_directory,
                    ],
                    check=True,
                    env={"GIT_TERMINAL_PROMPT": "0"},
                )
            except:
                logger.error(f"git clone failed, supressing exception for security, consider debugging locally")
        if not os.path.exists(f"{self.clone_directory}"):
            logger.error(
                f"Could not create git repo, stdout: {gitcmd.stdout} stderr: {gitcmd.stderr}"
            )
        self.create_file_list()
        self.commit_history = self.serialize_git_commits(
            self.get_git_log(num_commits_history)
        )
        return self.clone_directory

    def git_commit(
        self,
        branch_name: str,
        comment: str,
    ) -> None:
        current_datetime = datetime.now()
        timestamp = int(current_datetime.timestamp())
        unique_branch_name = f"{branch_name}-{timestamp}"
        self.local_branch_lookup[branch_name] = unique_branch_name
        checkout_b = subprocess.run(
            [
                "git",
                "checkout",
                "-b",
                f"{unique_branch_name}",
            ],
            check=True,
            cwd=self.clone_directory,
            capture_output=True,
        )
        logger.info(f"Checked out branch {unique_branch_name}")
        commitcmd = subprocess.run(
            [
                "git",
                "commit",
                "-m",
                f"{comment}",
            ],
            check=True,
            cwd=self.clone_directory,
            capture_output=True,
        )
        logger.info(f"Comitting... {commitcmd.stdout}")
        checkout_default = subprocess.run(
            [
                "git",
                "checkout",
                f"{self.branch}",
            ],
            check=True,
            cwd=self.clone_directory,
            capture_output=True,
        )
        logger.info(f"Returning to default branch {checkout_default.stdout}")

    def git_push_branch(self, branch: str, remote: str = "origin") -> None:
        true_branch_name = self.local_branch_lookup[branch]
        gitpushcmd = subprocess.run(
            [
                "git",
                "push",
                f"{remote}",
                f"{true_branch_name}",
            ],
            check=True,
            capture_output=True,
            cwd=self.clone_directory,
        )

    def git_pr(
        self,
        title: str,
        branch: str,
        body: str,
        check_open: bool = True,
    ) -> dict:
        is_already_open: bool = False
        true_branch_name = self.local_branch_lookup[branch]
        url = f"https://api.github.com/repos/{self.repo_owner}/{self.repo_name}/pulls"
        headers = {
            "Authorization": f"token {self.auth_token}",
            "Accept": "application/vnd.github.v3+json",
        }
        if check_open:
            rsp = requests.get(url, headers=headers)
            if rsp.status_code < 200 or rsp.status_code >= 300:
                logger.warning(f"Error: {rsp.status_code}, {rsp.text}")
                return {}
            rsp = rsp.json()
            for pr in rsp:
                title = pr["title"]
                state = pr["state"]
                if state == "open" and RUNWHEN_PR_KEYWORD in title:
                    is_already_open = True

        if is_already_open:
            return {}
        data = {
            "title": title,
            "head": branch,
            "body": body,
            "base": "main",
        }
        response = requests.post(url, headers=headers, json=data)

        if response.status_code >= 300:
            logger.warning(f"Error: {response.status_code}, {response.text}")
            return {}

        return response.json()

    def get_repo_base_url(self) -> str:
        remote_url = self.source_uri
        if remote_url.startswith("git@"):
            remote_url = remote_url.replace(":", "/").replace("git@", "https://")
        if remote_url.endswith(".git"):
            remote_url = remote_url[:-4]
        return remote_url

    @staticmethod
    def is_text_file(file_path):
        try:
            # Open the file in binary mode and read a small portion
            with open(file_path, "rb") as file:
                chunk = file.read(512)  # Read first 512 bytes
            # Try decoding this chunk. If it fails, it's likely binary
            chunk.decode("utf-8")
            return True
        except UnicodeDecodeError:
            return False

    def create_file_list(self) -> None:
        for root, dirs, files in os.walk(self.clone_directory):
            for name in files:
                if name not in Repository.EXCLUDE_PATHS and all(
                    ext not in name for ext in Repository.EXCLUDE_EXT
                ):
                    file_path = os.path.join(root, name)
                    if not Repository.is_text_file(file_path=file_path):
                        continue
                    src_file = RepositoryFile(
                        absolute_filepath=file_path,
                        filesystem_basepath=self.clone_directory,
                        repo_base_url=self.get_repo_base_url(),
                        branch=self.branch,
                    )
                    self.files.add_source_file(src_file)

    def search(
        self,
        search_words: list[str] = [],
        search_files: list[str] = [],
        # max_results_per_word: int = 5,
        # search_match_score_min: int = 90,
    ) -> [RepositorySearchResult]:
        if not search_files and not search_words:
            logger.warning(f"You must provide files and/or words to search with")
            return []
        logger.info(f"Performing search with words: {search_words}")
        logger.info(f"Performing search with files: {search_files}")
        # check both paths starting with / and without - this is a bit of hackery but
        # needed to get around a weakness in regex parsing
        file_paths: list[str] = self.files.file_paths
        # add any basename matches, for case when build paths differ from source paths
        # potentially causes false positives but should mostly work for now
        # TODO: revisit build vs src paths
        repo_file_bases: list[str] = self.files.all_basenames
        search_files_bases: list[str] = [os.path.basename(sfp) for sfp in search_files]
        repo_basename_mapping = {}
        for sfb in search_files_bases:
            if sfb in self.files.all_basenames:
                for repo_file in self.files.all_files:
                    if sfb == repo_file.basename:
                        repo_basename_mapping[
                            repo_file.basename
                        ] = repo_file.relative_file_path

        search_files_bases = set([fp for fp in repo_basename_mapping.values()])

        slashed_file_paths: list[str] = [f"/{fp}" for fp in file_paths]
        logger.info(search_files)
        files_to_examine: list[str] = set(search_files).intersection(file_paths)
        slashed_files_to_examine: list[str] = set(search_files).intersection(
            slashed_file_paths
        )

        logger.info(
            f"Searching files: {files_to_examine}, {search_files_bases} and {slashed_files_to_examine}"
        )
        # recombine, remove slashes and unique entries
        search_in: list[str] = list(
            set(
                list(files_to_examine)
                + list(search_files_bases)
                + [fp[1:] for fp in slashed_files_to_examine]
            )
        )
        logger.info(f"SEARCH FILES: {search_in}")
        results: list[RepositorySearchResult] = []
        for fp in search_in:
            repo_file: RepositoryFile = self.files.files[fp]
            commits = self.get_commits_that_changed_file(repo_file.relative_file_path)
            rsr: RepositorySearchResult = RepositorySearchResult(
                source_file=repo_file,
                related_commits=commits,
            )
            # TODO: look at how we can accurately search file content
            results.append(rsr)

        return results

    def get_commits_that_changed_file(self, filename: str) -> list[GitCommit]:
        related_commits = []
        for gc in self.commit_history:
            if filename in gc.changed_files:
                related_commits.append(gc)
        return related_commits

    def serialize_git_commits(self, commit_list: list) -> list[GitCommit]:
        git_commits: list[GitCommit] = []
        for commit_data in commit_list:
            gc: GitCommit = GitCommit(
                _clone_directory=self.clone_directory,
                **commit_data,
            )
            logger.info(f"Serializing commit: {gc.sha} {gc.author_name}")
            git_commits.append(gc)
        return git_commits

    def get_git_log(self, num_commits: int = 10) -> list:
        # Define a delimiter that is unlikely to appear in commit messages
        delimiter = "\n<--commit-end-->\n"

        # Define the custom format for the git log output
        git_log_format = f"%H%n%an%n%ae%n%ad%n%B{delimiter}"

        # Run the git log command
        git_log_output = subprocess.run(
            ["git", "log", f"--pretty=format:{git_log_format}", "-n", str(num_commits)],
            text=True,
            capture_output=True,
            check=True,
            cwd=self.clone_directory,
        ).stdout

        # Split the output into individual commit blocks using the delimiter
        commit_blocks = git_log_output.strip().split(delimiter)

        # Parse each commit block into a dictionary
        commits = []
        for block in commit_blocks:
            if block.strip():  # Skip empty blocks
                commit_info = block.strip().split("\n", 4)
                if len(commit_info) == 5:
                    sha = commit_info[0]
                    dt = commit_info[3]
                    try:
                        dt = dateutil.parser.parse(dt)
                    except Exception as e:
                        logger.info(
                            f"Could not parse commit {sha} datetime string: {dt}, using as-is: {e}"
                        )
                        dt = commit_info[3]
                    commit_dict = {
                        "sha": sha,
                        "author_name": commit_info[1],
                        "author_email": commit_info[2],
                        "datetime_data": dt,
                        "message": commit_info[4].strip(),
                    }
                    commits.append(commit_dict)
        return commits

    def list_issues(self, state="open"):
        url = f"https://api.github.com/repos/{self.repo_owner}/{self.repo_name}/issues"
        headers = {
            "Authorization": f"token {self.auth_token}",
            "Accept": "application/vnd.github.v3+json",
        }
        params = {"state": state}

        response = requests.get(url, headers=headers, params=params)

        if response.status_code != 200:
            logger.warning(f"Error: {response.status_code}")
            return {}

        return response.json()

    def create_issue(self, title, body=None, labels=None, assignees=None):
        url = f"https://api.github.com/repos/{self.repo_owner}/{self.repo_name}/issues"
        headers = {
            "Authorization": f"token {self.auth_token}",
            "Accept": "application/vnd.github.v3+json",
        }
        data = {"title": title}
        if body:
            data["body"] = body
        if labels:
            data["labels"] = labels
        if assignees:
            data["assignees"] = assignees

        response = requests.post(url, headers=headers, json=data)

        if response.status_code != 201:
            logger.warning(f"Error: {response.status_code}, {response.text}")
            return {}

        return response.json()
