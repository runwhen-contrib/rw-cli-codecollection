import os
import requests
import sys
from collections import defaultdict
from thefuzz import fuzz
from thefuzz import process as fuzzprocessor

# Ensure required environment variables are set
JENKINS_URL = os.getenv("JENKINS_URL")
JENKINS_USERNAME = os.getenv("JENKINS_USERNAME")
JENKINS_TOKEN = os.getenv("JENKINS_TOKEN")

if not all([JENKINS_URL, JENKINS_USERNAME, JENKINS_TOKEN]):
    print("Please set JENKINS_URL, JENKINS_USERNAME, and JENKINS_TOKEN environment variables.")
    sys.exit(1)

# Jenkins API URL
api_url = f"{JENKINS_URL}/api/json?depth=2"

# Basic authentication
auth = (JENKINS_USERNAME, JENKINS_TOKEN)

# Fetch Jenkins jobs data
try:
    response = requests.get(api_url, auth=auth, timeout=10)
    response.raise_for_status()  # Raises an HTTPError for bad responses (4xx, 5xx)
    jenkins_data = response.json()
except requests.exceptions.RequestException as e:
    print(f"Failed to fetch data from Jenkins: {e}")
    sys.exit(1)


def get_failed_tests():
    failed_tests = []
    for job in jenkins_data.get('jobs'):
        if job.get('lastBuild').get('result') == 'UNSTABLE':
            pipeline_details = {
                'pipeline_name': job.get('name'),
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
                tests_response.raise_for_status()  # Raises an HTTPError for bad tests_responses (4xx, 5xx)
                suites = tests_response.json().get('suites')
                test_results = []
                for suite in suites:
                    for case in suite.get('cases'):
                        if case.get('status') == 'FAILED':
                            test_results.append(case)
            except requests.exceptions.RequestException as e:
                print(f"Failed to fetch data from Jenkins: {e}")

            result = {"pipeline_details": pipeline_details, "test_results": test_results}
            failed_tests.append(result)
    return failed_tests


def build_logs_anyalytics(history_limit=5):
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
            
        # Extract error lines from all logs
        all_error_lines = []
        for log in job_logs:
            error_lines = [
                line.strip() for line in log['log_content'].split('\n')
                if any(error_term in line.lower() for error_term in ['error', 'exception', 'failed', 'failure'])
            ]
            all_error_lines.extend(error_lines)
        
        # Use thefuzz to find similar error patterns
        common_patterns = defaultdict(list)
        processed_lines = set()
        
        for line in all_error_lines:
            if line in processed_lines:
                continue
                
            # Use process.extractBests to find similar lines
            matches = fuzzprocessor.extractBests(
                line, 
                all_error_lines,
                scorer=fuzz.token_set_ratio,  # Better for error messages that might have different word orders
                score_cutoff=85  # 85% similarity threshold
            )
            
            similar_lines = [match[0] for match in matches]
            if len(similar_lines) > 1:
                pattern_key = similar_lines[0]
                common_patterns[pattern_key] = {
                    'occurrences': len(similar_lines),
                    'similar_lines': similar_lines,
                    'similarity_scores': [match[1] for match in matches]
                }
                processed_lines.update(similar_lines)
        
        # Calculate overall log similarity using token_set_ratio
        similarity_scores = []
        for i in range(len(job_logs)):
            for j in range(i + 1, len(job_logs)):
                score = fuzz.token_set_ratio(
                    job_logs[i]['log_content'],
                    job_logs[j]['log_content']
                )
                similarity_scores.append(score)
        
        avg_similarity = sum(similarity_scores) / len(similarity_scores) if similarity_scores else 0
        
        analysis_results.append({
            'job_name': job['job_name'],
            'builds_analyzed': len(job_logs),
            'similarity_score': avg_similarity,
            'common_error_patterns': [
                {
                    'pattern': pattern,
                    'occurrences': details['occurrences'],
                    'similar_lines': details['similar_lines'],
                    'similarity_scores': details['similarity_scores']
                }
                for pattern, details in common_patterns.items()
            ]
        })
    
    return analysis_results


if __name__ == "__main__":
    print(build_logs_anyalytics())