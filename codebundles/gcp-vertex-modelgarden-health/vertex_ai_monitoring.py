#!/usr/bin/env python3
"""
Vertex AI Model Garden monitoring utilities using direct REST API calls.
"""

import os
import sys
import argparse
import requests
import json as json_module
import subprocess
from datetime import datetime, timedelta, timezone


def setup_authentication():
    """Set up Google Cloud authentication."""
    try:
        # Check if gcloud auth is working
        result = subprocess.run(
            ['gcloud', 'auth', 'list', '--filter=status:ACTIVE', '--format=value(account)'],
            capture_output=True, text=True, timeout=30
        )
        
        if result.returncode != 0 or not result.stdout.strip():
            raise Exception("No active gcloud authentication found")
            
        # Authentication is working if we get here
        return True
        
    except Exception as e:
        raise Exception(f"Authentication setup failed: {str(e)}")


def get_auth_token():
    """Get authenticated token for REST API calls using gcloud."""
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    try:
        if debug_mode:
            print("🐛 DEBUG: Getting auth token using gcloud...")
            
        # Use gcloud to get access token - this works with user auth and service accounts
        result = subprocess.run(
            ['gcloud', 'auth', 'application-default', 'print-access-token'],
            capture_output=True, text=True, timeout=30
        )
        
        if result.returncode != 0:
            if debug_mode:
                print("🐛 DEBUG: application-default failed, trying regular auth...")
            # Fallback to regular gcloud auth if application-default fails
            result = subprocess.run(
                ['gcloud', 'auth', 'print-access-token'],
                capture_output=True, text=True, timeout=30
            )
        
        if result.returncode != 0:
            raise Exception(f"gcloud auth failed: {result.stderr}")
        
        token = result.stdout.strip()
        if debug_mode:
            print(f"🐛 DEBUG: Got token of length {len(token)}")
        
        # Get project ID from environment or gcloud
        env_project_id = os.environ.get("GCP_PROJECT_ID", "").strip()
        if env_project_id:
            project_id = env_project_id
        else:
            # Get project from gcloud config
            result = subprocess.run(
                ['gcloud', 'config', 'get-value', 'project'],
                capture_output=True, text=True, timeout=30
            )
            project_id = result.stdout.strip() if result.returncode == 0 else 'unknown'
        
        if debug_mode:
            print(f"🐛 DEBUG: Using project: {project_id}")
        
        return token, project_id
        
    except Exception as e:
        if debug_mode:
            print(f"🐛 DEBUG: Auth token error: {str(e)}")
        raise Exception(f"Failed to get auth token: {str(e)}")


def call_monitoring_api(endpoint, params=None, method='GET'):
    """Make authenticated REST API calls to Cloud Monitoring."""
    token, project_id = get_auth_token()
    
    headers = {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json'
    }
    
    base_url = 'https://monitoring.googleapis.com/v3'
    url = f'{base_url}/{endpoint}'
    
    if method == 'GET':
        response = requests.get(url, headers=headers, params=params)
    elif method == 'POST':
        response = requests.post(url, headers=headers, json=params)
    
    response.raise_for_status()
    return response.json(), project_id


def discover_all_deployed_models():
    """Discover all deployed Vertex AI models using gcloud CLI."""
    setup_authentication()
    
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    try:
        env_project_id = os.environ.get("GCP_PROJECT_ID", "").strip()
        if not env_project_id:
            # Get project from gcloud config instead of google.auth.default()
            result = subprocess.run(
                ['gcloud', 'config', 'get-value', 'project'],
                capture_output=True, text=True, timeout=30
            )
            env_project_id = result.stdout.strip() if result.returncode == 0 else 'unknown'
        
        discovered_models = {}
        total_endpoints = 0
        total_models = 0
        
        print('🔍 Discovering Vertex AI Models')
        
        available_regions = discover_available_regions(env_project_id)
        
        if not available_regions:
            print('⚠️  No available regions found, using defaults')
            available_regions = ['us-central1', 'us-east1', 'us-east4', 'us-east5', 'us-west1']
        
        print(f'📍 Checking {len(available_regions)} regions...')
        
        for region in available_regions:
            try:
                if debug_mode:
                    print(f'🐛 DEBUG: Checking region: {region}')
                
                list_cmd = [
                    'gcloud', 'ai', 'endpoints', 'list',
                    '--region', region,
                    '--project', env_project_id,
                    '--format', 'json'
                ]
                
                if debug_mode:
                    print(f'🐛 Running: {" ".join(list_cmd)}')
                
                list_result = subprocess.run(list_cmd, capture_output=True, text=True, timeout=60)
                
                if list_result.returncode != 0:
                    if debug_mode:
                        print(f'  ❌ gcloud list failed: {list_result.stderr[:100]}')
                    continue
                
                endpoints_data = json_module.loads(list_result.stdout) if list_result.stdout.strip() else []
                total_endpoints += len(endpoints_data)
                
                if debug_mode:
                    print(f'  🐛 Found {len(endpoints_data)} endpoints in {region}')
                
                for endpoint_data in endpoints_data:
                    endpoint_name = endpoint_data.get('displayName', 'unknown')
                    endpoint_id = endpoint_data.get('name', '').split('/')[-1]
                    
                    if debug_mode:
                        print(f'  🐛 Processing endpoint: {endpoint_id} ({endpoint_name})')
                    
                    describe_cmd = [
                        'gcloud', 'ai', 'endpoints', 'describe', endpoint_id,
                        '--region', region,
                        '--project', env_project_id,
                        '--format', 'json'
                    ]
                    
                    describe_result = subprocess.run(describe_cmd, capture_output=True, text=True, timeout=30)
                    
                    if describe_result.returncode != 0:
                        if debug_mode:
                            print(f'    ❌ gcloud describe failed: {describe_result.stderr[:100]}')
                        print(f'  ⚠️  Error: {endpoint_name} ({region}) - could not get details')
                        continue
                    
                    endpoint_details = json_module.loads(describe_result.stdout)
                    deployed_models = endpoint_details.get('deployedModels', [])
                    
                    if debug_mode:
                        print(f'    🐛 Found {len(deployed_models)} deployed models')
                    
                    if deployed_models:
                        for deployed_model in deployed_models:
                            total_models += 1
                            
                            model_path = deployed_model.get('model', '')
                            model_id = model_path.split('/')[-1] if model_path else 'unknown'
                            display_name = deployed_model.get('displayName', model_id)
                            
                            model_key = f"{display_name} ({region})"
                            discovered_models[model_key] = {
                                'model_id': model_id,
                                'display_name': display_name,
                                'region': region,
                                'endpoint_id': endpoint_id,
                                'endpoint_name': endpoint_name,
                                'source': 'gcloud_cli'
                            }
                            
                            print(f'  ✅ {display_name} → {endpoint_name} ({region})')
                    else:
                        if debug_mode:
                            print(f'    ⚠️  Endpoint {endpoint_id} ({endpoint_name}) has no deployed models')
                        else:
                            print(f'  ⚠️  Empty: {endpoint_name} ({region}) - no models')
                    
            except subprocess.TimeoutExpired:
                if debug_mode:
                    print(f'  ⚠️  Timeout checking region {region}')
            except Exception as region_error:
                if debug_mode:
                    print(f'  ⚠️  Error in region {region}: {str(region_error)[:100]}')
        
        print(f'\n📊 Discovery Results:')
        print(f'   Models: {total_models}, Endpoints: {total_endpoints}, Regions: {len(available_regions)}')
        
        if discovered_models:
            print(f'\n🤖 Deployed Models:')
            for model_key, details in discovered_models.items():
                print(f'   • {model_key}')
                if 'llama' in model_key.lower():
                    print(f'     🎯 LLAMA MODEL DETECTED')
        
        print(f'\nALL_MODELS_DISCOVERED:{total_models}')
        print(f'ALL_ENDPOINTS_DISCOVERED:{total_endpoints}')
        print(f'REGIONS_CHECKED:{len(available_regions)}')
        
        return discovered_models
        
    except Exception as auth_error:
        print(f'❌ Error: {str(auth_error)[:100]}')
        print('ALL_MODELS_DISCOVERED:0')
        print('ALL_ENDPOINTS_DISCOVERED:0')
        print('REGIONS_CHECKED:0')
        return {}


def discover_available_regions(project_id):
    """Discover available Vertex AI regions."""
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    try:
        custom_regions = os.environ.get('VERTEX_AI_REGIONS', '').strip()
        
        if custom_regions:
            regions_list = [r.strip() for r in custom_regions.split(',') if r.strip()]
            if debug_mode:
                print(f'🎯 Using custom regions: {", ".join(regions_list)}')
            return regions_list
        
        # Use comprehensive list of known Vertex AI regions
        all_possible_regions = [
            'us-central1', 'us-east1', 'us-east4', 'us-east5', 'us-west1', 'us-west2', 'us-west3', 'us-west4',
            'europe-west1', 'europe-west2', 'europe-west3', 'europe-west4', 'europe-west6', 'europe-west8', 'europe-west9',
            'asia-east1', 'asia-east2', 'asia-northeast1', 'asia-northeast2', 'asia-northeast3',
            'asia-south1', 'asia-southeast1', 'asia-southeast2', 'australia-southeast1'
        ]
        
        # Prioritize common regions
        priority_regions = ['us-central1', 'us-east1', 'us-east4', 'us-east5', 'us-west1', 
                          'europe-west1', 'europe-west4', 'asia-east1', 'asia-southeast1']
        
        ordered_regions = priority_regions + [r for r in all_possible_regions if r not in priority_regions]
        
        return ordered_regions
        
    except Exception as e:
        if debug_mode:
            print(f'⚠️  Could not determine available regions: {str(e)[:100]}')
        return ['us-central1', 'us-east1', 'us-east4', 'us-west1', 'europe-west1', 'asia-east1']


def analyze_error_patterns(hours=2, include_discovery=True):
    """Analyze Model Garden error patterns using REST API."""
    setup_authentication()
    
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    discovered_models = {}
    if include_discovery:
        if not debug_mode:
            print('=' * 40)
        discovered_models = discover_all_deployed_models()
        if not debug_mode:
            print('=' * 40)
    
    try:
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        
        start_time_str = start_time.strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        end_time_str = end_time.strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        
        print(f'📊 Error Analysis (Last {hours} Hours)')
        
        try:
            params = {
                'filter': 'metric.type="aiplatform.googleapis.com/publisher/online_serving/model_invocation_count"',
                'interval.startTime': start_time_str,
                'interval.endTime': end_time_str,
                'view': 'FULL'
            }
            
            token, project_id = get_auth_token()
            response_data, _ = call_monitoring_api(f'projects/{project_id}/timeSeries', params)
            
            response_codes = {}
            model_errors = {}
            total_invocations = 0
            total_errors = 0
            
            for result in response_data.get('timeSeries', []):
                resource_labels = result.get('resource', {}).get('labels', {})
                metric_labels = result.get('metric', {}).get('labels', {})
                
                model_id = resource_labels.get('model_user_id', 'unknown')
                response_code = metric_labels.get('response_code', 'unknown')
                
                count = sum(float(point.get('value', {}).get('doubleValue', 0)) 
                           for point in result.get('points', []))
                total_invocations += count
                
                response_codes[response_code] = response_codes.get(response_code, 0) + count
                
                if not response_code.startswith('2'):
                    total_errors += count
                    model_errors[model_id] = model_errors.get(model_id, 0) + count
            
            if total_invocations > 0:
                error_rate = (total_errors / total_invocations) * 100
                
                print(f'Invocations: {total_invocations:.0f}, Errors: {total_errors:.0f}, Rate: {error_rate:.2f}%')
                
                if model_errors:
                    print(f'   ⚠️  {len(model_errors)} models with errors')
                else:
                    print('   ✅ No errors detected')
                    
                print(f'HIGH_ERROR_RATE:{"true" if error_rate > 5 else "false"}')
                print(f'ERROR_COUNT:{total_errors:.0f}')
                
            else:
                print('No Model Garden invocation data found')
                print('HIGH_ERROR_RATE:false')
                print('ERROR_COUNT:0')
                
        except Exception as e:
            print(f"⚠️  Error querying invocation metrics: {e}")
            print('HIGH_ERROR_RATE:false')
            print('ERROR_COUNT:0')
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('HIGH_ERROR_RATE:false')
        print('ERROR_COUNT:0')


def analyze_throughput_consumption(hours=2, debug=False, include_discovery=True):
    """Analyze throughput and token consumption using REST API."""
    setup_authentication()
    
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    if debug_mode:
        debug = True
    
    discovered_models = {}
    if include_discovery:
        if not debug_mode:
            print('=' * 40)
        discovered_models = discover_all_deployed_models()
        if not debug_mode:
            print('=' * 40)
    
    try:
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        
        start_time_str = start_time.strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        end_time_str = end_time.strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        
        print(f'📈 Token Usage Analysis (Last {hours} Hours)')
        
        try:
            params = {
                'filter': 'metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count"',
                'interval.startTime': start_time_str,
                'interval.endTime': end_time_str,
                'view': 'FULL'
            }
            
            token, project_id = get_auth_token()
            response_data, _ = call_monitoring_api(f'projects/{project_id}/timeSeries', params)
            
            model_tokens = {}
            models_found = set()
            total_token_count = 0
            
            for result in response_data.get('timeSeries', []):
                resource_labels = result.get('resource', {}).get('labels', {})
                model_id = resource_labels.get('model_user_id', 'unknown')
                location = resource_labels.get('location', 'unknown')
                model_key = f"{model_id} ({location})"
                models_found.add(model_key)
                
                points = result.get('points', [])
                if points:
                    token_count = sum(float(point.get('value', {}).get('doubleValue', 0)) 
                                    for point in points)
                    if token_count > 0:
                        model_tokens[model_key] = token_count
                        total_token_count += token_count
                        print(f'   ✅ {model_key}: {token_count:.0f} tokens')
            
            if models_found:
                print('🤖 Models with Active Metrics:')
                for model in sorted(models_found):
                    print(f'  • {model}')
            
            if total_token_count > 0:
                print(f'\n💡 Total consumption: {total_token_count:.0f} tokens across {len(model_tokens)} models')
            else:
                print('\n📊 No active token consumption detected')
            
            print(f'HAS_USAGE_DATA:{"true" if total_token_count > 0 else "false"}')
            print(f'TOTAL_TOKEN_COUNT:{total_token_count:.0f}')
            print(f'MODELS_FOUND:{len(models_found)}')
            
        except Exception as e:
            print(f'⚠️  Error querying throughput metrics: {str(e)[:100]}')
            print('HAS_USAGE_DATA:false')
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('HAS_USAGE_DATA:false')


def check_service_health():
    """Check Model Garden service health using REST API."""
    setup_authentication()
    
    try:
        print('🔧 Service Configuration Check')
        
        try:
            params = {'pageSize': 500}
            
            token, project_id = get_auth_token()
            response_data, _ = call_monitoring_api(f'projects/{project_id}/metricDescriptors', params)
            
            vertex_metrics = 0
            for descriptor in response_data.get('metricDescriptors', []):
                if 'aiplatform.googleapis.com/publisher/online_serving' in descriptor.get('type', ''):
                    vertex_metrics += 1
            
            print(f'Model Garden Metrics Available: {vertex_metrics}')
            
            if vertex_metrics == 0:
                print('⚠️  No Model Garden metrics found')
            else:
                print('✅ Model Garden metrics are available for monitoring')
                
            print(f'METRICS_AVAILABLE:{vertex_metrics}')
            
        except Exception as e:
            print(f'⚠️  Error checking metrics: {str(e)[:100]}')
            print('METRICS_AVAILABLE:0')
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('METRICS_AVAILABLE:0')


def main():
    """Main entry point with command line parsing."""
    parser = argparse.ArgumentParser(description='Vertex AI Model Garden Health Monitoring')
    parser.add_argument('command', choices=['errors', 'throughput', 'health', 'discover', 'latency', 'report'], 
                       help='Analysis type to perform')
    parser.add_argument('--hours', type=int, default=2, help='Time window in hours (default: 2)')
    parser.add_argument('--debug', action='store_true', help='Enable debug output')
    parser.add_argument('--no-discovery', action='store_true', help='Skip model discovery')
    parser.add_argument('--regions', type=str, help='Comma-separated list of regions to check')
    
    args = parser.parse_args()
    
    if args.debug:
        os.environ['VERTEX_AI_DEBUG'] = 'true'
    
    # Set custom regions if provided
    if args.regions:
        os.environ['VERTEX_AI_REGIONS'] = args.regions
    
    try:
        if args.command == 'errors':
            analyze_error_patterns(hours=args.hours, include_discovery=not args.no_discovery)
        elif args.command == 'throughput':
            analyze_throughput_consumption(hours=args.hours, debug=args.debug, include_discovery=not args.no_discovery)
        elif args.command == 'health':
            check_service_health()
        elif args.command == 'discover':
            discover_all_deployed_models()
        elif args.command == 'latency':
            print('Latency analysis not yet implemented in REST API version')
        elif args.command == 'report':
            print('Report generation not yet implemented in REST API version')
    except Exception as e:
        print(f'❌ Error: {str(e)[:200]}')
        sys.exit(1)


if __name__ == '__main__':
    main()
