import re, json, logging
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


@dataclass
class StackTraceData:
    urls: list[str]
    # similar to urls, except just the API endpoints if found
    endpoints: list[str]
    files: list[str]
    error_messages: list[str]
    raw: str = field(default="", repr=False)
    # TODO: create a in-mem db of exception types
    # TODO: extract exception types and lookup in code
    # TODO: integration for generating log service URL

    @property
    def has_results(self):
        return (
            len(self.error_messages) > 0
            or len(self.urls) > 0
            or len(self.endpoints) > 0
            or len(self.files) > 0
            or len(self.error_messages) > 0
            or len(self.raw) > 0
        )


class BaseStackTraceParse:
    # TODO: pull from a chatgpt generated path list instead?
    # TODO: revisit filtering approach
    exclude_file_paths: list[str] = ["site-packages", "/html"]
    exclude_endpoints: list[str] = [
        "/python",
        "/opt/",
        "/lib/",
        "site-packages",
        "/1.1",
        "/html",
    ]
    # TODO: extract package names, include in next steps

    @staticmethod
    def is_json(data: str) -> bool:
        try:
            json.loads(data)
            return True
        except json.JSONDecodeError:
            return False

    @staticmethod
    def parse_log(log) -> StackTraceData:
        file_paths: list[str] = BaseStackTraceParse.extract_files(log)
        urls: list[str] = BaseStackTraceParse.extract_urls(log)
        endpoints: list[str] = BaseStackTraceParse.extract_endpoints(log)
        error_messages: list[str] = BaseStackTraceParse.extract_sentences(log)
        st_data = StackTraceData(
            urls=urls,
            endpoints=endpoints,
            files=file_paths,
            error_messages=error_messages,
            raw=log,
        )
        return st_data

    @staticmethod
    def extract_files(text, exclude_paths: list[str] = None) -> list[str]:
        if exclude_paths is None:
            exclude_paths = BaseStackTraceParse.exclude_file_paths
        # regex = r"/[\w/._-]+"
        regex = r"/[\w./_-]+\.[a-zA-Z0-9]+"
        results = re.findall(regex, text)
        results = [
            r
            for r in results
            if not any(exclude_path in r for exclude_path in exclude_paths)
        ]
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results

    @staticmethod
    def extract_urls(text) -> list[str]:
        regex = (
            r"(https?://|ftp://)[\w.-]+(?:\.[\w.-]+)+[\w/_-]*(?:(?:\?|\&amp;)[\w=]*)*"
        )
        results = re.findall(regex, text)
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results

    @staticmethod
    def extract_endpoints(text, exclude_paths: list[str] = None) -> list[str]:
        if exclude_paths is None:
            exclude_paths = BaseStackTraceParse.exclude_endpoints
        regex = r"/[a-zA-Z0-9/_-]+(?:/[a-zA-Z0-9/_-]+)*"
        results = re.findall(regex, text)
        results = [
            r
            for r in results
            if not any(exclude_paths in r for exclude_paths in exclude_paths)
        ]
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results

    @staticmethod
    def extract_sentences(text) -> list[str]:
        # note: must be at least 3 words to accept
        regex = r"\b[A-Z][a-z]*\s+[A-Za-z]+\s+[A-Za-z]+(?:\s+[A-Za-z]+)*[.,]?"
        results = re.findall(regex, text)
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results


class PythonStackTraceParse(BaseStackTraceParse):
    @staticmethod
    def parse_log(log) -> StackTraceData:
        if "stacktrace" in log or "Traceback" in log:
            return BaseStackTraceParse.parse_log(log)
        else:
            return None


class DRFStackTraceParse(PythonStackTraceParse):
    @staticmethod
    def parse_log(log) -> StackTraceData:
        st_data = None
        if BaseStackTraceParse.is_json(log):
            log = json.loads(log)
            if "detail" in log:
                PythonStackTraceParse.parse_log(log["detail"])
        else:
            st_data = PythonStackTraceParse.parse_log(log)
        return st_data


class GoogleDRFStackTraceParse(DRFStackTraceParse):
    @staticmethod
    def parse_log(log) -> StackTraceData:
        st_data = None
        if BaseStackTraceParse.is_json(log):
            log = json.loads(log)
            if "message" in log:
                log = log["message"]
                st_data = DRFStackTraceParse.parse_log(log)
            return st_data
        else:
            return st_data
