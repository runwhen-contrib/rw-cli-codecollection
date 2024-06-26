import re, json, logging
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


@dataclass
class StackTraceData:
    urls: list[str]
    # similar to urls, except just the API endpoints if found
    endpoints: list[str]
    files: list[str]
    line_nums: dict[str, list[int]]  # line numbers associated with exceptions per file
    error_messages: list[str]
    raw: str = field(default="", repr=False)
    parser_used_type: "BaseStackTraceParse" = None
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

    @property
    def errors_summary(self) -> str:
        return ", ".join(self.error_messages)

    @property
    def first_file(self) -> str:
        if len(self.files) > 0:
            return self.files[0]
        else:
            return ""

    @property
    def first_line_nums(self) -> list[int]:
        if len(self.line_nums.keys()) > 0:
            return list(self.line_nums.values())[0]
        else:
            return []

    def __str__(self) -> str:
        urls_str: str = ", ".join(self.urls)
        endpoints_str: str = ", ".join(self.endpoints)
        files_str: str = ", ".join(self.files)
        line_nums_str: str = ", ".join([f"{k}: {v}" for k, v in self.line_nums.items()])
        error_messages_str: str = ", ".join(self.error_messages)
        return f"StackTraceData: urls: {urls_str}, endpoints: {endpoints_str}, files: {files_str}, line_nums: {line_nums_str}, error_messages: {error_messages_str}"


class BaseStackTraceParse:
    """Base class for stacktrace parsing functions.
    Should be stateless so it can be used as a utility class.

    Note that the default behavior assumes python stack traces, and inheritors can override for other languages.

    """

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
    def parse_log(log, show_debug: bool = False) -> StackTraceData:
        file_paths: list[str] = BaseStackTraceParse.extract_files(log, show_debug=show_debug)
        line_nums: dict[str, list[int]] = BaseStackTraceParse.extract_line_nums(log, show_debug=show_debug)
        urls: list[str] = BaseStackTraceParse.extract_urls(log, show_debug=show_debug)
        endpoints: list[str] = BaseStackTraceParse.extract_endpoints(log, show_debug=show_debug)
        error_messages: list[str] = BaseStackTraceParse.extract_sentences(log, show_debug=show_debug)
        st_data = StackTraceData(
            urls=urls,
            endpoints=endpoints,
            files=file_paths,
            line_nums=line_nums,
            error_messages=error_messages,
            raw=log,
        )
        return st_data

    @staticmethod
    def extract_line_nums(text, show_debug: bool = False, exclude_paths: list[str] = None) -> dict[str, list[int]]:
        if exclude_paths is None:
            exclude_paths = BaseStackTraceParse.exclude_file_paths
        results = {}
        regex = r"[\w./_-]+\.[a-zA-Z0-9]+"
        split_text = text.split("\n")
        for text_line in split_text:
            matches = re.findall(regex, text_line)
            matches = [m for m in matches if not any(exclude_path in m for exclude_path in exclude_paths)]
            logger.debug(f"extract_line_nums matches: {matches} from text_line: {text_line}")
            for m in matches:
                if m not in results.keys():
                    results[m] = []
                regex = r"line (\d+)"
                line_nums = re.findall(regex, text_line)
                for line_num in line_nums:
                    if line_num not in results[m]:
                        results[m].append(int(line_num))
        return results

    @staticmethod
    def extract_files(text, show_debug: bool = False, exclude_paths: list[str] = None) -> list[str]:
        if show_debug:
            logger.debug(f"extract_files from text: {text}")
        if exclude_paths is None:
            exclude_paths = BaseStackTraceParse.exclude_file_paths
        regex = r"[\w./_-]+\.[a-zA-Z0-9]+"
        results = re.findall(regex, text)
        logger.debug(f"extract_files results: {results}")
        results = [r for r in results if not any(exclude_path in r for exclude_path in exclude_paths)]
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results

    @staticmethod
    def extract_urls(text, show_debug: bool = False) -> list[str]:
        regex = r"(https?://|ftp://)[\w.-]+(?:\.[\w.-]+)+[\w/_-]*(?:(?:\?|\&amp;)[\w=]*)*"
        results = re.findall(regex, text)
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results

    @staticmethod
    def extract_endpoints(text, show_debug: bool = False, exclude_paths: list[str] = None) -> list[str]:
        if exclude_paths is None:
            exclude_paths = BaseStackTraceParse.exclude_endpoints
        regex = r"/[a-zA-Z0-9/_-]+(?:/[a-zA-Z0-9/_-]+)*"
        results = re.findall(regex, text)
        results = [r for r in results if not any(exclude_paths in r for exclude_paths in exclude_paths)]
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results

    @staticmethod
    def extract_sentences(
        text,
        show_debug: bool = False,
    ) -> list[str]:
        # note: must be at least 3 words to accept
        regex = r"\b[A-Z][a-z]*\s+[A-Za-z]+\s+[A-Za-z]+(?:\s+[A-Za-z]+)*[.,]?"
        results = re.findall(regex, text)
        # if we did not get any results with a fine grained match, try a more general match
        if not results:
            results = re.findall(r".*error.*", text, re.IGNORECASE)
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results


class CSharpStackTraceParse(BaseStackTraceParse):
    @staticmethod
    def parse_log(log, show_debug: bool = True) -> StackTraceData:
        if ".Exception" in log or bool(re.search(r"at.*in", log)):
            return BaseStackTraceParse.parse_log(log, show_debug=show_debug)
        else:
            return None


class PythonStackTraceParse(BaseStackTraceParse):
    @staticmethod
    def parse_log(log, show_debug: bool = True) -> StackTraceData:
        if "stacktrace" in log or "Traceback" in log:
            return BaseStackTraceParse.parse_log(log, show_debug=show_debug)
        else:
            return None


class DRFStackTraceParse(PythonStackTraceParse):
    @staticmethod
    def parse_log(log, show_debug: bool = True) -> StackTraceData:
        st_data = None
        if BaseStackTraceParse.is_json(log):
            log = json.loads(log)
            if "detail" in log:
                PythonStackTraceParse.parse_log(log["detail"], show_debug=show_debug)
        else:
            st_data = PythonStackTraceParse.parse_log(log, show_debug=show_debug)
        return st_data


class GoogleDRFStackTraceParse(DRFStackTraceParse):
    @staticmethod
    def parse_log(log, show_debug: bool = True) -> StackTraceData:
        st_data = None
        if BaseStackTraceParse.is_json(log):
            log = json.loads(log)
            if "message" in log:
                log = log["message"]
                st_data = DRFStackTraceParse.parse_log(log, show_debug=show_debug)
            return st_data
        else:
            return st_data
