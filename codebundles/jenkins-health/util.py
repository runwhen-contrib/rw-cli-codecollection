import os
import requests
import json
import time
from collections import defaultdict
from thefuzz import fuzz
from thefuzz import process as fuzzprocessor

# Ensure required environment variables are set
JENKINS_URL =       os.getenv("JENKINS_URL")
JENKINS_USERNAME =  os.getenv("JENKINS_USERNAME")
JENKINS_TOKEN =     os.getenv("JENKINS_TOKEN")

if not all([JENKINS_URL, JENKINS_USERNAME, JENKINS_TOKEN]):
    error_msg = "Please set JENKINS_URL, JENKINS_USERNAME, and JENKINS_TOKEN environment variables."
    raise ValueError(error_msg)

# Jenkins API URL
api_url =   f"{JENKINS_URL}/api/json?depth=2"
# Basic authentication
auth =  (JENKINS_USERNAME, JENKINS_TOKEN)

# Fetch Jenkins jobs data
try:
    response = requests.get(api_url, auth=auth, timeout=10)
    response.raise_for_status()  # Raises an HTTPError for bad responses (4xx, 5xx)
    jenkins_data = response.json()
except requests.exceptions.RequestException as e:
    raise ConnectionError(f"Failed to fetch data from Jenkins: {e}")


def get_failed_tests():
    failed_tests = []
    for job in jenkins_data.get('jobs'):
        if job.get('lastBuild').get('result') == 'UNSTABLE':
            pipeline_details = {
                'pipeline_name': job.get('name'),
                'pipeline_url': job.get('url'),
                'build_result': job.get('lastBuild').get('result'),
                'build_number': job.get('lastBuild').get('number'),
                'build_timestamp': job.get('lastBuild').get('timestamp'),
                'build_duration': job.get('lastBuild').get('duration'),
                'build_queueId': job.get('lastBuild').get('queueId'),
                'build_building': job.get('lastBuild').get('building'),
                'build_changeSet': job.get('lastBuild').get('changeSet')
            }
            try:
                tests_response = requests.get(job.get('lastBuild').get('url')+"testReport/api/json", auth=auth, timeout=10)
                tests_response.raise_for_status()
                suites = tests_response.json().get('suites')
                test_results = []
                for suite in suites:
                    for case in suite.get('cases'):
                        test_results.append(case)
            except requests.exceptions.RequestException as e:
                raise ConnectionError(f"Failed to fetch test data from Jenkins: {e}")

            result = {"pipeline_details": pipeline_details, "test_results": test_results}
            failed_tests.append(result)
    return failed_tests

def get_queued_builds(wait_threshold="10m"):
    """Get builds waiting in queue longer than the specified threshold.
    
    Args:
        wait_threshold (str): Time threshold in format like '10min', '1h', '30m', '1d', '1day'
        
    Returns:
        list: List of queued builds that exceed the wait threshold
    """
    # Convert threshold to minutes
    wait_threshold = wait_threshold.lower().replace(' ', '').strip('"').strip("'")
    threshold_value = 0
    if 'min' in wait_threshold:
        threshold_value = int(wait_threshold.replace('min', ''))
    elif 'h' in wait_threshold:
        threshold_value = int(wait_threshold.replace('h', '')) * 60
    elif 'm' in wait_threshold:
        threshold_value = int(wait_threshold.replace('m', ''))
    elif 'day' in wait_threshold:
        threshold_value = int(wait_threshold.replace('day', '')) * 24 * 60
    elif 'd' in wait_threshold:
        threshold_value = int(wait_threshold.replace('d', '')) * 24 * 60
    else:
        raise ValueError("Invalid threshold format. Use formats like '10min', '1h', '30m', '1d', '1day'")

    queued_builds = []
    
    try:
        queue_url = f"{JENKINS_URL}/queue/api/json"
        queue_response = requests.get(queue_url, auth=auth, timeout=10)
        queue_response.raise_for_status()
        queue_data = queue_response.json()
        
        current_time = int(time.time() * 1000)  # Convert to milliseconds
        
        for item in queue_data.get('items', []):
            # Get time in queue in minutes
            in_queue_since = item.get('inQueueSince', 0)
            wait_time_mins = (current_time - in_queue_since) / (1000 * 60)  # Convert to minutes
            
            # Format wait time based on duration
            if wait_time_mins >= 24*60:  # More than a day
                wait_time = f"{wait_time_mins/(24*60):.1f}d"
            elif wait_time_mins >= 60:  # More than an hour
                wait_time = f"{wait_time_mins/60:.1f}h"
            else:
                wait_time = f"{wait_time_mins:.1f}min"
            
            if wait_time_mins >= threshold_value:
                job_name = item.get('task', {}).get('name', '')
                if job_name == '':
                    try:
                        queued_build_url = item.get('url', '')
                        if queued_build_url != '':
                            queued_build_url = f"{JENKINS_URL}/{queued_build_url}api/json?depth=1"
                            rsp = requests.get(queued_build_url, auth=auth, timeout=10).json()
                            job_name = rsp.get('task').get('name')
                        else:
                            job_name = 'Unknown Job'
                    except requests.exceptions.RequestException as e:
                        job_name = 'Unknown Job'

                queued_build = {
                    'job_name': job_name,
                    'waiting_since': in_queue_since,
                    'wait_time': wait_time,
                    'why': item.get('why', 'Unknown Reason'),
                    'stuck': item.get('stuck', False),
                    'blocked': item.get('blocked', False),
                    'url': f"{JENKINS_URL}/{item.get('url', '')}"
                }
                queued_builds.append(queued_build)
                
        return queued_builds
        
    except requests.exceptions.RequestException as e:
        raise ConnectionError(f"Failed to fetch queue data from Jenkins: {e}")


def get_executor_utilization():
    executor_utilization = []
    for label in jenkins_data.get('assignedLabels', []):
        busy_executors = label.get('busyExecutors', 0)
        total_executors = label.get('totalExecutors', 0)
        if total_executors > 0:
            utilization = (busy_executors / total_executors) * 100
        else:
            utilization = 0
        executor_utilization.append({
            'node_name': label.get('name', 'unknown'),
            'busy_executors': busy_executors,
            'total_executors': total_executors,
            'utilization_percentage': utilization
        })
    return executor_utilization

def build_logs_analytics(history_limit=5):
    # Get failed builds (up to limit) for each job
    failed_builds = []
    for job in jenkins_data.get('jobs', []):
        builds = []
        failed_count = 0
        
        # Iterate through all builds until we find limit failed ones
        for build in job.get('builds', []):
            if build.get('result') == 'FAILURE':
                builds.append({
                    'number': build.get('number'),
                    'url': build.get('url')
                })
                failed_count += 1
                if failed_count == history_limit:
                    break
                    
        if builds:
            failed_builds.append({
                'job_name': job.get('name'),
                'builds': builds
            })
    
    # Analyze logs for each failed job
    analysis_results = []
    for job in failed_builds:
        job_logs = []
        
        # Get logs for each failed build
        for build in job['builds']:
            try:
                log_url = f"{build['url']}logText/progressiveText?start=0"
                log_response = requests.get(log_url, auth=auth, timeout=10)
                log_response.raise_for_status()
                job_logs.append({
                    'build_number': build['number'],
                    'log_content': log_response.text
                })
            except requests.exceptions.RequestException as e:
                print(f"Failed to fetch logs for {job['job_name']} #{build['number']}: {e}")
                continue
        
        if len(job_logs) < 2:
            continue
            
        # Extract error sections from logs
        error_sections = []
        for log in job_logs:
            log_lines = log['log_content'].split('\n')
            error_section = []
            in_error = False
            
            for line in log_lines:
                # Start capturing on error indicators
                if any(error_term in line.lower() for error_term in ['error:', 'exception', 'failed', 'failure']):
                    # Skip common, less meaningful lines
                    if any(skip_term in line.lower() for skip_term in 
                          ['finished: failure', 'build failure', '[info]']):
                        continue
                    in_error = True
                    error_section = [line]
                # Continue capturing context
                elif in_error and line.strip():
                    # Skip info/debug lines in error context
                    if not line.lower().startswith('[info]'):
                        error_section.append(line)
                    # Stop after capturing some context
                    if len(error_section) > 10:
                        in_error = False
                        if error_section:  # Only add if we have meaningful content
                            error_sections.append('\n'.join(error_section))
                elif in_error:
                    in_error = False
                    if error_section:  # Only add if we have meaningful content
                        error_sections.append('\n'.join(error_section))
        
        # Use thefuzz to find similar error patterns
        common_patterns = defaultdict(list)
        processed_sections = set()
        
        for section in error_sections:
            if section in processed_sections:
                continue
                
            # Use process.extractBests to find similar sections
            matches = fuzzprocessor.extractBests(
                section,
                error_sections,
                scorer=fuzz.token_set_ratio,
                score_cutoff=85  # 85% similarity threshold
            )
            
            similar_sections = [match[0] for match in matches]
            # Only include patterns that occur in all builds
            if len(similar_sections) == len(job_logs):  # Must occur in all builds
                pattern_key = similar_sections[0]
                common_patterns[pattern_key] = {
                    'occurrences': len(similar_sections),
                    'similar_sections': similar_sections,
                    'similarity_scores': [match[1] for match in matches]
                }
                processed_sections.update(similar_sections)
        
        # Calculate overall log similarity
        similarity_scores = []
        for i in range(len(job_logs)):
            for j in range(i + 1, len(job_logs)):
                score = fuzz.token_set_ratio(
                    job_logs[i]['log_content'],
                    job_logs[j]['log_content']
                )
                similarity_scores.append(score)
        
        avg_similarity = sum(similarity_scores) / len(similarity_scores) if similarity_scores else 0
        
        # Filter out patterns that don't meet minimum occurrence threshold
        significant_patterns = {
            pattern: details for pattern, details in common_patterns.items()
            if details['occurrences'] == len(job_logs)  # Must occur in all builds
        }
        
        analysis_results.append({
            'job_name': job['job_name'],
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