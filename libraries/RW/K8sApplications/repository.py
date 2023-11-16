import subprocess
import os
import logging
import json
import re

from typing import List
from pathlib import Path
from dataclasses import dataclass, field
from thefuzz import process as fuzzprocessor

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)


@dataclass
class GitCommit:
    sha: str
    author_name: str
    author_email: str
    date: str
    message: str
    _filesystem_path: str
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
            cwd=self._filesystem_path,
        )

        # changed_files_output = subprocess.run(
        #     [
        #         "git",
        #         "diff",
        #         "--name-only",
        #         "9d8696ccc4b1d280b08bcb4197a673b321ad9e7c^!",
        #     ],
        #     text=True,
        #     capture_output=True,
        #     check=True,
        # )
        logger.info(f"git err: {changed_files_output.stderr}")
        logger.info(f"git stdout: {changed_files_output.stdout}")
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
    line_num: int
    source_file: "RepositoryFile"
    related_commits: list[GitCommit]


@dataclass
class RepositoryFile:
    git_file_url: str
    relative_file_path: str
    absolute_file_path: str
    line_count: int
    git_url_base: str
    filesystem_basepath: str
    branch: str
    content: str = field(repr=False)

    def __init__(
        self, absolute_filepath, filesystem_basepath, repo_base_url, branch="main"
    ) -> None:
        self.absolute_file_path = str(absolute_filepath)
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
        return None


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

    def __str__(self):
        repo_summary = f"Repository: {self.repo_owner}/{self.repo_name}\nRepository URI: {self.source_uri}"
        file_summary = f"Number of files: {len(self.files.files)}"
        branch_summary = f"Branch: {self.branch}"
        commit_summary = "Recent Commits:\n"
        commit_seperator = "--------------\n"
        for commit in self.commit_history:  # Show the last 5 commits as an example
            commit_summary += f"{commit_seperator}{commit.sha[:7]} by {commit.author_name} on {commit.date}: {commit.message[:50]}{'...' if len(commit.message) > 50 else ''}\n"
        return f"{repo_summary}\n{branch_summary}\n{file_summary}\n{commit_summary}"

    def __init__(
        self, source_uri: str, auth_token: platform.Secret = None, branch="main"
    ) -> None:
        self.source_uri = source_uri
        self.repo_url = self.get_repo_base_url()
        # get owner and repo name from uri
        parts = (
            self.repo_url.replace("https://github.com/", "")
            .replace("git@github.com:", "")
            .rstrip(".git")
            .split("/")
        )
        self.repo_owner = parts[0]
        self.repo_name = parts[1]
        if auth_token:
            self.auth_token = auth_token.value
        else:
            self.auth_token = None
        self.files = RepositoryFiles()
        self.branch = branch

    def clone_repo(
        self,
        num_commits_history: int = 10,
        cache: bool = True,
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

        if not cache:
            # Execute the Git clone command with the modified URI
            subprocess.run(
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

        self.create_file_list()
        self.commit_history = self.serialize_git_commits(
            self.get_git_log(num_commits_history)
        )
        return self.clone_directory

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
        search_words: list[str],
        search_files: list[str],
        max_results_per_word: int = 5,
        search_match_score_min: int = 90,
    ) -> [RepositorySearchResult]:
        logger.info(f"Performing search with words: {search_words}")
        # check both paths starting with / and without - this is a bit of hackery but
        # needed to get around a weakness in regex parsing
        file_paths: list[str] = self.files.file_paths
        slashed_file_paths: list[str] = [f"/{fp}" for fp in file_paths]
        logger.info(search_files)
        files_to_examine: list[str] = set(search_files).intersection(file_paths)
        slashed_files_to_examine: list[str] = set(search_files).intersection(
            slashed_file_paths
        )
        logger.info(
            f"Searching files: {files_to_examine} and {slashed_files_to_examine}"
        )
        # recombine, remove slashes and unique entries
        search_in: list[str] = list(
            set(list(files_to_examine) + [fp[1:] for fp in slashed_files_to_examine])
        )
        logger.info(f"SEARCHIN: {search_in}")
        matches: RepositorySearchResult = []
        # avoids bad query strings submitted to fuzz lib
        skip_regex = r"^[ \t\n\r#*,(){}\[\]\"\'\':]*$"
        for fp in search_in:
            repo_file: RepositoryFile = self.files.files[fp]
            # file_content: list[str] = repo_file.content.split("\n")
            # for i, fc in enumerate(file_content):
            #     line_num: int = i + 1
            #     if re.match(skip_regex, fc):
            #         continue
            #     extract_result = fuzzprocessor.extract(fc, search_words, limit=1)
            #     if extract_result[0][1] > search_match_score_min:
            #         matches.append(
            #             RepositorySearchResult(
            #                 line_num=line_num, source_file=repo_file, related_commits=[]
            #             )
            #         )
            # TODO: git diff lookups
            # TODO: look at exception type lookup table
        for match_result in matches:
            for commit in self.commit_history:
                if match_result.source_file.relative_file_path in commit.changed_files:
                    match_result.related_commits.append(commit)
        return matches

    def serialize_git_commits(self, commit_list: list) -> list[GitCommit]:
        git_commits: list[GitCommit] = []
        for commit_data in commit_list:
            gc: GitCommit = GitCommit(
                _filesystem_path=self.clone_directory,
                **commit_data,
            )
            logger.info(f"Serializing commit: {gc.sha} {gc.author_name}")
            git_commits.append(gc)
        return git_commits

    def get_git_log(self, num_commits: int = 10) -> list:
        # Define the custom format for the git log output
        git_log_format = "%H%n%an%n%ae%n%ad%n%B"

        # Run the git log command
        git_log_output = subprocess.run(
            [
                "git",
                "-C",
                self.clone_directory,
                "log",
                f"--pretty=format:{git_log_format}",
                "-n",
                str(num_commits),
            ],
            check=True,
            text=True,
            capture_output=True,
        ).stdout
        # logger.info(f"git log: {git_log_output}")
        # Split the output into individual commit blocks
        commit_blocks = git_log_output.strip().split("\n\n")
        # Parse each commit block into a dictionary
        commits = []
        for block in commit_blocks:
            if block.strip():  # Skip empty blocks
                commit_info = block.strip().split(
                    "\n", 4
                )  # Expect 5 parts: sha, author_name, author_email, date, message
                if len(commit_info) == 5:
                    commit_dict = {
                        "sha": commit_info[0],
                        "author_name": commit_info[1],
                        "author_email": commit_info[2],
                        "date": commit_info[3],
                        "message": commit_info[4].strip(),
                    }
                    commits.append(commit_dict)
        return commits

    def create_issue(self, title, body):
        # TODO: convert to rw.cli
        url = f"https://api.github.com/repos/{self.repo_owner}/{self.repo_name}/issues"
        data = {"title": title, "body": body}
        result = subprocess.run(
            [
                "curl",
                "-L",
                "-X",
                "POST",
                "-H",
                f"Authorization: token {self.auth_token}",
                "-H",
                "Accept: application/vnd.github.v3+json",
                "-d",
                json.dumps(data),
                url,
            ],
            capture_output=True,
            text=True,
        )
        if result.stderr:
            print("Error:", result.stderr)

    def list_issues(self):
        # TODO: convert to rw.cli
        url = f"https://api.github.com/repos/{self.repo_owner}/{self.repo_name}/issues"
        result = subprocess.run(
            [
                "curl",
                "-L",
                "-H",
                f"Authorization: token {self.auth_token}",
                "-H",
                "Accept: application/vnd.github.v3+json",
                url,
            ],
            capture_output=True,
            text=True,
        )
        if result.stderr:
            print("Error:", result.stderr)
        results = json.loads(result.stdout)
        return results
