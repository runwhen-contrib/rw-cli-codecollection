import subprocess
import os
import logging

from typing import List
from pathlib import Path
from dataclasses import dataclass

from RW import platform
from RW.Core import Core

logger = logging.getLogger(__name__)


@dataclass
class SourceCodeSearchResult:
    line_num: int
    source_file: "SourceCodeFile"


class SourceCodeFile:
    git_file_url: str
    relative_file_path: str
    absolute_file_path: str
    line_count: int
    git_url_base: str
    filesystem_basepath: str
    branch: str

    def __init__(self, absolute_filepath, filesystem_basepath, repo_base_url, branch="main") -> None:
        self.absolute_file_path = absolute_filepath
        self.git_url_base = repo_base_url
        self.branch = branch
        self.relative_file_path = Path(self.absolute_file_path).relative_to(filesystem_basepath)
        self.line_count = sum(1 for line in open(self.absolute_file_path) if line.strip())
        self.git_file_url = f"{self.git_url_base}/blob/{self.branch}/{self.relative_file_path}"

    def search(self, search_term: str) -> SourceCodeSearchResult:
        # do not implement this stub
        return None


class SourceCodeFiles:
    files: dict[str, SourceCodeFile] = {}

    def add_source_file(self, src_file: SourceCodeFile) -> None:
        self.files[src_file.file_path] = src_file


class SourceCode:
    source_uri: str
    auth_token: str
    files: SourceCodeFiles
    clone_dectory: str
    branch: str

    def __init__(self, source_uri: str, auth_token: platform.Secret = None, branch="main") -> None:
        self.source_uri = source_uri
        self.auth_token = auth_token.value
        self.files = SourceCodeFiles()
        self.branch = branch

    def clone_repo(self) -> str:
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
        return self.clone_directory

    def get_repo_base_url(self) -> str:
        remote_url = self.source_uri
        if remote_url.startswith("git@"):
            remote_url = remote_url.replace(":", "/").replace("git@", "https://")
        if remote_url.endswith(".git"):
            remote_url = remote_url[:-4]
        return remote_url

    def create_file_list(self) -> None:
        for root, dirs, files in os.walk(self.clone_dectory):
            for name in files:
                file_path = os.path.join(root, name)
                src_file = SourceCodeFile(
                    absolute_filepath=file_path,
                    filesystem_basepath=self.clone_dectory,
                    repo_base_url=self.get_repo_base_url(),
                    branch=self.branch,
                )
                self.files.add_source_file(src_file)

    def search(self, search_term: str, file_path: str) -> [SourceCodeSearchResult]:
        # iterates over source files and calls their search method with the search_term, returning a list of SourceCodeSearchResult
        pass
