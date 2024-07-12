import os, logging
from RW.K8sApplications.parsers import *
from RW.K8sApplications.k8s_applications import (
    parse_stacktraces,
    ParseMode,
    stacktrace_report,
    stacktrace_report_data,
    parse_django_json_stacktraces,
    dynamic_parse_stacktraces,
)
from RW.K8sApplications.parsers import (
    BaseStackTraceParse,
    PythonStackTraceParse,
    GoLangStackTraceParse,
    GoogleDRFStackTraceParse,
)

logger = logging.getLogger(__name__)

THIS_DIR: str = "/".join(__file__.split("/")[:-1])
TEST_DATA_DIR = "test_data"
MAX_LOG_LINES: int = 1025


def test_python_parser():
    logger.info("Testing python parser")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/python.log", "r") as f:
        data = f.read()
    print(f"Log data: {data}")
    results = parse_stacktraces(
        data, parse_mode=ParseMode.MULTILINE_LOG, parser_override=PythonStackTraceParse, show_debug=True
    )
    print(f"Result: {results}")
    assert len(results) > 0
    assert "OperationalError:" in results[0].error_messages[0]
    assert len(results[0].files) > 2
    assert results[0].line_nums["/path/to/your/virtualenv/lib/python3.8/site-packages/django/db/utils.py"] == [90]
    assert results[0].parser_used_type == "PythonStackTraceParse"


def test_google_drf_parser():
    logger.info("Testing Google DRF parser")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/djangojson.log", "r") as f:
        data = f.read()
    # first_line = data.split("\n")[0]
    print(f"Log data: {data}")
    results = parse_django_json_stacktraces(data, show_debug=True)
    print(f"Result: {results}")
    r = stacktrace_report(results)
    print(f"REPORT\n\n{r}\n\n")
    assert len(results) > 0


def test_golang_parser():
    logger.info("Testing golang parser")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/golang.log", "r") as f:
        data = f.read()
    print(f"Log data: {data}")
    results = parse_stacktraces(
        data, parse_mode=ParseMode.MULTILINE_LOG, parser_override=GoLangStackTraceParse, show_debug=True
    )
    print(f"Result: {results}")
    assert len(results) > 0
    assert results[0].urls == []
    assert results[0].endpoints == []
    assert "/src/handlers.go" in results[0].files
    assert results[0].line_nums["/src/handlers.go"] == [69]
    assert results[0].line_nums["/src/middleware.go"] == [82, 109]


def test_golang_report():
    logger.info("Testing Report")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/golang.log", "r") as f:
        data = f.read()
    if len(data) > MAX_LOG_LINES:
        logger.warning(
            f"Length of logs provided for parsing stacktraces is greater than {MAX_LOG_LINES}, be aware this could effect performance"
        )
    results = parse_stacktraces(
        data, parse_mode=ParseMode.MULTILINE_LOG, parser_override=GoLangStackTraceParse, show_debug=True
    )
    r = stacktrace_report(results)
    print(f"REPORT\n\n{r}\n\n")


def test_golangjson_parse():
    logger.info("Testing Golang Json Parser")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/golangjson.log", "r") as f:
        data = f.read()
    results = parse_stacktraces(
        data, parse_mode=ParseMode.SPLIT_INPUT, parser_override=GoLangJsonStackTraceParse, show_debug=True
    )
    logger.info(f"Results: {results}")


def test_no_results():
    r = stacktrace_report([])
    logger.info(f"REPORT\n\n{r}\n\n")


def test_dynamic():
    logger.info("Testing dynamic parser")
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/djangojson.log", "r") as f:
        data = f.read()
    results = dynamic_parse_stacktraces(data, parser_name="Dynamic", parse_mode=ParseMode.SPLIT_INPUT, show_debug=True)
    r = stacktrace_report_data(results)
    mcst = r["most_common_stacktrace"]
    report = r["report"]
    assert report
    assert mcst
