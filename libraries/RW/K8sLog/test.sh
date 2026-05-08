#!/bin/bash
# The test file is named with a leading underscore (`_test_log_filter.py`)
# so pytest's default `test_*.py` discovery skips it; we invoke it by path.
# Same convention as libraries/RW/K8sApplications/test.sh.
pytest --log-cli-level=DEBUG _test_log_filter.py
