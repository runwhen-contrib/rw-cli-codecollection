#!/usr/bin/env python3
"""
Vertex AI Model Garden monitoring utilities using Google Cloud Monitoring Python SDK.
"""

import os
import sys
import argparse
from datetime import datetime, timedelta, timezone
from google.cloud import monitoring_v3
from google.cloud.monitoring_v3.query import Query
from google.cloud import aiplatform
from google.auth import default
import json
import subprocess


def setup_authentication():
    """Set up Google Cloud authentication."""
    # Check if credentials are already set up properly
    creds_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS', '')
    
    # If no credentials path or empty path, try to use default authentication
    if not creds_path or not os.path.exists(creds_path):
        # In Robot Framework context, credentials might be set differently
        # Try to use the default credentials discovery
        try:
            default()  # This will raise an exception if no credentials are found
        except Exception:
            # If default auth fails and we have an empty path, don't set it
            if creds_path == '':
                # Remove the empty environment variable to allow default auth
                if 'GOOGLE_APPLICATION_CREDENTIALS' in os.environ:
                    del os.environ['GOOGLE_APPLICATION_CREDENTIALS']
            else:
                # Keep the existing path
                os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = creds_path
    else:
        # Valid credentials path exists
        os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = creds_path


def get_monitoring_client():
    """Get authenticated monitoring client."""
    credentials, project_id = default()
    client = monitoring_v3.MetricServiceClient(credentials=credentials)
    
    # Use project ID from environment variable if set, otherwise use from credentials
    env_project_id = os.environ.get("GCP_PROJECT_ID", "").strip()
    if env_project_id:
        project_name = f'projects/{env_project_id}'
    else:
        project_name = f'projects/{project_id}'
    
    return client, project_name


def cross_reference_discovery_with_metrics(discovered_models, project_id, hours=2):
    """Cross-reference discovery results with monitoring metrics to identify discrepancies."""
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    if debug_mode:
        print(f'\n🔍 Cross-Referencing Discovery with Metrics APIs')
        print('=' * 60)
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        if debug_mode:
            print(f'🐛 DEBUG: Using project: {project_name}')
            print(f'🐛 DEBUG: Time range: {start_time} to {end_time}')
        
        # Get models from metrics API
        metrics_models = set()
        invocation_details = {}
        
        try:
            # Check invocation metrics
            results = client.list_time_series(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/model_invocation_count"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL
            )
            
            for result in results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                location = result.resource.labels.get('location', 'unknown')
                response_code = result.metric.labels.get('response_code', 'unknown')
                
                model_key = f"{model_id} ({location})"
                metrics_models.add(model_key)
                
                if debug_mode:
                    invocation_count = sum(point.value.double_value for point in result.points)
                    if model_key not in invocation_details:
                        invocation_details[model_key] = {}
                    invocation_details[model_key][response_code] = invocation_count
                    
            if debug_mode and len(metrics_models) > 0:
                print(f'  ✅ Monitoring API found {len(metrics_models)} models with recent activity')
                
        except Exception as e:
            if debug_mode:
                print(f'  ❌ Error querying monitoring metrics: {str(e)[:100]}')
        
        # Check token consumption metrics
        try:
            token_results = client.list_time_series(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL
            )
            
            token_models = set()
            
            for result in token_results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                location = result.resource.labels.get('location', 'unknown')
                model_key = f"{model_id} ({location})"
                token_models.add(model_key)
            
            if debug_mode and len(token_models) > 0:
                print(f'  ✅ Token Metrics API found {len(token_models)} models with token usage')
            
            # Combine all models from metrics
            all_metrics_models = metrics_models.union(token_models)
            
        except Exception as e:
            if debug_mode:
                print(f'  ⚠️  Token metrics error: {str(e)[:100]}')
            all_metrics_models = metrics_models
        
        # Get models from discovery API
        discovered_model_keys = set(discovered_models.keys())
        
        # Compare the results
        models_in_metrics_not_discovery = all_metrics_models - discovered_model_keys
        models_in_discovery_not_metrics = discovered_model_keys - all_metrics_models
        models_in_both = all_metrics_models & discovered_model_keys
        
        # Only show significant findings
        if models_in_metrics_not_discovery or (debug_mode and (len(all_metrics_models) > 0 or len(discovered_model_keys) > 0)):
            print(f'\n📊 Discovery vs Metrics:')
            print(f'   Discovery: {len(discovered_model_keys)} models, Metrics: {len(all_metrics_models)} models')
            
            if models_in_both:
                print(f'   ✅ {len(models_in_both)} models found in both APIs')
            
            if models_in_metrics_not_discovery:
                print(f'   🚨 {len(models_in_metrics_not_discovery)} ACTIVE models NOT in discovery:')
                for model in sorted(models_in_metrics_not_discovery):
                    print(f'      • {model}')
                print(f'   💡 These models are active but not found by endpoint discovery')
                print(f'      Possible reasons: different deployment method, region mismatch, or permissions')
            
            if models_in_discovery_not_metrics:
                print(f'   💤 {len(models_in_discovery_not_metrics)} deployed models without recent activity')
        
        return {
            'discovered_models': discovered_model_keys,
            'metrics_models': all_metrics_models,
            'both': models_in_both,
            'metrics_only': models_in_metrics_not_discovery,
            'discovery_only': models_in_discovery_not_metrics
        }
        
    except Exception as e:
        if debug_mode:
            print(f'❌ Error in cross-reference analysis: {str(e)[:100]}')
        return None


def discover_all_deployed_models():
    """Proactively discover all deployed Vertex AI models and endpoints."""
    setup_authentication()
    
    # Initialize debug mode early
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    try:
        # Get project info
        env_project_id = os.environ.get("GCP_PROJECT_ID", "").strip()
        if not env_project_id:
            _, project_id = default()
            env_project_id = project_id
        
        discovered_models = {}
        total_endpoints = 0
        total_models = 0
        
        print('🔍 Discovering Vertex AI Models')
        
        # First, discover available regions for this project
        available_regions = discover_available_regions(env_project_id)
        
        if not available_regions:
            print('⚠️  No available regions found, using defaults')
            available_regions = ['us-central1', 'us-east1', 'us-east4', 'us-east5', 'us-west1']
        
        print(f'📍 Checking {len(available_regions)} regions...')
        
        # Track regions with findings
        regions_with_endpoints = []
        regions_with_models = []
        
        # Now discover endpoints in each available region
        for region in available_regions:
            try:
                if debug_mode:
                    print(f'🐛 DEBUG: Checking region: {region}')
                
                # List all endpoints in this region
                aiplatform.init(project=env_project_id, location=region)
                endpoints = aiplatform.Endpoint.list()
                
                region_endpoint_count = 0
                region_model_count = 0
                
                for endpoint in endpoints:
                    total_endpoints += 1
                    region_endpoint_count += 1
                    
                    endpoint_name = endpoint.display_name or endpoint.name.split('/')[-1]
                    endpoint_id = endpoint.name.split('/')[-1]
                    
                    if debug_mode:
                        print(f'  🐛 DEBUG: Processing endpoint {endpoint_id} ({endpoint_name})')
                        print(f'    🐛 Full endpoint path: {endpoint.name}')
                        print(f'    🐛 Has deployed_models attr: {hasattr(endpoint, "deployed_models")}')
                        
                    # Get deployed models on this endpoint - improved approach
                    deployed_models_found = False
                    
                    # Always try to get detailed endpoint information first
                    # The list() method may not populate deployed_models reliably
                    try:
                        if debug_mode:
                            print(f'    🐛 Getting detailed endpoint information for {endpoint_id}')
                        
                        # Get fresh endpoint details - this should populate deployed_models properly
                        detailed_endpoint = aiplatform.Endpoint(endpoint.name)
                        
                        if hasattr(detailed_endpoint, 'deployed_models') and detailed_endpoint.deployed_models:
                            if debug_mode:
                                print(f'    🐛 Detailed endpoint has {len(detailed_endpoint.deployed_models)} deployed models')
                            
                            for deployed_model in detailed_endpoint.deployed_models:
                                deployed_models_found = True
                                total_models += 1
                                region_model_count += 1
                                
                                model_id = deployed_model.model.split('/')[-1] if deployed_model.model else 'unknown'
                                display_name = deployed_model.display_name or model_id
                                
                                if debug_mode:
                                    print(f'      🐛 Model: {display_name} (ID: {model_id})')
                                    print(f'      🐛 Model path: {getattr(deployed_model, "model", "unknown")}')
                                    print(f'      🐛 Machine type: {getattr(deployed_model, "machine_type", "unknown")}')
                                
                                model_key = f"{display_name} ({region})"
                                discovered_models[model_key] = {
                                    'model_id': model_id,
                                    'display_name': display_name,
                                    'region': region,
                                    'endpoint_id': endpoint_id,
                                    'endpoint_name': endpoint_name,
                                    'machine_type': getattr(deployed_model, 'machine_type', 'unknown'),
                                    'min_replica_count': getattr(deployed_model, 'min_replica_count', 0),
                                    'max_replica_count': getattr(deployed_model, 'max_replica_count', 0),
                                    'traffic_split': getattr(deployed_model, 'traffic_split', 0),
                                    'create_time': str(getattr(endpoint, 'create_time', 'unknown'))
                                }
                                
                                print(f'  ✅ {display_name} → {endpoint_name} ({region})')
                        else:
                            if debug_mode:
                                print(f'    🐛 Detailed endpoint check: no deployed models found')
                                
                    except Exception as detail_error:
                        if debug_mode:
                            print(f'    🐛 Failed to get detailed endpoint: {str(detail_error)[:100]}')
                    
                    # Fallback: Try the original method if detailed approach failed
                    if not deployed_models_found:
                        if debug_mode:
                            print(f'    🐛 Fallback: Trying original deployed_models attribute')
                            
                        if hasattr(endpoint, 'deployed_models') and endpoint.deployed_models:
                            if debug_mode:
                                print(f'    🐛 Original endpoint has {len(endpoint.deployed_models)} deployed models')
                            
                            for deployed_model in endpoint.deployed_models:
                                deployed_models_found = True
                                total_models += 1
                                region_model_count += 1
                                
                                model_id = deployed_model.model.split('/')[-1] if deployed_model.model else 'unknown'
                                display_name = deployed_model.display_name or model_id
                                
                                model_key = f"{display_name} ({region})"
                                discovered_models[model_key] = {
                                    'model_id': model_id,
                                    'display_name': display_name,
                                    'region': region,
                                    'endpoint_id': endpoint_id,
                                    'endpoint_name': endpoint_name,
                                    'machine_type': getattr(deployed_model, 'machine_type', 'unknown'),
                                    'min_replica_count': getattr(deployed_model, 'min_replica_count', 0),
                                    'max_replica_count': getattr(deployed_model, 'max_replica_count', 0),
                                    'traffic_split': getattr(deployed_model, 'traffic_split', 0),
                                    'create_time': str(getattr(endpoint, 'create_time', 'unknown'))
                                }
                                
                                print(f'  ✅ {display_name} → {endpoint_name} ({region})')
                        else:
                            if debug_mode:
                                print(f'    🐛 Original endpoint: deployed_models is empty or None')
                                print(f'    🐛 Has deployed_models attr: {hasattr(endpoint, "deployed_models")}')
                                if hasattr(endpoint, 'deployed_models'):
                                    print(f'    🐛 deployed_models value: {endpoint.deployed_models}')
                    
                    # If no models found, report the empty endpoint
                    if not deployed_models_found:
                        if debug_mode:
                            print(f'    ⚠️  Endpoint {endpoint_id} ({endpoint_name}) has no deployed models')
                        else:
                            print(f'  ⚠️  Empty: {endpoint_name} ({region}) - no models')
                
                # Track regions with findings
                if region_endpoint_count > 0:
                    regions_with_endpoints.append(f"{region}({region_endpoint_count})")
                if region_model_count > 0:
                    regions_with_models.append(f"{region}({region_model_count})")
                    
            except Exception as region_error:
                if 'PERMISSION_DENIED' in str(region_error) or 'does not have permission' in str(region_error):
                    if debug_mode:
                        print(f'  ❌ Permission denied for region {region}')
                elif 'Invalid resource location' in str(region_error) or 'LOCATION_NOT_FOUND' in str(region_error):
                    if debug_mode:
                        print(f'  ⚠️  Region {region} not available')
                else:
                    if debug_mode:
                        print(f'  ⚠️  Error in region {region}: {str(region_error)[:100]}')
        
        # Concise summary
        print(f'\n📊 Discovery Results:')
        print(f'   Models: {total_models}, Endpoints: {total_endpoints}, Regions: {len(available_regions)}')
        
        if regions_with_models:
            print(f'   📍 Models found in: {", ".join(regions_with_models)}')
        elif regions_with_endpoints:
            print(f'   📍 Empty endpoints in: {", ".join(regions_with_endpoints)}')
        else:
            print(f'   📍 No endpoints found in any region')
        
        if discovered_models:
            print(f'\n🤖 Deployed Models:')
            for model_key, details in discovered_models.items():
                print(f'   • {model_key}')
                if 'llama' in model_key.lower():
                    print(f'     🎯 LLAMA MODEL')
        
        # Run cross-reference but make it concise
        cross_ref_results = cross_reference_discovery_with_metrics(discovered_models, env_project_id)
        
        print(f'\nALL_MODELS_DISCOVERED:{total_models}')
        print(f'ALL_ENDPOINTS_DISCOVERED:{total_endpoints}')
        print(f'REGIONS_CHECKED:{len(available_regions)}')
        
        return discovered_models
        
    except Exception as auth_error:
        print(f'❌ Authentication/Setup error: {str(auth_error)[:100]}')
        print('ALL_MODELS_DISCOVERED:0')
        print('ALL_ENDPOINTS_DISCOVERED:0')
        print('REGIONS_CHECKED:0')
        return {}


def discover_available_regions(project_id):
    """Discover available Vertex AI regions for the given project."""
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    try:
        # Check for custom regions from environment variable or use comprehensive list
        custom_regions = os.environ.get('VERTEX_AI_REGIONS', '').strip()
        
        if custom_regions:
            regions_list = [r.strip() for r in custom_regions.split(',') if r.strip()]
            if debug_mode:
                print(f'🎯 Using custom regions from VERTEX_AI_REGIONS: {", ".join(regions_list)}')
            return regions_list
        
        from google.cloud import resourcemanager_v3
        from google.api_core import retry
        import time
        
        # Try to get available regions dynamically
        # This is a best-effort approach as there's no direct "list supported regions" API
        
        # Use a comprehensive list of known Vertex AI regions (as of 2024)
        all_possible_regions = [
            # US regions
            'us-central1', 'us-east1', 'us-east4', 'us-east5', 
            'us-west1', 'us-west2', 'us-west3', 'us-west4',
            
            # Europe regions
            'europe-west1', 'europe-west2', 'europe-west3', 'europe-west4', 
            'europe-west6', 'europe-west8', 'europe-west9', 'europe-west12',
            'europe-north1', 'europe-central2',
            
            # Asia Pacific regions
            'asia-east1', 'asia-east2', 'asia-northeast1', 'asia-northeast2', 'asia-northeast3',
            'asia-south1', 'asia-south2', 'asia-southeast1', 'asia-southeast2',
            'australia-southeast1', 'australia-southeast2',
            
            # Other regions
            'northamerica-northeast1', 'northamerica-northeast2',
            'southamerica-east1', 'southamerica-west1'
        ]
        
        # Prioritize common regions that are most likely to have models
        priority_regions = [
            'us-central1', 'us-east1', 'us-east4', 'us-east5', 'us-west1', 
            'europe-west1', 'europe-west4', 'asia-east1', 'asia-southeast1'
        ]
        
        # Put priority regions first, then add others
        ordered_regions = priority_regions + [r for r in all_possible_regions if r not in priority_regions]
        
        if debug_mode:
            print(f'📋 Will check regions in priority order')
            print(f'🚀 Priority regions: {", ".join(priority_regions)}')
            print(f'📍 Additional regions: {len(ordered_regions) - len(priority_regions)} more regions')
        
        return ordered_regions
        
    except Exception as e:
        if debug_mode:
            print(f'⚠️  Could not determine available regions: {str(e)[:100]}')
        # Fall back to a basic set of common regions
        return ['us-central1', 'us-east1', 'us-east4', 'us-west1', 'europe-west1', 'asia-east1']


def analyze_error_patterns(hours=2, include_discovery=True):
    """Analyze Model Garden error patterns and response codes."""
    setup_authentication()
    
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    # Only run discovery if explicitly requested
    discovered_models = {}
    if include_discovery:
        if not debug_mode:
            print('=' * 40)
        discovered_models = discover_all_deployed_models()
        if not debug_mode:
            print('=' * 40)
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        if debug_mode:
            print(f'📊 Model Garden Error Analysis (Last {hours} Hours)')
        else:
            print(f'📊 Error Analysis (Last {hours} Hours)')
        
        try:
            # Get all invocations with response codes
            results = client.list_time_series(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/model_invocation_count"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL
            )
            
            response_codes = {}
            model_errors = {}
            total_invocations = 0
            total_errors = 0
            models_with_metrics = set()
            
            for result in results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                response_code = result.metric.labels.get('response_code', 'unknown')
                
                models_with_metrics.add(model_id)
                count = sum(point.value.double_value for point in result.points)
                total_invocations += count
                
                # Track response codes
                response_codes[response_code] = response_codes.get(response_code, 0) + count
                
                # Track errors by model (non-2xx codes)
                if not response_code.startswith('2'):
                    total_errors += count
                    model_errors[model_id] = model_errors.get(model_id, 0) + count
            
            # Compare discovered models vs models with metrics (concise)
            if discovered_models and not debug_mode:
                models_without_metrics = 0
                for model_key, details in discovered_models.items():
                    model_id = details['display_name']
                    if model_id not in models_with_metrics and details['display_name'] not in models_with_metrics:
                        models_without_metrics += 1
                        if 'llama' in model_key.lower():
                            print(f'   🎯 LLAMA model without recent activity: {model_key}')
                
                if models_without_metrics > 0:
                    print(f'   💤 {models_without_metrics} deployed models without recent activity')
            
            if total_invocations > 0:
                error_rate = (total_errors / total_invocations) * 100
                
                if debug_mode or error_rate > 0:
                    print(f'Invocations: {total_invocations:.0f}, Errors: {total_errors:.0f}, Rate: {error_rate:.2f}%')
                
                if debug_mode:
                    print('')
                    print('Response Code Distribution:')
                    for code in sorted(response_codes.keys()):
                        count = response_codes[code]
                        percentage = (count / total_invocations) * 100
                        error_type = 'Success' if code.startswith('2') else 'Client Error' if code.startswith('4') else 'Server Error' if code.startswith('5') else 'Other'
                        print(f'  {code} ({error_type}): {count:.0f} ({percentage:.1f}%)')
                
                if model_errors:
                    if debug_mode:
                        print('')
                        print('⚠️  Models with Errors:')
                        for model, errors in sorted(model_errors.items(), key=lambda x: x[1], reverse=True)[:5]:
                            print(f'  {model}: {errors:.0f} errors')
                    else:
                        print(f'   ⚠️  {len(model_errors)} models with errors')
                    
                    if any(code.startswith('4') for code in response_codes.keys()):
                        print('')
                        print('🔍 Client errors (4xx) detected - check authentication, quotas, or request format')
                    if any(code.startswith('5') for code in response_codes.keys()):
                        print('')
                        print('🔍 Server errors (5xx) detected - may indicate service issues or capacity problems')
                else:
                    if not debug_mode and error_rate == 0:
                        print('   ✅ No errors detected')
                    elif debug_mode:
                        print('')
                        print('✅ No errors detected in Model Garden invocations')
                    
                print(f'HIGH_ERROR_RATE:{"true" if error_rate > 5 else "false"}')
                print(f'ERROR_COUNT:{total_errors:.0f}')
                
            else:
                print('No Model Garden invocation data found')
                if discovered_models and not debug_mode:
                    print(f'({len(discovered_models)} models deployed but no metrics)')
                elif debug_mode:
                    print('This could indicate no Model Garden usage or monitoring data collection issues')
                print('HIGH_ERROR_RATE:false')
                print('ERROR_COUNT:0')
                
        except Exception as e:
            if '403' in str(e) or 'Permission' in str(e):
                print('❌ Permission denied accessing invocation metrics')
                if debug_mode:
                    print('   Required permission: monitoring.timeSeries.list')
                    print('   Service account needs: Monitoring Viewer role')
            else:
                print(f"⚠️  Error querying invocation metrics: {e}")
            print('HIGH_ERROR_RATE:false')
            print('ERROR_COUNT:0')
                
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('HIGH_ERROR_RATE:false')
        print('ERROR_COUNT:0')


def analyze_latency_performance(hours=2, include_discovery=True):
    """Analyze Model Garden latency performance."""
    setup_authentication()
    
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    # First discover all models if requested
    discovered_models = {}
    if include_discovery:
        if not debug_mode:
            print('=' * 40)
        discovered_models = discover_all_deployed_models()
        if not debug_mode:
            print('=' * 40)
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        if debug_mode:
            print(f'🚀 Model Garden Latency Analysis (Last {hours} Hours)')
        else:
            print(f'🚀 Latency Analysis (Last {hours} Hours)')
        
        try:
            # Get model invocation latencies
            results = client.list_time_series(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/model_invocation_latencies"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL
            )
            
            model_latencies = {}
            models_with_latency_metrics = set()
            
            for result in results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                models_with_latency_metrics.add(model_id)
                latencies = [point.value.double_value for point in result.points]
                
                if latencies:
                    avg_latency = sum(latencies) / len(latencies)
                    max_latency = max(latencies)
                    model_latencies[model_id] = {
                        'avg': avg_latency,
                        'max': max_latency,
                        'samples': len(latencies)
                    }
            
            # Compare discovered models vs models with latency metrics (concise)
            if discovered_models and not debug_mode:
                models_without_latency = 0
                for model_key, details in discovered_models.items():
                    model_id = details['display_name']
                    if model_id not in models_with_latency_metrics and details['display_name'] not in models_with_latency_metrics:
                        models_without_latency += 1
                        if 'llama' in model_key.lower():
                            print(f'   🎯 LLAMA model without latency data: {model_key}')
                
                if models_without_latency > 0:
                    print(f'   💤 {models_without_latency} deployed models without latency data')
            
            if model_latencies:
                high_latency_models = []
                elevated_latency_models = []
                
                if debug_mode:
                    print('')
                    print('Model Invocation Latencies:')
                
                for model, data in sorted(model_latencies.items(), key=lambda x: x[1]['avg']):
                    avg_latency = data['avg']
                    max_latency = data['max']
                    samples = data['samples']
                    
                    performance_level = 'Excellent'
                    if avg_latency >= 30:
                        performance_level = 'Poor'
                        high_latency_models.append(model)
                    elif avg_latency >= 10:
                        performance_level = 'Fair-Poor'
                        elevated_latency_models.append(model)
                    elif avg_latency >= 5:
                        performance_level = 'Good'
                    
                    if debug_mode:
                        print(f'  {model}: {avg_latency:.2f}s avg, {max_latency:.2f}s max ({samples} samples) - {performance_level}')
                    elif avg_latency >= 5:  # Only show problematic ones in non-debug
                        print(f'   ⚠️  {model}: {avg_latency:.1f}s avg ({performance_level})')
                
                if not debug_mode:
                    if high_latency_models:
                        print(f'   🚨 {len(high_latency_models)} models with high latency (>30s)')
                    elif elevated_latency_models:
                        print(f'   ⚠️  {len(elevated_latency_models)} models with elevated latency (10-30s)')
                    else:
                        print(f'   ✅ {len(model_latencies)} models with good latency (<10s)')
                
                print(f'HIGH_LATENCY_MODELS:{len(high_latency_models)}')
                print(f'ELEVATED_LATENCY_MODELS:{len(elevated_latency_models)}')
                
                # Get first token latencies (debug mode only)
                if debug_mode:
                    first_token_results = client.list_time_series(
                        name=project_name,
                        filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/first_token_latencies"',
                        interval=interval,
                        view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL
                    )
                    
                    first_token_data = {}
                    for result in first_token_results:
                        model_id = result.resource.labels.get('model_user_id', 'unknown')
                        latencies = [point.value.double_value for point in result.points]
                        if latencies:
                            first_token_data[model_id] = sum(latencies) / len(latencies)
                    
                    if first_token_data:
                        print('')
                        print('First Token Latencies:')
                        for model, first_token_latency in sorted(first_token_data.items(), key=lambda x: x[1]):
                            status = 'Good' if first_token_latency < 10 else 'Needs Attention'
                            print(f'  {model}: {first_token_latency:.2f}s first token - {status}')
                
            else:
                print('No model invocation latency data available')
                if discovered_models:
                    if debug_mode:
                        print(f'However, {len(discovered_models)} models are deployed and available for monitoring')
                    else:
                        print(f'({len(discovered_models)} models deployed but no latency metrics)')
                print('HIGH_LATENCY_MODELS:0')
                print('ELEVATED_LATENCY_MODELS:0')
                
        except Exception as e:
            if '403' in str(e) or 'Permission' in str(e):
                print('❌ Permission denied accessing latency metrics')
                if debug_mode:
                    print('   Required permission: monitoring.timeSeries.list')
            else:
                print(f'⚠️  Error querying latency metrics: {str(e)[:100]}')
            print('HIGH_LATENCY_MODELS:0')
            print('ELEVATED_LATENCY_MODELS:0')
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('HIGH_LATENCY_MODELS:0')
        print('ELEVATED_LATENCY_MODELS:0')


def analyze_throughput_consumption(hours=2, debug=False, include_discovery=True):
    """Analyze throughput and token consumption using dashboard-style queries."""
    setup_authentication()
    
    # Override debug from environment
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    if debug_mode:
        debug = True
    
    # First discover all models if requested
    discovered_models = {}
    if include_discovery:
        if not debug_mode:
            print('=' * 40)
        discovered_models = discover_all_deployed_models()
        if not debug_mode:
            print('=' * 40)
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        if debug_mode:
            print(f'📈 Model Garden Token and Throughput Analysis (Last {hours} Hours)')
            print(f'Time range: {start_time.strftime("%Y-%m-%d %H:%M")} to {end_time.strftime("%Y-%m-%d %H:%M")} UTC')
        else:
            print(f'📈 Token Usage Analysis (Last {hours} Hours)')
        
        try:
            # Use the WORKING aggregation method (CRITICAL FIX for alignment problem)
            aggregation = monitoring_v3.Aggregation(
                alignment_period={'seconds': 60},
                per_series_aligner=monitoring_v3.Aggregation.Aligner.ALIGN_RATE,
                cross_series_reducer=monitoring_v3.Aggregation.Reducer.REDUCE_SUM,
                group_by_fields=['resource.model_user_id', 'resource.location']
            )
            
            # Get token consumption metrics with working aggregation
            token_request = monitoring_v3.ListTimeSeriesRequest(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count" resource.type="aiplatform.googleapis.com/PublisherModel"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
                aggregation=aggregation
            )
            
            token_results = list(client.list_time_series(request=token_request))
            
            model_tokens = {}
            models_found = set()
            total_token_rate = 0
            
            # Process aggregated results (this is the working method)
            for result in token_results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                location = result.resource.labels.get('location', 'unknown')
                model_key = f"{model_id} ({location})"
                models_found.add(model_key)
                
                if result.points:
                    recent_points = sorted(result.points, key=lambda p: p.interval.end_time.timestamp(), reverse=True)[:10]
                    rates = [point.value.double_value for point in recent_points if point.value.double_value > 0]
                    
                    if rates:
                        avg_rate = sum(rates) / len(rates)
                        max_rate = max(rates)
                        total_token_rate += avg_rate
                        model_tokens[model_key] = avg_rate
                        
                        if debug_mode:
                            print(f'🔍 Active Token Stream: {model_key}')
                            print(f'   Average rate: {avg_rate:.2f} tokens/sec')
                            print(f'   Peak rate: {max_rate:.2f} tokens/sec')
                        else:
                            print(f'   ✅ {model_key}: {avg_rate:.1f} tokens/sec')
            
            if debug_mode:
                print(f'📋 Discovery: Found {len(models_found)} models with metrics')
                if models_found:
                    print('🤖 Models with Active Metrics:')
                    for model in sorted(models_found):
                        print(f'  • {model}')
            
            # Compare with discovered models (concise version)
            if discovered_models and not debug_mode:
                models_without_usage = 0
                for model_key, details in discovered_models.items():
                    found_in_metrics = any(details['display_name'] in metric_model or details['model_id'] in metric_model 
                                         for metric_model in models_found)
                    if not found_in_metrics:
                        models_without_usage += 1
                        if 'llama' in model_key.lower():
                            print(f'   🎯 LLAMA model without recent usage: {model_key}')
                
                if models_without_usage > 0 and debug_mode:
                    print(f'   📊 {models_without_usage} deployed models without token usage')
            
            # Display results
            has_meaningful_tokens = total_token_rate > 0
            
            if has_meaningful_tokens:
                if not debug_mode:
                    print(f'\n💡 Total consumption: {total_token_rate:.1f} tokens/sec across {len(model_tokens)} models')
                else:
                    print(f'\n📊 Active Token Consumption (Total: {total_token_rate:.2f} tokens/sec):')
                    for model in sorted(model_tokens.keys(), key=lambda x: model_tokens[x], reverse=True):
                        rate = model_tokens[model]
                        print(f'  {model}: {rate:.2f} tokens/sec')
            else:
                print('\n📊 No active token consumption detected')
                if models_found:
                    print('Models configured but no usage in time window')
                elif discovered_models:
                    print(f'{len(discovered_models)} models deployed but no metrics')
                else:
                    print('No models or metrics found')
            
            if debug_mode:
                print('\n💡 Analysis Summary:')
                if has_meaningful_tokens:
                    print('  ✅ Active Model Garden usage detected')
                    print(f'  • Total token rate: {total_token_rate:.2f} tokens/sec')
                    print('  • Monitor usage trends to predict quota needs')
                    print('  • Consider provisioned throughput for consistent high-volume models')
                    print('  • Review token efficiency for cost optimization')
                    print('COST_OPTIMIZATION_OPPORTUNITY:false')
                else:
                    if models_found:
                        print('  📊 Models are configured but showing no active usage in this time window')
                        print('  • Models may be idle or usage may be outside the time window')
                        print(f'  • Try extending the time window (--hours {hours*2} or --hours 24)')
                    elif discovered_models:
                        print(f'  📊 {len(discovered_models)} models deployed but no metrics found')
                        print('  • Models may be recently deployed and not yet generating metrics')
                        print('  • Models may be idle or not receiving traffic')
                        print('  • Try sending test requests to generate metrics')
                    else:
                        print('  📊 No Model Garden models or metrics found')
                        print('  • Verify Model Garden is deployed in this project')
                        print('  • Check if models are deployed in a different region')
                    print('COST_OPTIMIZATION_OPPORTUNITY:false')
            
            print(f'HAS_USAGE_DATA:{"true" if has_meaningful_tokens else "false"}')
            print(f'TOTAL_TOKEN_RATE:{total_token_rate:.2f}')
            print(f'TOTAL_THROUGHPUT:0.00')
            print(f'MODELS_FOUND:{len(models_found)}')
            print(f'MODELS_DISCOVERED:{len(discovered_models) if discovered_models else 0}')
            
        except Exception as e:
            if '403' in str(e) or 'Permission' in str(e):
                print('❌ Permission denied accessing throughput metrics')
                print('   Required permission: monitoring.timeSeries.list')
            else:
                print(f'⚠️  Error querying throughput metrics: {str(e)[:100]}')
            print('HAS_USAGE_DATA:false')
            print('ISSUE_SEVERITY:1')  # Critical - monitoring failure
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('HAS_USAGE_DATA:false')
        print('ISSUE_SEVERITY:1')  # Critical - auth failure


def check_service_health():
    """Check Model Garden service health and available metrics."""
    setup_authentication()
    
    try:
        client, project_name = get_monitoring_client()
        
        print('🔧 Service Configuration Check')
        
        try:
            descriptors = client.list_metric_descriptors(name=project_name)
            
            vertex_metrics = 0
            total_checked = 0
            
            for descriptor in descriptors:
                total_checked += 1
                if 'aiplatform.googleapis.com/publisher/online_serving' in descriptor.type:
                    vertex_metrics += 1
                
                # Limit iterations to avoid timeout
                if total_checked > 500:
                    break
            
            print(f'Model Garden Metrics Available: {vertex_metrics}')
            
            if vertex_metrics == 0:
                print('⚠️  No Model Garden metrics found - this could indicate:')
                print('   • No Model Garden usage in this project')
                print('   • Model Garden not available in this region')
                print('   • Monitoring not properly configured')
            else:
                print('✅ Model Garden metrics are available for monitoring')
                
            print(f'METRICS_AVAILABLE:{vertex_metrics}')
            
        except Exception as e:
            if '403' in str(e) or 'Permission' in str(e):
                print('❌ Permission denied accessing metric descriptors')
                print('   Required permission: monitoring.metricDescriptors.list')
                print('   Service account needs: Monitoring Viewer role')
            else:
                print(f'⚠️  Error checking metrics: {str(e)[:100]}')
            print('METRICS_AVAILABLE:0')
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('METRICS_AVAILABLE:0')


def generate_health_report_table(hours=2):
    """Generate a normalized tabular health report using the working SDK pattern from throughput analysis."""
    setup_authentication()
    
    debug_mode = os.environ.get('VERTEX_AI_DEBUG', '').lower() == 'true'
    
    print('📊 VERTEX AI MODEL GARDEN - HEALTH REPORT TABLE')
    print('═' * 80)
    
    # Discover all models first
    discovered_models = discover_all_deployed_models()
    
    # Initialize model data dictionary
    model_data = {}
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        print('\n🔍 Gathering model metrics using working SDK pattern...')
        
        try:
            # Use the WORKING aggregation method from throughput analysis
            aggregation = monitoring_v3.Aggregation(
                alignment_period={'seconds': 60},
                per_series_aligner=monitoring_v3.Aggregation.Aligner.ALIGN_RATE,
                cross_series_reducer=monitoring_v3.Aggregation.Reducer.REDUCE_SUM,
                group_by_fields=['resource.model_user_id', 'resource.location']
            )
            
            # 1. Get token consumption metrics using the exact working pattern
            token_request = monitoring_v3.ListTimeSeriesRequest(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count" resource.type="aiplatform.googleapis.com/PublisherModel"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
                aggregation=aggregation
            )
            
            token_results = list(client.list_time_series(request=token_request))
            
            for result in token_results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                location = result.resource.labels.get('location', 'unknown')
                model_key = f"{model_id} ({location})"
                
                if model_key not in model_data:
                    model_data[model_key] = {
                        'model_name': model_id,
                        'region': location,
                        'deployment_type': 'MaaS' if 'maas' in model_id.lower() else 'Self-hosted',
                        'total_requests': 0,
                        'error_count': 0,
                        'success_count': 0,
                        'token_rate': 0,
                        'avg_latency': 0,
                        'status': 'Unknown',
                        'error_rate': 'N/A'
                    }
                
                # Calculate token rate using the same method as throughput analysis
                if result.points:
                    recent_points = sorted(result.points, key=lambda p: p.interval.end_time.timestamp(), reverse=True)[:10]
                    rates = [point.value.double_value for point in recent_points if point.value.double_value > 0]
                    
                    if rates:
                        avg_rate = sum(rates) / len(rates)
                        model_data[model_key]['token_rate'] = avg_rate
                        
            if debug_mode and model_data:
                print(f'✅ Found {len(model_data)} models with token usage')
                
        except Exception as e:
            if debug_mode:
                print(f'⚠️  Error querying token metrics: {str(e)[:100]}')
        
        try:
            # 2. Get invocation metrics using the same pattern
            invocation_request = monitoring_v3.ListTimeSeriesRequest(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/model_invocation_count" resource.type="aiplatform.googleapis.com/PublisherModel"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
                aggregation=aggregation
            )
            
            invocation_results = list(client.list_time_series(request=invocation_request))
            
            for result in invocation_results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                location = result.resource.labels.get('location', 'unknown')
                response_code = result.metric.labels.get('response_code', '200')
                model_key = f"{model_id} ({location})"
                
                if model_key not in model_data:
                    model_data[model_key] = {
                        'model_name': model_id,
                        'region': location,
                        'deployment_type': 'MaaS' if 'maas' in model_id.lower() else 'Self-hosted',
                        'total_requests': 0,
                        'error_count': 0,
                        'success_count': 0,
                        'token_rate': 0,
                        'avg_latency': 0,
                        'status': 'Unknown',
                        'error_rate': 'N/A'
                    }
                
                # Calculate request counts
                if result.points:
                    recent_points = sorted(result.points, key=lambda p: p.interval.end_time.timestamp(), reverse=True)[:10]
                    rates = [point.value.double_value for point in recent_points if point.value.double_value > 0]
                    
                    if rates:
                        avg_rate = sum(rates) / len(rates)
                        model_data[model_key]['total_requests'] += avg_rate * hours * 3600  # Convert back to total requests
                        
                        # Count errors vs success based on response code
                        if response_code.startswith('2'):
                            model_data[model_key]['success_count'] += avg_rate * hours * 3600
                        else:
                            model_data[model_key]['error_count'] += avg_rate * hours * 3600
                            
            if debug_mode and len(model_data) > 0:
                print(f'✅ Found invocation data for models')
                
        except Exception as e:
            if debug_mode:
                print(f'⚠️  Error querying invocation metrics: {str(e)[:100]}')
        
        try:
            # 3. Get latency metrics using the same pattern
            latency_request = monitoring_v3.ListTimeSeriesRequest(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/response_latency" resource.type="aiplatform.googleapis.com/PublisherModel"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
                aggregation=aggregation
            )
            
            latency_results = list(client.list_time_series(request=latency_request))
            
            for result in latency_results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                location = result.resource.labels.get('location', 'unknown')
                model_key = f"{model_id} ({location})"
                
                if model_key in model_data:
                    if result.points:
                        recent_points = sorted(result.points, key=lambda p: p.interval.end_time.timestamp(), reverse=True)[:10]
                        latencies = [point.value.double_value for point in recent_points if point.value.double_value > 0]
                        
                        if latencies:
                            model_data[model_key]['avg_latency'] = sum(latencies) / len(latencies)
                        
            if debug_mode:
                print(f'✅ Found latency data for models')
                
        except Exception as e:
            if debug_mode:
                print(f'⚠️  Error querying latency metrics: {str(e)[:100]}')
        
        # 4. Include discovered models that might not have metrics
        for region, endpoints in discovered_models.items():
            for endpoint_info in endpoints:
                if 'models' in endpoint_info:
                    for model in endpoint_info['models']:
                        model_name = model.get('name', 'unknown')
                        model_key = f"{model_name} ({region})"
                        if model_key not in model_data:
                            model_data[model_key] = {
                                'model_name': model_name,
                                'region': region,
                                'deployment_type': 'Self-hosted',
                                'total_requests': 0,
                                'error_count': 0,
                                'success_count': 0,
                                'token_rate': 0,
                                'avg_latency': 0,
                                'status': '⚪ No Traffic',
                                'error_rate': 'N/A'
                            }
        
        # 5. Determine status for each model based on metrics
        for model_key, data in model_data.items():
            # If we have token usage, the model is definitely active
            if data['token_rate'] > 0:
                if data['total_requests'] > 0:
                    error_rate = (data['error_count'] / data['total_requests']) * 100
                    
                    if error_rate > 10:
                        data['status'] = '🔴 Critical'
                    elif error_rate > 5:
                        data['status'] = '🟡 Warning'
                    elif data.get('avg_latency', 0) > 30:
                        data['status'] = '🟡 Slow'
                    else:
                        data['status'] = '🟢 Healthy'
                        
                    data['error_rate'] = f"{error_rate:.1f}%"
                else:
                    # Has token usage but no request metrics - still active
                    data['status'] = '🟢 Active'
                    data['error_rate'] = 'N/A'
            elif data['total_requests'] > 0:
                # Has requests but no token data
                error_rate = (data['error_count'] / data['total_requests']) * 100
                data['status'] = '🟡 Limited' if error_rate < 5 else '🔴 Issues'
                data['error_rate'] = f"{error_rate:.1f}%"
            else:
                # No activity detected
                data['status'] = '⚪ Inactive'
                data['error_rate'] = 'N/A'
        
        # 6. Generate the table
        if model_data:
            print('\n')
            print('┌─' + '─' * 40 + '─┬─' + '─' * 12 + '─┬─' + '─' * 12 + '─┬─' + '─' * 12 + '─┬─' + '─' * 12 + '─┬─' + '─' * 12 + '─┐')
            print('│ Model Name                               │ Type         │ Region       │ Status       │ Token/sec    │ Error Rate   │')
            print('├─' + '─' * 40 + '─┼─' + '─' * 12 + '─┼─' + '─' * 12 + '─┼─' + '─' * 12 + '─┼─' + '─' * 12 + '─┼─' + '─' * 12 + '─┤')
            
            # Sort by status (healthy first, then by token rate)
            sorted_models = sorted(model_data.values(), key=lambda x: (x['status'], -x['token_rate'], x['model_name']))
            
            for data in sorted_models:
                model_name = data['model_name'][:40]  # Truncate if too long
                deployment_type = data['deployment_type'][:12]
                region = data['region'][:12]
                status = data['status'][:12]
                token_rate = f"{data['token_rate']:.1f}" if data['token_rate'] > 0 else '-'
                error_rate = data['error_rate'][:12]
                
                print(f'│ {model_name:<40} │ {deployment_type:<12} │ {region:<12} │ {status:<12} │ {token_rate:>12} │ {error_rate:>12} │')
            
            print('└─' + '─' * 40 + '─┴─' + '─' * 12 + '─┴─' + '─' * 12 + '─┴─' + '─' * 12 + '─┴─' + '─' * 12 + '─┴─' + '─' * 12 + '─┘')
            
            # Summary statistics
            print()
            print('📈 SUMMARY STATISTICS:')
            healthy_count = len([m for m in model_data.values() if '🟢' in m['status']])
            warning_count = len([m for m in model_data.values() if '🟡' in m['status']])
            critical_count = len([m for m in model_data.values() if '🔴' in m['status']])
            inactive_count = len([m for m in model_data.values() if '⚪' in m['status']])
            
            print(f'  • Total Models: {len(model_data)}')
            print(f'  • Healthy/Active: {healthy_count} 🟢')
            print(f'  • Warning: {warning_count} 🟡') 
            print(f'  • Critical: {critical_count} 🔴')
            print(f'  • Inactive: {inactive_count} ⚪')
            
            # Token consumption summary
            total_token_rate = sum(m['token_rate'] for m in model_data.values())
            if total_token_rate > 0:
                print(f'  • Total Token Rate: {total_token_rate:.1f} tokens/sec')
            
            # Export for programmatic use
            print()
            print('📊 EXPORT DATA:')
            print(f'TOTAL_MODELS:{len(model_data)}')
            print(f'HEALTHY_MODELS:{healthy_count}')
            print(f'WARNING_MODELS:{warning_count}') 
            print(f'CRITICAL_MODELS:{critical_count}')
            print(f'INACTIVE_MODELS:{inactive_count}')
            print(f'TOTAL_TOKEN_RATE:{total_token_rate:.2f}')
        else:
            print('\n📝 No models found with monitoring data')
            print('TOTAL_MODELS:0')
            
    except Exception as e:
        print(f'❌ Error generating health report: {str(e)[:100]}')
        if debug_mode:
            import traceback
            traceback.print_exc()
        print('TOTAL_MODELS:0')


def main():
    """Main entry point with command line parsing."""
    parser = argparse.ArgumentParser(description='Vertex AI Model Garden Health Monitoring')
    parser.add_argument('command', choices=['errors', 'latency', 'throughput', 'health', 'discover', 'report'], 
                       help='Analysis type to perform')
    parser.add_argument('--hours', type=int, default=2, help='Time window in hours (default: 2)')
    parser.add_argument('--debug', action='store_true', help='Enable debug output')
    parser.add_argument('--fast', action='store_true', help='Use fast mode (5 common US regions)')
    parser.add_argument('--us-only', action='store_true', help='Check US regions only')
    parser.add_argument('--priority-regions', action='store_true', help='Check 9 priority regions worldwide')
    parser.add_argument('--regions', type=str, help='Comma-separated list of specific regions')
    parser.add_argument('--no-discovery', action='store_true', help='Skip model discovery in analysis commands')
    
    args = parser.parse_args()
    
    # Set debug mode environment variable
    if args.debug:
        os.environ['VERTEX_AI_DEBUG'] = 'true'
    
    # Set region environment variable based on arguments
    if args.fast:
        os.environ['VERTEX_AI_REGIONS'] = 'us-central1,us-east1,us-east4,us-east5,us-west1'
        print('🚀 Fast mode: Checking common US regions only')
    elif args.us_only:
        os.environ['VERTEX_AI_REGIONS'] = 'us-central1,us-east1,us-east4,us-east5,us-west1,us-west2,us-west3,us-west4'
        print('🇺🇸 US-only mode: Checking all US regions')
    elif args.priority_regions:
        os.environ['VERTEX_AI_REGIONS'] = 'us-central1,us-east1,us-east4,us-west1,europe-west1,europe-west4,asia-east1,asia-southeast1,australia-southeast1'
        print('🌍 Priority regions mode: Checking 9 common worldwide regions')
    elif args.regions:
        os.environ['VERTEX_AI_REGIONS'] = args.regions
        print(f'🎯 Custom regions mode: {args.regions}')
    
    try:
        if args.command == 'errors':
            analyze_error_patterns(hours=args.hours, include_discovery=not args.no_discovery)
        elif args.command == 'latency':
            analyze_latency_performance(hours=args.hours, include_discovery=not args.no_discovery)
        elif args.command == 'throughput':
            analyze_throughput_consumption(hours=args.hours, debug=args.debug, include_discovery=not args.no_discovery)
        elif args.command == 'health':
            check_service_health()
        elif args.command == 'discover':
            discover_all_deployed_models()
        elif args.command == 'report':
            generate_health_report_table(hours=args.hours)
    except Exception as e:
        print(f'❌ Error: {str(e)[:200]}')
        sys.exit(1)


if __name__ == '__main__':
    main() 