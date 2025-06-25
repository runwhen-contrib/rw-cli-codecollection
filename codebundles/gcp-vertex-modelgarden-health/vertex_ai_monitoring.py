#!/usr/bin/env python3
"""
Vertex AI Model Garden monitoring utilities using Google Cloud Monitoring Python SDK.
"""

import os
import sys
import argparse
from datetime import datetime, timedelta, timezone
from google.cloud import monitoring_v3
from google.auth import default


def setup_authentication():
    """Set up Google Cloud authentication."""
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS', '')


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


def analyze_error_patterns(hours=2):
    """Analyze Model Garden error patterns and response codes."""
    setup_authentication()
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        print(f'📊 Model Garden Error Analysis (Last {hours} Hours)')
        
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
            
            for result in results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                response_code = result.metric.labels.get('response_code', 'unknown')
                
                count = sum(point.value.double_value for point in result.points)
                total_invocations += count
                
                # Track response codes
                response_codes[response_code] = response_codes.get(response_code, 0) + count
                
                # Track errors by model (non-2xx codes)
                if not response_code.startswith('2'):
                    total_errors += count
                    model_errors[model_id] = model_errors.get(model_id, 0) + count
            
            if total_invocations > 0:
                error_rate = (total_errors / total_invocations) * 100
                
                print(f'Total Invocations: {total_invocations:.0f}')
                print(f'Total Errors: {total_errors:.0f}')
                print(f'Error Rate: {error_rate:.2f}%')
                print('')
                print('Response Code Distribution:')
                
                for code in sorted(response_codes.keys()):
                    count = response_codes[code]
                    percentage = (count / total_invocations) * 100
                    error_type = 'Success' if code.startswith('2') else 'Client Error' if code.startswith('4') else 'Server Error' if code.startswith('5') else 'Other'
                    print(f'  {code} ({error_type}): {count:.0f} ({percentage:.1f}%)')
                
                if model_errors:
                    print('')
                    print('⚠️  Models with Errors:')
                    for model, errors in sorted(model_errors.items(), key=lambda x: x[1], reverse=True)[:5]:
                        print(f'  {model}: {errors:.0f} errors')
                    
                    if any(code.startswith('4') for code in response_codes.keys()):
                        print('')
                        print('🔍 Client errors (4xx) detected - check authentication, quotas, or request format')
                    if any(code.startswith('5') for code in response_codes.keys()):
                        print('')
                        print('🔍 Server errors (5xx) detected - may indicate service issues or capacity problems')
                else:
                    print('')
                    print('✅ No errors detected in Model Garden invocations')
                    
                print(f'HIGH_ERROR_RATE:{"true" if error_rate > 5 else "false"}')
                print(f'ERROR_COUNT:{total_errors:.0f}')
                
            else:
                print('No Model Garden invocation data found')
                print('This could indicate no Model Garden usage or monitoring data collection issues')
                print('HIGH_ERROR_RATE:false')
                print('ERROR_COUNT:0')
                
        except Exception as e:
            if '403' in str(e) or 'Permission' in str(e):
                print('❌ Permission denied accessing invocation metrics')
                print('   Required permission: monitoring.timeSeries.list')
                print('   Service account needs: Monitoring Viewer role')
            else:
                print(f'⚠️  Error querying invocation metrics: {str(e)[:100]}')
            print('HIGH_ERROR_RATE:false')
            print('ERROR_COUNT:0')
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('HIGH_ERROR_RATE:false')
        print('ERROR_COUNT:0')


def analyze_latency_performance(hours=2):
    """Analyze Model Garden latency performance."""
    setup_authentication()
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        print(f'🚀 Model Garden Latency Analysis (Last {hours} Hours)')
        
        try:
            # Get model invocation latencies
            results = client.list_time_series(
                name=project_name,
                filter='metric.type="aiplatform.googleapis.com/publisher/online_serving/model_invocation_latencies"',
                interval=interval,
                view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL
            )
            
            model_latencies = {}
            
            for result in results:
                model_id = result.resource.labels.get('model_user_id', 'unknown')
                latencies = [point.value.double_value for point in result.points]
                
                if latencies:
                    avg_latency = sum(latencies) / len(latencies)
                    max_latency = max(latencies)
                    model_latencies[model_id] = {
                        'avg': avg_latency,
                        'max': max_latency,
                        'samples': len(latencies)
                    }
            
            if model_latencies:
                print('')
                print('Model Invocation Latencies:')
                high_latency_models = []
                elevated_latency_models = []
                
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
                    
                    print(f'  {model}: {avg_latency:.2f}s avg, {max_latency:.2f}s max ({samples} samples) - {performance_level}')
                
                print(f'HIGH_LATENCY_MODELS:{len(high_latency_models)}')
                print(f'ELEVATED_LATENCY_MODELS:{len(elevated_latency_models)}')
                
                # Get first token latencies
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
                print('HIGH_LATENCY_MODELS:0')
                print('ELEVATED_LATENCY_MODELS:0')
                
        except Exception as e:
            if '403' in str(e) or 'Permission' in str(e):
                print('❌ Permission denied accessing latency metrics')
                print('   Required permission: monitoring.timeSeries.list')
            else:
                print(f'⚠️  Error querying latency metrics: {str(e)[:100]}')
            print('HIGH_LATENCY_MODELS:0')
            print('ELEVATED_LATENCY_MODELS:0')
            
    except Exception as auth_error:
        print(f'❌ Authentication error: {str(auth_error)[:100]}')
        print('HIGH_LATENCY_MODELS:0')
        print('ELEVATED_LATENCY_MODELS:0')


def analyze_throughput_consumption(hours=2, debug=False):
    """Analyze throughput and token consumption using dashboard-style queries."""
    setup_authentication()
    
    try:
        client, project_name = get_monitoring_client()
        
        # Set time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=hours)
        interval = monitoring_v3.TimeInterval(end_time=end_time, start_time=start_time)
        
        print(f'📈 Model Garden Token and Throughput Analysis (Last {hours} Hours)')
        print(f'Time range: {start_time.strftime("%Y-%m-%d %H:%M")} to {end_time.strftime("%Y-%m-%d %H:%M")} UTC')
        
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
                        
                        print(f'🔍 Active Token Stream: {model_key}')
                        print(f'   Average rate: {avg_rate:.2f} tokens/sec')
                        print(f'   Peak rate: {max_rate:.2f} tokens/sec')
            
            print(f'📋 Discovery: Found {len(models_found)} models')
            if models_found:
                print('🤖 Models with Active Metrics:')
                for model in sorted(models_found):
                    print(f'  • {model}')
            
            # Display results with enhanced features
            has_meaningful_tokens = total_token_rate > 0
            
            if has_meaningful_tokens:
                print('')
                print(f'📊 Active Token Consumption (Total: {total_token_rate:.2f} tokens/sec):')
                
                for model in sorted(model_tokens.keys(), key=lambda x: model_tokens[x], reverse=True):
                    rate = model_tokens[model]
                    print(f'  {model}: {rate:.2f} tokens/sec')
                    
            else:
                print('')
                print('📊 Token Status: No active token consumption detected')
                if models_found:
                    print('ISSUE_SEVERITY:3')  # Medium - models but no usage
                else:
                    print('ISSUE_SEVERITY:2')  # High - no models
            
            print('')
            print('💡 Analysis Summary:')
            
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
                else:
                    print('  📊 No Model Garden models or metrics found')
                    print('  • Verify Model Garden is deployed in this project')
                    print('  • Check if models are deployed in a different region')
                print('COST_OPTIMIZATION_OPPORTUNITY:false')
            
            print(f'HAS_USAGE_DATA:{"true" if has_meaningful_tokens else "false"}')
            print(f'TOTAL_TOKEN_RATE:{total_token_rate:.2f}')
            print(f'TOTAL_THROUGHPUT:0.00')
            print(f'MODELS_FOUND:{len(models_found)}')
            
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


def main():
    """Main function for command-line usage."""
    parser = argparse.ArgumentParser(description='Vertex AI Model Garden monitoring utilities')
    parser.add_argument('command', choices=['errors', 'latency', 'throughput', 'health'],
                        help='Monitoring command to run')
    parser.add_argument('--hours', type=int, default=2,
                        help='Number of hours to analyze (default: 2)')
    
    args = parser.parse_args()
    
    if args.command == 'errors':
        analyze_error_patterns(args.hours)
    elif args.command == 'latency':
        analyze_latency_performance(args.hours)
    elif args.command == 'throughput':
        analyze_throughput_consumption(args.hours)
    elif args.command == 'health':
        check_service_health()


if __name__ == '__main__':
    main() 