import requests
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from thefuzz import fuzz
from thefuzz import process as fuzzprocessor

from robot.api.deco import keyword
from RW import platform


class Jenkins:
    """
    This Robot Framework library exposes its keywords so that each one
    accepts jenkins_url, jenkins_username, and jenkins_token directly.

    The `jenkins_username` and `jenkins_token` parameters are expected
    to be `platform.Secret` objects, so we do `jenkins_username.value`
    and `jenkins_token.value` to retrieve the actual strings.

    Example usage in Robot:

    *** Settings ***
    Library   Jenkins

    *** Variables ***
    ${JENKINS_URL}      https://my-jenkins.example
    ${JENKINS_USERNAME}  MyJenkinsUsernameSecret
    ${JENKINS_TOKEN}     MyJenkinsTokenSecret

    *** Test Cases ***
    List Recent Failed Tests in Jenkins
        ${failed_tests}=    Get Failed Tests    ${JENKINS_URL}    ${JENKINS_USERNAME}    ${JENKINS_TOKEN}
        Log    Found ${len(${failed_tests})} unstable builds
    """

    def __init__(self):
        # We don't store credentials or Jenkins data at construction time
        pass

    def _fetch_jenkins_data(
        self,
        jenkins_url: str,
        jenkins_username: platform.Secret,
        jenkins_token: platform.Secret
    ):
        """
        Helper method that calls Jenkins at /api/json?depth=2 and returns the parsed JSON.
        Raises ConnectionError if the request fails.
        """
        api_url = f"{jenkins_url}/api/json?depth=2"
        # Extract the actual secret values for Basic Auth
        auth = (jenkins_username.value, jenkins_token.value)
        try:
            response = requests.get(api_url, auth=auth, timeout=10)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            raise ConnectionError(f"Failed to fetch data from Jenkins: {e}")

    @keyword("Get Failed Tests")
    def get_failed_tests(
        self,
        jenkins_url: str,
        jenkins_username: platform.Secret,
        jenkins_token: platform.Secret
    ):
        """
        Returns a list of pipelines in the 'UNSTABLE' state along with their failed tests.

        Example:
        | ${failed_tests}=    Get Failed Tests    ${JENKINS_URL}    ${JENKINS_USERNAME}    ${JENKINS_TOKEN} |
        | FOR  ${pipeline}  IN  @{failed_tests} |
        |    Log  Pipeline name: ${pipeline['pipeline_details']['pipeline_name']} |
        |    Log  Test results:  ${pipeline['test_results']}                     |
        | END |
        """
        jenkins_data = self._fetch_jenkins_data(jenkins_url, jenkins_username, jenkins_token)
        # For requests during test-report fetching:
        auth = (jenkins_username.value, jenkins_token.value)

        failed_tests = []
        for job in jenkins_data.get('jobs', []):
            last_build = job.get('lastBuild') or {}
            if last_build.get('result') == 'UNSTABLE':
                pipeline_details = {
                    'pipeline_name': job.get('name'),
                    'pipeline_url': job.get('url'),
                    'build_result': last_build.get('result'),
                    'build_number': last_build.get('number'),
                    'build_timestamp': last_build.get('timestamp'),
                    'build_duration': last_build.get('duration'),
                    'build_queueId': last_build.get('queueId'),
                    'build_building': last_build.get('building'),
                    'build_changeSet': last_build.get('changeSet')
                }
                try:
                    test_report_url = f"{last_build.get('url')}testReport/api/json"
                    tests_response = requests.get(test_report_url, auth=auth, timeout=10)
                    tests_response.raise_for_status()
                    suites = tests_response.json().get('suites', [])
                    test_results = []
                    for suite in suites:
                        for case in suite.get('cases', []):
                            test_results.append(case)
                except requests.exceptions.RequestException as e:
                    raise ConnectionError(f"Failed to fetch test data from Jenkins: {e}")

                failed_tests.append({
                    "pipeline_details": pipeline_details,
                    "test_results": test_results
                })

        return failed_tests

    @keyword("Get Queued Builds")
    def get_queued_builds(
        self,
        jenkins_url: str,
        jenkins_username: platform.Secret,
        jenkins_token: platform.Secret,
        wait_threshold: str = "10m"
    ):
        """
        Get builds waiting in queue longer than the specified threshold (e.g., '10m', '1h', '1d').

        Returns a list of dictionaries with details of each queued build.

        Example usage in Robot:
        | ${queued_builds}= | Get Queued Builds | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} | 15m |
        | FOR  ${build}  IN  @{queued_builds} |
        |    Log  Job ${build['job_name']} has been queued for ${build['wait_time']}. |
        | END |
        """
        wt = wait_threshold.lower().replace(' ', '').strip('"').strip("'")
        threshold_value = 0
        if 'min' in wt:
            threshold_value = int(wt.replace('min', ''))
        elif 'h' in wt:
            threshold_value = int(wt.replace('h', '')) * 60
        elif 'm' in wt:
            threshold_value = int(wt.replace('m', ''))
        elif 'day' in wt:
            threshold_value = int(wt.replace('day', '')) * 24 * 60
        elif 'd' in wt:
            threshold_value = int(wt.replace('d', '')) * 24 * 60
        else:
            raise ValueError(
                "Invalid threshold format. Use '10min', '1h', '30m', '1d', '1day', etc."
        )

        # Use .value to extract the actual username/token
        auth = (jenkins_username.value, jenkins_token.value)
        queue_url = f"{jenkins_url}/queue/api/json"
        queued_builds = []

        try:
            queue_response = requests.get(queue_url, auth=auth, timeout=10)
            queue_response.raise_for_status()
            queue_data = queue_response.json()

            current_time = int(time.time() * 1000)
            for item in queue_data.get('items', []):
                in_queue_since = item.get('inQueueSince', 0)
                wait_time_mins = (current_time - in_queue_since) / (1000 * 60)

                if wait_time_mins >= threshold_value:
                    if wait_time_mins >= 24*60:
                        wait_time = f"{wait_time_mins/(24*60):.1f}d"
                    elif wait_time_mins >= 60:
                        wait_time = f"{wait_time_mins/60:.1f}h"
                    else:
                        wait_time = f"{wait_time_mins:.1f}min"

                    job_name = item.get('task', {}).get('name', '')
                    if not job_name:
                        try:
                            queued_build_url = item.get('url', '')
                            if queued_build_url:
                                queued_build_url = f"{jenkins_url}/{queued_build_url}api/json?depth=1"
                                rsp = requests.get(queued_build_url, auth=auth, timeout=10).json()
                                job_name = rsp.get('task', {}).get('name', 'Unknown Job')
                            else:
                                job_name = 'Unknown Job'
                        except requests.exceptions.RequestException:
                            job_name = 'Unknown Job'

                    queued_builds.append({
                        'job_name': job_name,
                        'waiting_since': in_queue_since,
                        'wait_time': wait_time,
                        'why': item.get('why', 'Unknown Reason'),
                        'stuck': item.get('stuck', False),
                        'blocked': item.get('blocked', False),
                        'url': f"{jenkins_url}/{item.get('url', '')}"
                    })
        except requests.exceptions.RequestException as e:
            raise ConnectionError(f"Failed to fetch queue data from Jenkins: {e}")

        return queued_builds

    @keyword("Get Executor Utilization")
    def get_executor_utilization(
        self,
        jenkins_url: str,
        jenkins_username: platform.Secret,
        jenkins_token: platform.Secret
    ):
        """
        Returns a list with executor utilization info for each Jenkins node.

        | ${utilization}= | Get Executor Utilization | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} |
        | FOR  ${node}  IN  @{utilization} |
        |    Log  Node ${node['node_name']} is at ${node['utilization_percentage']}% utilization. |
        | END |
        """
        jenkins_data = self._fetch_jenkins_data(jenkins_url, jenkins_username, jenkins_token)
        executor_utilization = []

        for label in jenkins_data.get('assignedLabels', []):
            busy_executors = label.get('busyExecutors', 0)
            total_executors = label.get('totalExecutors', 0)
            utilization = (busy_executors / total_executors) * 100 if total_executors else 0
            executor_utilization.append({
                'node_name': label.get('name', 'unknown'),
                'busy_executors': busy_executors,
                'total_executors': total_executors,
                'utilization_percentage': utilization
            })

        return executor_utilization

    @keyword("Build Logs Analytics")
    def build_logs_analytics(
        self,
        jenkins_url: str,
        jenkins_username: platform.Secret,
        jenkins_token: platform.Secret,
        history_limit: int = 5
    ):
        """
        For each job in Jenkins, retrieve up to `history_limit` failed builds,
        analyze their logs, and attempt to find common error patterns using fuzzy matching.

        Returns a list of dictionaries, each describing:
          - job_name
          - builds_analyzed
          - similarity_score
          - common_error_patterns

        Example usage:
        | ${analysis_results}= | Build Logs Analytics | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} | 5 |
        | FOR  ${analysis}  IN  @{analysis_results} |
        |    Log  Job ${analysis['job_name']} has average log similarity ${analysis['similarity_score']}. |
        |    Log  Common error patterns: ${analysis['common_error_patterns']} |
        | END |
        """
        auth = (jenkins_username.value, jenkins_token.value)
        jenkins_data = self._fetch_jenkins_data(jenkins_url, jenkins_username, jenkins_token)
        failed_builds = []

        # Collect up to history_limit failed builds per job
        for job in jenkins_data.get('jobs', []):
            builds = []
            failed_count = 0
            for build in job.get('builds', []):
                if build.get('result') == 'FAILURE':
                    builds.append({'number': build.get('number'), 'url': build.get('url')})
                    failed_count += 1
                    if failed_count == history_limit:
                        break

            if builds:
                failed_builds.append({'job_name': job.get('name'), 'builds': builds})

        analysis_results = []
        for job_info in failed_builds:
            job_logs = []
            for build_info in job_info['builds']:
                try:
                    log_url = f"{build_info['url']}logText/progressiveText?start=0"
                    log_response = requests.get(log_url, auth=auth, timeout=10)
                    log_response.raise_for_status()
                    job_logs.append({
                        'build_number': build_info['number'],
                        'log_content': log_response.text
                    })
                except requests.exceptions.RequestException as e:
                    print(f"Failed to fetch logs for {job_info['job_name']} #{build_info['number']}: {e}")
                    continue

            # If there's only one failed build, can't compare logs across multiple builds
            if len(job_logs) < 2:
                continue

            # Extract error sections
            error_sections = []
            for log in job_logs:
                lines = log['log_content'].split('\n')
                error_section = []
                in_error = False

                for line in lines:
                    lower_line = line.lower()
                    if any(term in lower_line for term in ['error:', 'exception', 'failed', 'failure']):
                        if any(skip_term in lower_line for skip_term in ['finished: failure', 'build failure', '[info]']):
                            continue
                        in_error = True
                        error_section = [line]
                    elif in_error and line.strip():
                        if not lower_line.startswith('[info]'):
                            error_section.append(line)
                        if len(error_section) > 10:
                            in_error = False
                            if error_section:
                                error_sections.append('\n'.join(error_section))
                    elif in_error:
                        in_error = False
                        if error_section:
                            error_sections.append('\n'.join(error_section))

            # Use fuzzy matching to find common error sections
            common_patterns = defaultdict(dict)
            processed_sections = set()

            for section in error_sections:
                if section in processed_sections:
                    continue
                matches = fuzzprocessor.extractBests(
                    section,
                    error_sections,
                    scorer=fuzz.token_set_ratio,
                    score_cutoff=85
                )
                similar_sections = [m[0] for m in matches]
                # Only keep if it appears in all logs
                if len(similar_sections) == len(job_logs):
                    pattern_key = similar_sections[0]
                    common_patterns[pattern_key] = {
                        'occurrences': len(similar_sections),
                        'similar_sections': similar_sections,
                        'similarity_scores': [m[1] for m in matches]
                    }
                    processed_sections.update(similar_sections)

            # Calculate overall log similarity
            similarity_scores = []
            for i in range(len(job_logs)):
                for j in range(i + 1, len(job_logs)):
                    score = fuzz.token_set_ratio(job_logs[i]['log_content'], job_logs[j]['log_content'])
                    similarity_scores.append(score)

            avg_similarity = sum(similarity_scores) / len(similarity_scores) if similarity_scores else 0
            # Filter out patterns that appear in all logs
            significant_patterns = {
                pattern: details
                for pattern, details in common_patterns.items()
                if details['occurrences'] == len(job_logs)
            }

            analysis_results.append({
                'job_name': job_info['job_name'],
                'builds_analyzed': len(job_logs),
                'similarity_score': avg_similarity,
                'common_error_patterns': [
                    {
                        'pattern': pattern,
                        'occurrences': details['occurrences'],
                        'similar_sections': details['similar_sections'],
                        'similarity_scores': details['similarity_scores']
                    }
                    for pattern, details in significant_patterns.items()
                ]
            })

        return analysis_results

    @keyword("Parse Atom Feed")
    def parse_atom_feed(
        self,
        jenkins_url: str,
        jenkins_username: platform.Secret,
        jenkins_token: platform.Secret
    ):
        """
        Fetches and parses the Jenkins manage/log Atom feed, returning the combined log text.

        Example usage:
        | ${logs}= | Parse Jenkins Atom Feed | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} |
        | Log      | Jenkins logs: ${logs}   |
        """
        auth = (jenkins_username.value, jenkins_token.value)
        feed_url = f"{jenkins_url}/manage/log/rss"
        namespace = {'atom': 'http://www.w3.org/2005/Atom'}

        try:
            response = requests.get(feed_url, auth=auth, timeout=10)
            response.raise_for_status()
        except requests.exceptions.RequestException as e:
            raise ConnectionError(f"Failed to fetch data from Jenkins: {e}")

        root = ET.fromstring(response.text)
        logs = ""
        for entry in root.findall('atom:entry', namespace):
            content_elem = entry.find('atom:content', namespace)
            if content_elem is not None and content_elem.text:
                logs += f"{content_elem.text.strip()}\n{'=' * 80}\n"

        return logs
