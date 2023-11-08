from .source_code import SourceCode, SourceCodeFile, SourceCodeFiles, SourceCodeSearchResult
from RW import CLI
from RW import platform
from RW.Core import Core


def test(git_uri, git_token):
    sc = SourceCode(source_uri=git_uri, auth_token=git_token)
    sc.clone_repo()
