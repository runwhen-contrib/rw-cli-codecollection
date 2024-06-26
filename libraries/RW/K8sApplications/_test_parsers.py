import os, logging
from RW.K8sApplications.parsers import *
from RW.K8sApplications.k8s_applications import parse_stacktraces, ParseMode
from RW.K8sApplications.parsers import BaseStackTraceParse, PythonStackTraceParse

logger = logging.getLogger(__name__)

THIS_DIR: str = "/".join(__file__.split("/")[:-1])
TEST_DATA_DIR = "test_data"
MAX_LOG_LINES: int = 1025


def test_python_parser():
    with open(f"{THIS_DIR}/{TEST_DATA_DIR}/python.log", "r") as f:
        data = f.read()
    if len(data) > MAX_LOG_LINES:
        logger.warning(
            f"Length of logs provided for parsing stacktraces is greater than {MAX_LOG_LINES}, be aware this could effect performance"
        )
    print(f"Log data: {data}")
    results = parse_stacktraces(
        data, parse_mode=ParseMode.MULTILINE_LOG, parser_override=PythonStackTraceParse, show_debug=True
    )
    print(f"Result: {results}")
    assert len(results) > 0


if __name__ == "__main__":
    test_python_parser()
