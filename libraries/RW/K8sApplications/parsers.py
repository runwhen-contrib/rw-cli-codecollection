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
    occurences: int = 1
    # TODO: create a in-mem db of exception types
    # TODO: extract exception types and lookup in code
    # TODO: integration for generating log service URL

    def __eq__(self, other):
        if isinstance(other, StackTraceData):
            return (
                self.raw == other.raw
                and self.error_messages == other.error_messages
                and self.files == other.files
                and self.endpoints == other.endpoints
                and self.urls == other.urls
                and self.parser_used_type == other.parser_used_type
                and self.line_nums == other.line_nums
            )
        return False

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

    def get_first_file_line_nums_as_str(self) -> str:
        if len(self.line_nums.keys()) > 0:
            file_key = list(self.line_nums.keys())[0]
            line_nums = self.line_nums[file_key]
            formatted_line_nums = f"{file_key} on lines:"
            for l in line_nums:
                formatted_line_nums += f"{str(l)}, "
            return formatted_line_nums.rstrip(", ")
        else:
            return ""

    def __str__(self) -> str:
        urls_str: str = ", ".join(self.urls if self.urls else [""])
        endpoints_str: str = ", ".join(self.endpoints if self.endpoints else [""])
        files_str: str = ", ".join(self.files if self.files else [""])
        line_nums_str: str = ", ".join([f"{k}: {v}" for k, v in self.line_nums.items()])
        error_messages_str: str = ", ".join(self.error_messages if self.error_messages else [""])
        return f"StackTraceData: occurences: {self.occurences}, urls: {urls_str}, endpoints: {endpoints_str}, files: {files_str}, line_nums: {line_nums_str}, error_messages: {error_messages_str}\n\n{self.raw}"


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
        if show_debug:
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
    accepted_file_types: list[str] = [".py"]

    @staticmethod
    def extract_sentences(
        text,
        show_debug: bool = False,
    ) -> list[str]:
        results = []
        for line in text.split("\n"):
            if len(line) < 2:
                continue
            if line[0] != " " and line[-1] != " " and "Traceback" not in line and "The above exception" not in line:
                results.append(line)
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        return results

    @staticmethod
    def extract_line_nums(text, show_debug: bool = False, exclude_paths: list[str] = None) -> dict[str, list[int]]:
        # if exclude_paths is None:
        #     exclude_paths = BaseStackTraceParse.exclude_file_paths
        results = {}
        regex = r"([\.0-9-a-zA-Z/_]+\.py)"
        split_text = text.split("\n")
        for text_line in split_text:
            matches = re.findall(regex, text_line)
            if not matches:
                continue
            # matches = [m for m in matches if not any(exclude_path in m for exclude_path in exclude_paths)]
            logger.debug(f"extract_line_nums matches: {matches} from text_line: {text_line}")
            for m in matches:
                if not m:
                    continue
                if m not in results.keys():
                    results[m] = []
                    num_regex = r"line (\d+)"
                    line_nums = re.findall(num_regex, text_line)
                    for line_num in line_nums:
                        if line_num not in results[m]:
                            results[m].append(int(line_num))
        return results

    @staticmethod
    def extract_files(text, show_debug: bool = False, exclude_paths: list[str] = None) -> list[str]:
        results: list[str] = []
        if show_debug:
            logger.debug(f"extract_files from text: {text}")
        # if exclude_paths is None:
        #     exclude_paths = BaseStackTraceParse.exclude_file_paths
        regex = r"[\w./_-]+\.[a-zA-Z0-9]+"
        results = re.findall(regex, text)
        if show_debug:
            logger.debug(f"extract_files results: {results}")
        # results = [r for r in results if not any(exclude_path in r for exclude_path in exclude_paths)]
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        results = [
            r for r in results if any(r.endswith(file_type) for file_type in PythonStackTraceParse.accepted_file_types)
        ]
        return results

    @staticmethod
    def parse_log(log, show_debug: bool = True) -> StackTraceData:
        if "stacktrace" in log or "Traceback" in log:
            file_paths: list[str] = PythonStackTraceParse.extract_files(log, show_debug=show_debug)
            line_nums: dict[str, list[int]] = PythonStackTraceParse.extract_line_nums(log, show_debug=show_debug)
            urls: list[str] = BaseStackTraceParse.extract_urls(log, show_debug=show_debug)
            endpoints: list[str] = BaseStackTraceParse.extract_endpoints(log, show_debug=show_debug)
            error_messages: list[str] = PythonStackTraceParse.extract_sentences(log, show_debug=show_debug)
            st_data = StackTraceData(
                urls=urls,
                endpoints=endpoints,
                files=file_paths,
                line_nums=line_nums,
                error_messages=error_messages,
                raw=log,
            )
            return st_data
        else:
            return None


class DRFStackTraceParse(PythonStackTraceParse):
    @staticmethod
    def parse_log(log, show_debug: bool = True) -> StackTraceData:
        st_data = None
        if BaseStackTraceParse.is_json(log):
            log = json.loads(log)
            detail_lookup: dict = None
            detail_lookup = log.get("detail", None)
            while "detail" in detail_lookup.keys():
                detail_lookup = detail_lookup["detail"]
            if detail_lookup:
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


class GoLangStackTraceParse(BaseStackTraceParse):
    accepted_file_types: list[str] = [".go"]

    @staticmethod
    def parse_log(log, show_debug: bool = False) -> StackTraceData:
        file_paths: list[str] = GoLangStackTraceParse.extract_files(log, show_debug=show_debug)
        line_nums: dict[str, list[int]] = GoLangStackTraceParse.extract_line_nums(log, show_debug=show_debug)
        urls: list[str] = BaseStackTraceParse.extract_urls(log, show_debug=show_debug)
        endpoints: list[str] = GoLangStackTraceParse.extract_endpoints(log, show_debug=show_debug)
        error_messages: list[str] = GoLangStackTraceParse.extract_sentences(log, show_debug=show_debug)
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
    def extract_files(text, show_debug: bool = False, exclude_paths: list[str] = None) -> list[str]:
        results: list[str] = []
        results = BaseStackTraceParse.extract_files(text, show_debug=show_debug, exclude_paths=exclude_paths)
        results = [
            r for r in results if any(r.endswith(file_type) for file_type in GoLangStackTraceParse.accepted_file_types)
        ]
        if show_debug:
            logger.debug(f"extract_files golang results after filtering: {results}")
        return results

    @staticmethod
    def extract_endpoints(text, show_debug: bool = False, exclude_paths: list[str] = None) -> list[str]:
        results: list[str] = []
        if "api/" in text:
            results = BaseStackTraceParse.extract_endpoints(text, show_debug=show_debug, exclude_paths=exclude_paths)
            results = [r for r in results if "api/" in r]
        else:
            return []

    @staticmethod
    def extract_sentences(
        text,
        show_debug: bool = False,
    ) -> list[str]:
        # TODO: create a new regex with a stop symbol for lines without spaces
        # note: must be at least 3 words to accept
        split_text: list[str] = text.split("\n")
        filtered_result: list[str] = []
        for line in split_text:
            if ".go" not in line and " " in line:
                filtered_result.append(line)
        results = filtered_result
        deduplicated = []
        for r in results:
            if r not in deduplicated:
                deduplicated.append(r)
        results = deduplicated
        logger.debug(f"extract_sentences results: {results}")
        return results

    @staticmethod
    def extract_line_nums(text, show_debug: bool = False, exclude_paths: list[str] = None) -> dict[str, list[int]]:
        if exclude_paths is None:
            exclude_paths = BaseStackTraceParse.exclude_file_paths
        results = {}
        regex = r"([_@0-9a-zA-Z/\.]+)"
        split_text = text.split("\n")
        for text_line in split_text:
            text_line = text_line.strip()
            if ".go" not in text_line:
                continue
            if not text_line:
                continue
            matches = re.findall(regex, text_line)
            matches = [m for m in matches if not any(exclude_path in m for exclude_path in exclude_paths)]
            matches = [m for m in matches if ".go" in m]
            if not matches:
                continue
            if len(matches) != 1:
                continue
            go_file_match = matches[0]
            if ":" in text_line:
                line_num = text_line.split(":")[-1]
                if go_file_match not in results.keys():
                    results[go_file_match] = []
                if line_num not in results[go_file_match]:
                    results[go_file_match].append(int(line_num))
        logger.debug(f"extract_line_nums results: {results}")
        return results


class GoLangJsonStackTraceParse(GoLangStackTraceParse):
    @staticmethod
    def parse_log(log, show_debug: bool = False) -> StackTraceData:
        if BaseStackTraceParse.is_json(log):
            log = json.loads(log)
            stacktrace_error = log.get("error", None)
            stacktrace_str = log.get("stacktrace", None)
            log = f"{stacktrace_error}\n{stacktrace_str}"
            st_data = GoLangStackTraceParse.parse_log(log, show_debug=show_debug)
            return st_data
        else:
            return None


# lookup map used for dynamic parser selection
DYNAMIC_PARSER_LOOKUP = {
    "dynamic": None,
    "python": PythonStackTraceParse,
    "golang": GoLangStackTraceParse,
    "golangjson": GoLangJsonStackTraceParse,
    "csharp": CSharpStackTraceParse,
    "django": DRFStackTraceParse,
    "djangojson": GoogleDRFStackTraceParse,
    "java": None,
    "node": None,
}
