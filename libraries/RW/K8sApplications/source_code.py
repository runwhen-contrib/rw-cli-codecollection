import subprocess
import os
import logging
import json

from typing import List
from pathlib import Path
from dataclasses import dataclass, field

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
    _diff: str = field(default=None, repr=False, init=False)

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


@dataclass
class SourceCodeSearchResult:
    line_num: int
    source_file: "SourceCodeFile"


@dataclass
class SourceCodeFile:
    git_file_url: str
    relative_file_path: str
    absolute_file_path: str
    line_count: int
    git_url_base: str
    filesystem_basepath: str
    branch: str

    def __init__(self, absolute_filepath, filesystem_basepath, repo_base_url, branch="main") -> None:
        self.absolute_file_path = str(absolute_filepath)
        self.git_url_base = str(repo_base_url)
        self.branch = branch
        self.relative_file_path = str(Path(self.absolute_file_path).relative_to(filesystem_basepath))
        # logger.info(f"Counting: {self.absolute_file_path}")
        self.line_count = sum(1 for line in open(self.absolute_file_path) if line.strip())
        self.git_file_url = f"{self.git_url_base}/blob/{self.branch}/{self.relative_file_path}"

    def search(self, search_term: str) -> SourceCodeSearchResult:
        # do not implement this stub
        return None


@dataclass
class SourceCodeFiles:
    files: dict[str, SourceCodeFile]

    def __init__(self) -> None:
        self.files = {}

    def add_source_file(self, src_file: SourceCodeFile) -> None:
        self.files[src_file.relative_file_path] = src_file


class SourceCode:
    EXCLUDE_PATHS: list[str] = [
        ".git",
        ".gitmodules",
    ]
    EXCLUDE_EXT: list[str] = [".png", ".jpg", ".jpeg", ".ico"]
    source_uri: str
    auth_token: str
    files: SourceCodeFiles
    clone_directory: str
    branch: str
    commit_history: list[GitCommit] = []

    def __str__(self):
        file_summary = f"Number of files: {len(self.files.files)}"
        branch_summary = f"Branch: {self.branch}"
        repo_summary = f"Repository URI: {self.source_uri}"
        commit_summary = "Recent Commits:\n"
        commit_seperator = "--------------\n"
        for commit in self.commit_history:  # Show the last 5 commits as an example
            commit_summary += f"{commit_seperator}{commit.sha[:7]} by {commit.author_name} on {commit.date}: {commit.message[:50]}{'...' if len(commit.message) > 50 else ''}\n"
        return f"{repo_summary}\n{branch_summary}\n{file_summary}\n{commit_summary}"

    def __init__(self, source_uri: str, auth_token: platform.Secret = None, branch="main") -> None:
        self.source_uri = source_uri
        if auth_token:
            self.auth_token = auth_token.value
        else:
            self.auth_token = None
        self.files = SourceCodeFiles()
        self.branch = branch

    def clone_repo(
        self,
        num_commits_history: int = 10,
    ) -> str:
        repo_name = self.source_uri.split("/")[-1]
        if repo_name.endswith(".git"):
            repo_name = repo_name[:-4]
        self.clone_directory = f"/tmp/{repo_name}"

        # Ensure the target directory is clean
        if os.path.exists(self.clone_directory):
            subprocess.run(["rm", "-rf", self.clone_directory], check=True)
        os.makedirs(self.clone_directory, exist_ok=True)

        # Modify the Git URI to include the token for authentication
        if "https://" in self.source_uri and self.auth_token:
            auth_uri = self.source_uri.replace("https://", f"https://oauth2:{self.auth_token}@")
        elif "https://":
            auth_uri = self.source_uri
        else:
            raise ValueError("Unsupported Git URI. Please use HTTPS URL for cloning with a token.")

        # Execute the Git clone command with the modified URI
        subprocess.run(
            ["git", "clone", "--branch", self.branch, "--single-branch", auth_uri, self.clone_directory],
            check=True,
            env={"GIT_TERMINAL_PROMPT": "0"},
        )

        self.create_file_list()
        self.commit_history = self.serialize_git_commits(self.get_git_log(num_commits_history))
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
                if name not in SourceCode.EXCLUDE_PATHS and all(ext not in name for ext in SourceCode.EXCLUDE_EXT):
                    file_path = os.path.join(root, name)
                    if not SourceCode.is_text_file(file_path=file_path):
                        continue
                    src_file = SourceCodeFile(
                        absolute_filepath=file_path,
                        filesystem_basepath=self.clone_directory,
                        repo_base_url=self.get_repo_base_url(),
                        branch=self.branch,
                    )
                    self.files.add_source_file(src_file)

    def search(self, search_term: str, file_path: str) -> [SourceCodeSearchResult]:
        # iterates over source files and calls their search method with the search_term, returning a list of SourceCodeSearchResult
        pass

    def serialize_git_commits(self, commit_list: list) -> list[GitCommit]:
        git_commits: list[GitCommit] = []
        for commit_data in commit_list:
            gc: GitCommit = GitCommit(**commit_data)
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
