#!/usr/bin/env python3
"""
Azure Resource Dependency Graph Generator

This script generates a visual dependency graph of Azure resources in a subscription
using the Azure Resource Graph service.
"""

import argparse
import json
import subprocess
import sys
import os
import time
import logging
import tempfile
from typing import Dict, List, Set, Tuple, Optional, Any, Callable, TypeVar
from functools import wraps

logger = logging.getLogger(__name__)

# Import the visualization modules
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

# Global list to collect non-fatal errors and warnings
_failed_operations_log: List[str] = []

# Type variable for decorator
F = TypeVar('F', bound=Callable[..., Any])
DEFAULT_TIMEOUT = 300  # Default timeout for subprocess commands in seconds

def log_failure(message: str):
    """Logs a failure message that allows the script to continue."""
    global _failed_operations_log
    _failed_operations_log.append(message)
    logger.warning(f"Warning: {message}")

def truncate_subscription_id(subscription_id: str) -> str:
    """
    Truncate subscription ID to first 10 characters plus ellipsis.
    
    Args:
        subscription_id: The full Azure subscription ID
        
    Returns:
        Truncated subscription ID
    """
    return subscription_id[:10] + "..."

def retry_with_backoff(max_retries: int = 3, initial_delay: float = 1.0, backoff_factor: float = 2.0) -> Callable[[F], F]:
    """
    A decorator to retry a function with exponential backoff.
    
    Args:
        max_retries: Maximum number of times to retry the function.
        initial_delay: Initial delay in seconds before the first retry.
        backoff_factor: Factor by which the delay increases for each retry.
    """
    def decorator(func: F) -> F:
        @wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            delay = initial_delay
            for i in range(max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except subprocess.CalledProcessError as e:
                    # Check for throttling or other retryable errors
                    stderr_output = e.stderr.decode() if e.stderr else ""
                    if "RateLimiting" in stderr_output or "TooManyRequests" in stderr_output or "Throttled" in stderr_output:
                        log_failure(f"Attempt {i+1}/{max_retries+1}: Command failed due to throttling. Retrying in {delay:.2f}s. Command: {args[0] if args else 'N/A'}")
                        if i < max_retries:
                            time.sleep(delay)
                            delay *= backoff_factor
                        else:
                            log_failure(f"Max retries reached for command: {args[0] if args else 'N/A'}. Giving up.")
                            raise # Re-raise the last exception if max retries reached
                    else:
                        # For non-retryable errors, re-raise immediately
                        raise
                except Exception as e:
                    raise
            return None # Should not be reached
        return wrapper
    return decorator

def run_subprocess_with_timeout(cmd, timeout=DEFAULT_TIMEOUT, shell=False) -> Tuple[str, str]:
    """
    Run a subprocess command with timeout and proper error handling.
    
    Args:
        cmd: Command to run (list or string)
        timeout: Timeout in seconds
        shell: Whether to run command in shell
        
    Returns:
        Tuple of (stdout, stderr) or raises exception
    """
    logger.debug(f"Running command with {timeout}s timeout: {cmd}")
    
    process = None
    try:
        # Use Popen instead of run to have better control
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=shell,
            text=True,
            universal_newlines=True
        )
        
        # Use communicate with timeout to avoid deadlocks
        stdout, stderr = process.communicate(timeout=timeout)
        
        if process.returncode != 0:
            logger.warning(f"Command failed with code {process.returncode}: {stderr}")
            raise subprocess.CalledProcessError(process.returncode, cmd, output=stdout, stderr=stderr)
        
        return stdout, stderr
    
    except subprocess.TimeoutExpired:
        # Kill the process if it times out
        if process is not None:
            process.kill()
            _, stderr = process.communicate()
        else:
            stderr = ""
        logger.error(f"Command timed out after {timeout}s: {cmd}")
        log_failure(f"Command timed out after {timeout}s: {cmd}")
        raise TimeoutError(f"Command timed out after {timeout}s: {cmd}")
    
    except Exception as e:
        logger.error(f"Error executing command {cmd}: {str(e)}")
        raise

@retry_with_backoff()
def run_az_command(command: str) -> Optional[Any]:
    """
    Run an Azure CLI command and return its output (JSON parsed or raw string).
    
    Args:
        command: The Azure CLI command to run
        
    Returns:
        The parsed JSON output (dict/list), raw string output, or None if an error occurs.
    """
    try:
        result = subprocess.run(command, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=DEFAULT_TIMEOUT)
        
        if result.stdout.strip():
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError:
                # If not valid JSON, return the raw string output
                return result.stdout.strip()
        return None # Command ran successfully but returned no output
    except subprocess.CalledProcessError as e:
        # This will be caught by the decorator's exception handling
        raise
    except Exception as e: # Catch any other unexpected errors
        # This will be caught by the decorator's exception handling
        raise

@retry_with_backoff()
def run_az_command_list(command: List[str], subscription_id: Optional[str] = None) -> Dict[str, Any]:
    """
    Run an Azure CLI command from a list and return the JSON output.
    
    Args:
        command: The Azure CLI command as a list
        subscription_id: Optional subscription ID
        
    Returns:
        The parsed JSON output of the command
    """
    full_command = list(command) # Create a copy to avoid modifying the original list
    try:
        if subscription_id:
            full_command.extend(['--subscription', subscription_id])
        
        result = subprocess.run(
            full_command,
            capture_output=True,
            text=True,
            check=True
        )
        
        if result.stdout.strip():
            return json.loads(result.stdout)
        return {}
        
    except subprocess.CalledProcessError as e:
        # This will be caught by the decorator's exception handling
        raise
    except json.JSONDecodeError as e:
        log_failure(f"Error parsing JSON response from command {' '.join(full_command)}: {e}")
        return {}
    except Exception as e:
        # This will be caught by the decorator's exception handling
        raise

def check_az_cli_installed() -> bool:
    """Check if Azure CLI is installed."""
    try:
        process = subprocess.Popen(["az", "--version"], stdout=subprocess.PIPE, shell=True, stderr=subprocess.PIPE, text=True)
        stdout, stderr = process.communicate(timeout=10)
        if process.returncode != 0:
            log_failure(f"Azure CLI is not installed or not found in PATH. Error: {stderr.strip()}")
            return False
        logger.info(f"Azure CLI version: {stdout.strip()}")
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

def check_az_cli_logged_in() -> bool:
    """Check if the user is logged in to Azure CLI."""
    try:
        logger.info("Running 'az account show' to check if Azure CLI is logged in...")
        process = subprocess.Popen(["az account show"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True, text=True)
        stdout, stderr = process.communicate(timeout=10)
        if process.returncode != 0:
            log_failure(f"Azure CLI is not logged in. Error: {stderr.strip()}")
            return False
        logger.info(f"Azure CLI is logged in successfully : {stdout.strip()}")
        return True
    except subprocess.CalledProcessError:
        return False

def get_subscription_id() -> Optional[str]:
    """Get the current Azure subscription ID."""
    try:
        result = run_az_command("az account show --query id -o json")
        if result is None:
            log_failure("Failed to retrieve subscription ID.")
            return None
        if isinstance(result, str):
            return result.strip('"')
        elif isinstance(result, dict) and 'id' in result:
            return result['id']
        log_failure(f"Unexpected format for subscription ID: {result}")
        return None
    except Exception as e:
        log_failure(f"Error in get_subscription_id: {e}")
        return None

def list_resource_groups(subscription_id: str) -> List[Dict[str, Any]]:
    """
    List all resource groups in the subscription.
    
    Args:
        subscription_id: The Azure subscription ID
        
    Returns:
        A list of resource group objects
    """
    query = f"ResourceContainers | where type == 'microsoft.resources/subscriptions/resourcegroups' | where subscriptionId == '{subscription_id}' | project name, id"
    try:
        result = run_az_command(f"az graph query -q \"{query}\" --subscription {subscription_id}")
        if result is None:
            log_failure(f"Failed to retrieve resource groups for subscription {subscription_id}.")
            return []
        if isinstance(result, dict):
            return result.get('data', [])
        log_failure(f"Unexpected format for resource groups: {result}")
        return []
    except Exception as e:
        log_failure(f"Error in list_resource_groups for subscription {subscription_id}: {e}")
        return []

def get_network_information(resource: Dict[str, Any], subscription_id: str) -> Dict[str, Any]:
    """Get network information for addressable resources"""
    resource_type = resource.get('type', '').lower()
    resource_group = resource.get('resourceGroup', '')
    name = resource.get('name', '')
    network_info = {}
    
    if not resource_group or not name:
        log_failure(f"Skipping network info for resource {name} due to missing resourceGroup or name.")
        return network_info

    try:
        # Virtual Machines
        if 'microsoft.compute/virtualmachines' in resource_type:
            vm_details = run_az_command_list([
                'az', 'vm', 'show',
                '--resource-group', resource_group,
                '--name', name,
                '--show-details'
            ], subscription_id)
            if vm_details:
                network_info.update({
                    'privateIps': vm_details.get('privateIps', []),
                    'publicIps': vm_details.get('publicIps', []),
                    'fqdns': vm_details.get('fqdns', [])
                })
        
        # Public IP Addresses
        elif 'microsoft.network/publicipaddresses' in resource_type:
            pip_details = run_az_command_list([
                'az', 'network', 'public-ip', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if pip_details:
                network_info.update({
                    'ipAddress': pip_details.get('ipAddress'),
                    'fqdn': pip_details.get('dnsSettings', {}).get('fqdn'),
                    'allocationMethod': pip_details.get('publicIPAllocationMethod')
                })
        
        # Load Balancers
        elif 'microsoft.network/loadbalancers' in resource_type:
            lb_details = run_az_command_list([
                'az', 'network', 'lb', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if lb_details:
                frontend_ips = []
                frontend_configs = lb_details.get('frontendIPConfigurations', [])
                if isinstance(frontend_configs, list):
                    for frontend in frontend_configs:
                        public_ip_address = frontend.get('publicIPAddress')
                        if public_ip_address and isinstance(public_ip_address, dict):
                            frontend_ips.append(public_ip_address.get('id', '').split('/')[-1])
                else:
                    log_failure(f"Unexpected format for 'frontendIPConfigurations' in LB {name}. Expected list, got {type(frontend_configs)}.")
                network_info['frontendIPs'] = frontend_ips
        
        # App Services
        elif 'microsoft.web/sites' in resource_type:
            app_details = run_az_command_list([
                'az', 'webapp', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if app_details:
                network_info.update({
                    'defaultHostName': app_details.get('defaultHostName'),
                    'hostNames': app_details.get('hostNames', []),
                    'outboundIpAddresses': app_details.get('outboundIpAddresses', '').split(',') if app_details.get('outboundIpAddresses') else []
                })
        
        # Storage Accounts
        elif 'microsoft.storage/storageaccounts' in resource_type:
            storage_details = run_az_command_list([
                'az', 'storage', 'account', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if storage_details:
                primary_endpoints = storage_details.get('primaryEndpoints', {})
                network_info['endpoints'] = primary_endpoints
        
    except Exception as e:
        log_failure(f"Error getting network info for {name} ({resource_type}): {str(e)}")
        
    return network_info

def get_environment_variables(resource: Dict[str, Any], subscription_id: str) -> Dict[str, Any]:
    """Get environment variables for supported resources"""
    resource_type = resource.get('type', '').lower()
    resource_group = resource.get('resourceGroup', '')
    name = resource.get('name', '')
    env_vars = {}

    if not resource_group or not name:
        log_failure(f"Skipping environment variables for resource {name} due to missing resourceGroup or name.")
        return env_vars
    
    try:
        # App Service / Web Apps
        if 'microsoft.web/sites' in resource_type:
            app_settings = run_az_command_list([
                'az', 'webapp', 'config', 'appsettings', 'list',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if isinstance(app_settings, list):
                env_vars['appSettings'] = {setting.get('name'): setting.get('value') for setting in app_settings if isinstance(setting, dict) and setting.get('name')}
            
            # Get connection strings
            conn_strings = run_az_command_list([
                'az', 'webapp', 'config', 'connection-string', 'list',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if isinstance(conn_strings, list):
                env_vars['connectionStrings'] = {cs.get('name'): cs.get('value') for cs in conn_strings if isinstance(cs, dict) and cs.get('name')}
        
        # Function Apps
        elif 'microsoft.web/sites' in resource_type and resource.get('kind', '').lower() == 'functionapp':
            func_settings = run_az_command_list([
                'az', 'functionapp', 'config', 'appsettings', 'list',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if isinstance(func_settings, list):
                env_vars['functionAppSettings'] = {setting.get('name'): setting.get('value') for setting in func_settings if isinstance(setting, dict) and setting.get('name')}
        
        # Container Instances
        elif 'microsoft.containerinstance/containergroups' in resource_type:
            container_details = run_az_command_list([
                'az', 'container', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if container_details:
                containers = container_details.get('containers', [])
                if isinstance(containers, list):
                    for i, container in enumerate(containers):
                        if isinstance(container, dict) and container.get('environmentVariables'):
                            env_vars[f'container_{i}_env'] = {
                                env.get('name'): env.get('value', env.get('secureValue', 'SECURE_VALUE'))
                                for env in container['environmentVariables'] if isinstance(env, dict) and env.get('name')
                            }
                else:
                    log_failure(f"Unexpected format for 'containers' in Container Group {name}. Expected list, got {type(containers)}.")
                        
    except Exception as e:
        log_failure(f"Error getting environment variables for {name} ({resource_type}): {str(e)}")
        
    return env_vars

def get_resource_specific_config(resource: Dict[str, Any], subscription_id: str) -> Dict[str, Any]:
    """Get resource-specific configuration details"""
    resource_type = resource.get('type', '').lower()
    resource_group = resource.get('resourceGroup', '')
    name = resource.get('name', '')
    config = {}

    if not resource_group or not name:
        log_failure(f"Skipping specific config for resource {name} due to missing resourceGroup or name.")
        return config
    
    try:
        # Virtual Machines
        if 'microsoft.compute/virtualmachines' in resource_type:
            vm_details = run_az_command_list([
                'az', 'vm', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if vm_details:
                config.update({
                    'vmSize': vm_details.get('hardwareProfile', {}).get('vmSize'),
                    'osType': vm_details.get('storageProfile', {}).get('osDisk', {}).get('osType'),
                    'imageReference': vm_details.get('storageProfile', {}).get('imageReference'),
                    'adminUsername': vm_details.get('osProfile', {}).get('adminUsername')
                })
        
        # Storage Accounts
        elif 'microsoft.storage/storageaccounts' in resource_type:
            storage_details = run_az_command_list([
                'az', 'storage', 'account', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if storage_details:
                config.update({
                    'sku': storage_details.get('sku'),
                    'accessTier': storage_details.get('accessTier'),
                    'encryption': storage_details.get('encryption'),
                    'networkRuleSet': storage_details.get('networkRuleSet')
                })
        
        # SQL Databases
        elif 'microsoft.sql/servers/databases' in resource_type:
            # Extract server name from resource ID
            resource_id_parts = resource.get('id', '').split('/')
            server_name = ''
            if len(resource_id_parts) > 8:
                server_name = resource_id_parts[8]
            
            if server_name:
                db_details = run_az_command_list([
                    'az', 'sql', 'db', 'show',
                    '--resource-group', resource_group,
                    '--server', server_name,
                    '--name', name
                ], subscription_id)
                if db_details:
                    config.update({
                        'edition': db_details.get('edition'),
                        'serviceLevelObjective': db_details.get('serviceLevelObjective'),
                        'maxSizeBytes': db_details.get('maxSizeBytes'),
                        'collation': db_details.get('collation')
                    })
            else:
                log_failure(f"Could not extract server name from resource ID for SQL Database {name}.")
        
        # Key Vaults
        elif 'microsoft.keyvault/vaults' in resource_type:
            kv_details = run_az_command_list([
                'az', 'keyvault', 'show',
                '--resource-group', resource_group,
                '--name', name
            ], subscription_id)
            if kv_details:
                properties_dict = kv_details.get('properties', {})
                access_policies = properties_dict.get('accessPolicies', [])
                if not isinstance(access_policies, list):
                    log_failure(f"Unexpected format for 'accessPolicies' in Key Vault {name}. Expected list, got {type(access_policies)}.")
                    access_policies = []
                config.update({
                    'sku': properties_dict.get('sku'),
                    'accessPolicies': access_policies,
                    'enabledForDeployment': properties_dict.get('enabledForDeployment'),
                    'enabledForTemplateDeployment': properties_dict.get('enabledForTemplateDeployment')
                })
                
    except Exception as e:
        log_failure(f"Error getting specific config for {name} ({resource_type}): {str(e)}")
        
    return config

def list_resources_basic(subscription_id: str) -> List[Dict[str, Any]]:
    """
    List all resources in the subscription with basic information.
    
    Args:
        subscription_id: The Azure subscription ID
        
    Returns:
        A list of basic resource objects
    """
    query = f"Resources | where subscriptionId == '{subscription_id}' | project id, name, type, resourceGroup, kind, location, tags, properties"
    try:
        result = run_az_command(f"az graph query -q \"{query}\" --subscription {subscription_id}")
        if result is None:
            log_failure(f"Failed to retrieve basic resources for subscription {subscription_id}.")
            return []
        if isinstance(result, dict):
            return result.get('data', [])
        log_failure(f"Unexpected format for basic resources: {result}")
        return []
    except Exception as e:
        log_failure(f"Error in list_resources_basic for subscription {subscription_id}: {e}")
        return []

def list_resources(subscription_id: str, basic_mode: bool = False) -> List[Dict[str, Any]]:
    """
    List all resources in the subscription with enhanced details.
    
    Args:
        subscription_id: The Azure subscription ID
        basic_mode: If True, only gather basic resource information
        
    Returns:
        A list of resource objects with detailed information
    """
    if basic_mode:
        logger.info("Using basic mode - gathering resource information without detailed enhancement...")
        return list_resources_basic(subscription_id)
    
    logger.info("Using enhanced mode - gathering detailed resource information...")
    logger.info("Fetching basic resource information...")
    query = f"Resources | where subscriptionId == '{subscription_id}' | project id, name, type, resourceGroup, kind, location, tags"
    
    basic_resources = []
    try:
        result = run_az_command(f"az graph query -q \"{query}\" --subscription {subscription_id}")
        if result is None:
            log_failure(f"Failed to retrieve basic resources for subscription {subscription_id}.")
        elif isinstance(result, dict):
            basic_resources = result.get('data', [])
        else:
            log_failure(f"Unexpected format for basic resources: {result}")
    except Exception as e:
        log_failure(f"Error fetching basic resource information for subscription {subscription_id}: {e}")

    enhanced_resources = []
    total_resources = len(basic_resources)
    
    logger.info(f"Enhancing resource details for {total_resources} resources...")
    for i, resource in enumerate(basic_resources, 1):
        resource_name = resource.get('name', 'Unknown')
        resource_id = resource.get('id')
        resource_type = resource.get('type')

        logger.info(f"Processing resource {i}/{total_resources}: {resource_name}")
        
        if not resource_id:
            log_failure(f"Resource {resource_name} missing 'id', skipping detailed enhancement.")
            enhanced_resources.append(resource)
            continue
        if not resource_type:
            log_failure(f"Resource {resource_name} ({resource_id}) missing 'type', skipping detailed enhancement.")
            enhanced_resources.append(resource)
            continue

        try:
            # Get enhanced resource details
            enhanced_resource = resource.copy()
            
            # Add network information
            network_info = get_network_information(resource, subscription_id)
            if network_info:
                enhanced_resource['networkInfo'] = network_info
                
            # Add environment variables
            env_vars = get_environment_variables(resource, subscription_id)
            if env_vars:
                enhanced_resource['environmentVariables'] = env_vars
                
            # Add resource-specific configurations
            specific_config = get_resource_specific_config(resource, subscription_id)
            if specific_config:
                enhanced_resource['specificConfiguration'] = specific_config
            
            # Get properties from Resource Graph for dependency analysis
            properties_query = f"Resources | where id == '{resource_id}' | project properties"
            try:
                properties_result = run_az_command(f"az graph query -q \"{properties_query}\" --subscription {subscription_id}")
                
                if properties_result is not None and isinstance(properties_result, dict) and properties_result.get('data'):
                    if properties_result['data'] and isinstance(properties_result['data'][0], dict):
                        enhanced_resource['properties'] = properties_result['data'][0].get('properties', {})
                    else:
                        log_failure(f"Properties query for {resource_id} returned unexpected data format: {properties_result}")
                elif properties_result is not None:
                    log_failure(f"Properties query for {resource_id} returned no data or unexpected type: {properties_result}")
                else:
                    log_failure(f"Failed to retrieve properties for {resource_id}.")
            except Exception as e:
                log_failure(f"Error retrieving properties for {resource_id}: {e}")
            
            enhanced_resources.append(enhanced_resource)
            
        except Exception as e:
            log_failure(f"Error enhancing resource {resource_name} ({resource_id}): {str(e)}")
            # Add basic resource info if enhancement fails
            enhanced_resources.append(resource)
    
    logger.info(f"Enhanced {len(enhanced_resources)} resources with detailed information")
    return enhanced_resources

def get_resource_dependencies(subscription_id: str, resources: List[Dict[str, Any]]) -> Tuple[Dict[str, Set[str]], Dict[str, Set[str]]]:
    """
    Identify dependencies between resources using enhanced resource information.
    
    Args:
        subscription_id: The Azure subscription ID
        resources: List of enhanced resources to analyze
        
    Returns:
        A tuple containing (confirmed_dependencies, potential_dependencies) dictionaries mapping resource IDs to sets of dependent resource IDs
    """
    confirmed_dependencies: Dict[str, Set[str]] = {}
    potential_dependencies: Dict[str, Set[str]] = {}
    
    # Initialize empty dependency sets for all resources
    for resource in resources:
        resource_id = resource.get('id')
        if resource_id:
            confirmed_dependencies[resource_id] = set()
            potential_dependencies[resource_id] = set()
        else:
            log_failure(f"Resource missing 'id', cannot initialize for dependency tracking: {resource.get('name', 'Unknown')}")
    
    logger.info("Analyzing resource dependencies with enhanced information...")
    
    # Check for different types of dependencies
    for resource in resources:
        resource_id = resource.get('id')
        resource_type = resource.get('type')
        
        if not resource_id:
            log_failure(f"Resource missing 'id', skipping dependency analysis for {resource.get('name', 'Unknown')}.")
            continue
        if not resource_type:
            log_failure(f"Resource {resource_id} missing 'type', skipping dependency analysis.")
            continue
        
        # Use enhanced properties if available, otherwise use basic properties
        properties = resource.get('properties', {})
        
        # Enhanced dependency detection using environment variables
        env_vars = resource.get('environmentVariables', {})
        
        # Enhanced dependency detection using network information
        network_info = resource.get('networkInfo', {})
        
        # Enhanced dependency detection using specific configurations
        specific_config = resource.get('specificConfiguration', {})
        
        # Look for resource IDs in properties, environment variables, and configurations
        all_resource_data = json.dumps({
            'properties': properties,
            'environmentVariables': env_vars,
            'specificConfiguration': specific_config,
            'networkInfo': network_info
        })
        
        for potential_dep in resources:
            potential_dep_id = potential_dep.get('id')
            if potential_dep_id and potential_dep_id != resource_id and potential_dep_id in all_resource_data:
                confirmed_dependencies[resource_id].add(potential_dep_id)
        
        # Enhanced dependency detection using environment variables (potential dependencies)
        if env_vars:
            # App Settings dependencies
            app_settings = env_vars.get('appSettings', {})
            for setting_name, setting_value in app_settings.items():
                if isinstance(setting_value, str):
                    # Look for resource names in connection strings, URLs, and other settings
                    for potential_dep in resources:
                        dep_name = potential_dep.get('name', '')
                        if dep_name and len(dep_name) > 3:  # Avoid matching very short names
                            # Direct name match
                            if dep_name in setting_value:
                                potential_dependencies[resource_id].add(potential_dep['id'])
                            # For URLs, also check if the resource name appears as a subdomain or hostname
                            elif dep_name.replace('-', '') in setting_value.replace('-', ''):
                                potential_dependencies[resource_id].add(potential_dep['id'])
            
            # Connection strings dependencies
            conn_strings = env_vars.get('connectionStrings', {})
            for conn_name, conn_value in conn_strings.items():
                if isinstance(conn_value, str):
                    # Look for server names or resource names in connection strings
                    for potential_dep in resources:
                        dep_name = potential_dep.get('name', '')
                        if dep_name and len(dep_name) > 3:  # Avoid matching very short names
                            # Direct name match
                            if dep_name in conn_value:
                                potential_dependencies[resource_id].add(potential_dep['id'])
                            # For URLs and connection strings, also check without hyphens
                            elif dep_name.replace('-', '') in conn_value.replace('-', ''):
                                potential_dependencies[resource_id].add(potential_dep['id'])
        
        # Enhanced dependency detection using network information (potential dependencies)
        if network_info:
            # Look for dependencies based on hostnames, endpoints, etc.
            for key, value in network_info.items():
                if isinstance(value, (str, list)):
                    value_str = json.dumps(value) if isinstance(value, list) else value
                    for potential_dep in resources:
                        dep_name = potential_dep.get('name', '')
                        if dep_name and dep_name in value_str:
                            potential_dependencies[resource_id].add(potential_dep['id'])
        
        # Type-specific dependency detection (confirmed dependencies from properties)
        if resource_type == 'microsoft.app/containerapps':
            # Container Apps depend on their environment and registry
            managed_environment_id = properties.get('managedEnvironmentId')
            if managed_environment_id:
                confirmed_dependencies[resource_id].add(managed_environment_id)
            
            # Container Apps secret references and registry dependencies
            config = properties.get('configuration')
            if isinstance(config, dict):
                # Registry dependencies
                registries = config.get('registries', [])
                if not isinstance(registries, list):
                    log_failure(f"Unexpected format for 'registries' in resource {resource_id}. Expected list, got {type(registries)}. Skipping registry dependencies.")
                    registries = [] # Ensure it's an empty list to prevent TypeError
                for registry in registries:
                    if isinstance(registry, dict):
                        server = registry.get('server', '')
                        # Find the ACR resource by matching the login server
                        for potential_acr in resources:
                            potential_acr_type = potential_acr.get('type')
                            if potential_acr_type == 'microsoft.containerregistry/registries':
                                try:
                                    acr_query = f"Resources | where id == '{potential_acr.get('id')}' | project properties.loginServer"
                                    acr_result = run_az_command(f"az graph query -q \"{acr_query}\" --subscription {subscription_id}")
                                    if acr_result is not None and isinstance(acr_result, dict) and acr_result.get('data'):
                                        if acr_result['data'] and isinstance(acr_result['data'][0], dict):
                                            if acr_result['data'][0].get('properties.loginServer') == server:
                                                confirmed_dependencies[resource_id].add(potential_acr['id'])
                                        else:
                                            log_failure(f"ACR query for {potential_acr.get('id')} returned unexpected data format: {acr_result}")
                                    elif acr_result is not None:
                                        log_failure(f"ACR query for {potential_acr.get('id')} returned no data or unexpected type: {acr_result}")
                                    else:
                                        log_failure(f"Failed to retrieve ACR login server for {potential_acr.get('id')}.")
                                except Exception as e:
                                    log_failure(f"Error retrieving ACR login server for {potential_acr.get('id')}: {e}")
                
                # Secret references that might point to Key Vault or other services
                secrets = config.get('secrets', [])
                if not isinstance(secrets, list):
                    log_failure(f"Unexpected format for 'secrets' in resource {resource_id}. Expected list, got {type(secrets)}. Skipping secret dependencies.")
                    secrets = []
                for secret in secrets:
                    if isinstance(secret, dict):
                        secret_name = secret.get('name', '')
                        # Common patterns for secret names that indicate dependencies
                        if 'keyvault' in secret_name.lower() or 'kv' in secret_name.lower():
                            for potential_kv in resources:
                                if potential_kv.get('type') == 'microsoft.keyvault/vaults':
                                    potential_dependencies[resource_id].add(potential_kv['id'])
                        elif 'storage' in secret_name.lower():
                            for potential_storage in resources:
                                if potential_storage.get('type') == 'microsoft.storage/storageaccounts':
                                    potential_dependencies[resource_id].add(potential_storage['id'])
                        elif 'database' in secret_name.lower() or 'db' in secret_name.lower():
                            for potential_db in resources:
                                potential_db_type = potential_db.get('type')
                                if potential_db_type in ['microsoft.sql/servers', 'microsoft.documentdb/databaseaccounts', 'microsoft.dbforpostgresql/flexibleservers']:
                                    potential_dependencies[resource_id].add(potential_db['id'])
            
            # Environment variable secret references
            template = properties.get('template')
            if isinstance(template, dict):
                containers = template.get('containers', [])
                if not isinstance(containers, list):
                    log_failure(f"Unexpected format for 'containers' in resource {resource_id} template. Expected list, got {type(containers)}. Skipping container env dependencies.")
                    containers = []
                for container in containers:
                    if isinstance(container, dict) and 'env' in container:
                        env_list = container.get('env', [])
                        if not isinstance(env_list, list):
                            log_failure(f"Unexpected format for 'env' in container of resource {resource_id}. Expected list, got {type(env_list)}. Skipping env var dependencies.")
                            env_list = []
                        for env_var in env_list:
                            if isinstance(env_var, dict) and 'secretRef' in env_var:
                                secret_ref = env_var['secretRef']
                                # Analyze secret reference patterns
                                if 'appinsights' in secret_ref.lower():
                                    for potential_insights in resources:
                                        if potential_insights.get('type') == 'microsoft.insights/components':
                                            potential_dependencies[resource_id].add(potential_insights['id'])
                                elif 'webpubsub' in secret_ref.lower() or 'signalr' in secret_ref.lower():
                                    for potential_signalr in resources:
                                        potential_signalr_type = potential_signalr.get('type')
                                        if potential_signalr_type in ['microsoft.signalrservice/signalr', 'microsoft.signalrservice/webpubsub']:
                                            potential_dependencies[resource_id].add(potential_signalr['id'])
        
        elif resource_type == 'microsoft.web/sites':
            # Web Apps often depend on App Service Plans (confirmed dependency)
            server_farm_id = properties.get('serverFarmId')
            if server_farm_id:
                confirmed_dependencies[resource_id].add(server_farm_id)
            
            # Enhanced App Insights detection using environment variables (potential dependencies)
            if env_vars:
                app_settings = env_vars.get('appSettings', {})
                # Look for Application Insights connection strings
                for setting_name, setting_value in app_settings.items():
                    if isinstance(setting_value, str) and 'APPLICATIONINSIGHTS' in setting_name.upper():
                        for potential_insights in resources:
                            if potential_insights.get('type') == 'microsoft.insights/components':
                                if potential_insights.get('name') and potential_insights['name'] in setting_value:
                                    potential_dependencies[resource_id].add(potential_insights['id'])
                
                # Look for database connection strings
                conn_strings = env_vars.get('connectionStrings', {})
                for conn_name, conn_value in conn_strings.items():
                    if isinstance(conn_value, str):
                        # SQL Database dependencies
                        if 'database.windows.net' in conn_value or 'sql.azuresynapse.net' in conn_value:
                            for potential_sql in resources:
                                potential_sql_type = potential_sql.get('type')
                                if potential_sql_type in ['microsoft.sql/servers', 'microsoft.sql/servers/databases']:
                                    if potential_sql.get('name') and potential_sql['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_sql['id'])
                        
                        # Storage Account dependencies
                        if 'blob.core.windows.net' in conn_value or 'table.core.windows.net' in conn_value or 'queue.core.windows.net' in conn_value or 'file.core.windows.net' in conn_value:
                            for potential_storage in resources:
                                if potential_storage.get('type') == 'microsoft.storage/storageaccounts':
                                    if potential_storage.get('name') and potential_storage['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_storage['id'])
                        
                        # Cosmos DB dependencies (MongoDB, SQL API, etc.)
                        if 'cosmos.azure.com' in conn_value or 'documents.azure.com' in conn_value:
                            for potential_cosmos in resources:
                                if potential_cosmos.get('type') == 'microsoft.documentdb/databaseaccounts':
                                    if potential_cosmos.get('name') and potential_cosmos['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_cosmos['id'])
                        
                        # PostgreSQL dependencies
                        if 'postgres.database.azure.com' in conn_value:
                            for potential_pg in resources:
                                potential_pg_type = potential_pg.get('type')
                                if potential_pg_type in ['microsoft.dbforpostgresql/servers', 'microsoft.dbforpostgresql/flexibleservers']:
                                    if potential_pg.get('name') and potential_pg['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_pg['id'])
                        
                        # MySQL dependencies
                        if 'mysql.database.azure.com' in conn_value:
                            for potential_mysql in resources:
                                potential_mysql_type = potential_mysql.get('type')
                                if potential_mysql_type in ['microsoft.dbformysql/servers', 'microsoft.dbformysql/flexibleservers']:
                                    if potential_mysql.get('name') and potential_mysql['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_mysql['id'])
                        
                        # Service Bus dependencies
                        if 'servicebus.windows.net' in conn_value:
                            for potential_sb in resources:
                                if potential_sb.get('type') == 'microsoft.servicebus/namespaces':
                                    if potential_sb.get('name') and potential_sb['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_sb['id'])
                        
                        # Event Hub dependencies
                        if 'servicebus.windows.net' in conn_value and 'EntityPath=' in conn_value:
                            for potential_eh in resources:
                                if potential_eh.get('type') == 'microsoft.eventhub/namespaces':
                                    if potential_eh.get('name') and potential_eh['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_eh['id'])
                        
                        # Redis Cache dependencies
                        if 'redis.cache.windows.net' in conn_value:
                            for potential_redis in resources:
                                if potential_redis.get('type') == 'microsoft.cache/redis':
                                    if potential_redis.get('name') and potential_redis['name'] in conn_value:
                                        potential_dependencies[resource_id].add(potential_redis['id'])
            
            # Enhanced detection for Key Vault secret references
            if env_vars:
                app_settings = env_vars.get('appSettings', {})
                for setting_name, setting_value in app_settings.items():
                    if isinstance(setting_value, str):
                        # Key Vault secret references (format: @Microsoft.KeyVault(SecretUri=...))
                        if '@Microsoft.KeyVault' in setting_value or 'vault.azure.net' in setting_value:
                            for potential_kv in resources:
                                if potential_kv.get('type') == 'microsoft.keyvault/vaults':
                                    if potential_kv.get('name') and potential_kv['name'] in setting_value:
                                        potential_dependencies[resource_id].add(potential_kv['id'])
                        
                        # Service Bus connection strings in app settings
                        if 'servicebus.windows.net' in setting_value:
                            for potential_sb in resources:
                                if potential_sb.get('type') == 'microsoft.servicebus/namespaces':
                                    if potential_sb.get('name') and potential_sb['name'] in setting_value:
                                        potential_dependencies[resource_id].add(potential_sb['id'])
                        
                        # SignalR/Web PubSub connection strings
                        if 'webpubsub.azure.com' in setting_value or 'service.signalr.net' in setting_value:
                            for potential_signalr in resources:
                                potential_signalr_type = potential_signalr.get('type')
                                if potential_signalr_type in ['microsoft.signalrservice/signalr', 'microsoft.signalrservice/webpubsub']:
                                    if potential_signalr.get('name') and potential_signalr['name'] in setting_value:
                                        potential_dependencies[resource_id].add(potential_signalr['id'])
            
            # Check for App Insights connection in properties (confirmed dependency)
            if properties and 'siteConfig' in properties and properties.get('siteConfig') is not None:
                site_config = properties.get('siteConfig', {})
                app_settings = site_config.get('appSettings', []) # Ensure default is list
                if app_settings and isinstance(app_settings, list):
                    for setting in app_settings:
                        if isinstance(setting, dict) and setting.get('name') == 'APPLICATIONINSIGHTS_CONNECTION_STRING' and 'value' in setting:
                            conn_string = setting['value']
                            for potential_insights in resources:
                                if potential_insights.get('type') == 'microsoft.insights/components' and potential_insights.get('name') and potential_insights['name'] in conn_string:
                                    confirmed_dependencies[resource_id].add(potential_insights['id'])
        
        elif resource_type == 'microsoft.insights/components':
            # Application Insights may depend on storage accounts for logs (potential dependency)
            if specific_config:
                for potential_storage in resources:
                    if potential_storage.get('type') == 'microsoft.storage/storageaccounts':
                        # Check if storage account is referenced in App Insights config
                        if potential_storage.get('name') and potential_storage['name'] in json.dumps(specific_config):
                            potential_dependencies[resource_id].add(potential_storage['id'])
        
        elif resource_type == 'microsoft.apimanagement/service':
            # APIM often connected to App Insights (potential dependency)
            for potential_insights in resources:
                if potential_insights.get('type') == 'microsoft.insights/components':
                    potential_dependencies[resource_id].add(potential_insights['id'])
            
            # Enhanced APIM dependency detection using configuration (potential dependencies)
            if specific_config:
                # Look for backend services, named values, etc.
                config_str = json.dumps(specific_config)
                for potential_dep in resources:
                    potential_dep_type = potential_dep.get('type')
                    if potential_dep_type in ['microsoft.web/sites', 'microsoft.storage/storageaccounts', 'microsoft.keyvault/vaults']:
                        if potential_dep.get('name') and potential_dep['name'] in config_str:
                            potential_dependencies[resource_id].add(potential_dep['id'])
        
        elif resource_type == 'microsoft.keyvault/vaults':
            # Key Vault may be referenced by other services
            # This is typically a reverse dependency, but we can detect some patterns
            if specific_config:
                access_policies = specific_config.get('accessPolicies', [])
                if not isinstance(access_policies, list):
                    log_failure(f"Unexpected format for 'accessPolicies' in Key Vault {resource_id}. Expected list, got {type(access_policies)}.")
                    access_policies = []
                for policy in access_policies:
                    if isinstance(policy, dict) and 'objectId' in policy:
                        # Could potentially match this to service principals of other resources
                        pass
        
        elif resource_type == 'microsoft.compute/virtualmachines':
            # VMs depend on various resources (potential dependencies from config)
            if specific_config:
                # Check for dependencies on storage accounts (for diagnostics, disks)
                config_str = json.dumps(specific_config)
                for potential_storage in resources:
                    if potential_storage.get('type') == 'microsoft.storage/storageaccounts':
                        if potential_storage.get('name') and potential_storage['name'] in config_str:
                            potential_dependencies[resource_id].add(potential_storage['id'])
            
            # VMs depend on their network interfaces (confirmed dependency)
            if properties and 'networkProfile' in properties:
                network_interfaces = properties.get('networkProfile', {}).get('networkInterfaces', [])
                if not isinstance(network_interfaces, list):
                    log_failure(f"Unexpected format for 'networkInterfaces' in VM {resource_id}. Expected list, got {type(network_interfaces)}.")
                    network_interfaces = []
                for nic in network_interfaces:
                    if isinstance(nic, dict) and 'id' in nic:
                        confirmed_dependencies[resource_id].add(nic['id'])
        
        elif resource_type == 'microsoft.storage/storageaccounts':
            # Storage accounts may have network restrictions pointing to VNets (confirmed dependency)
            if specific_config and 'networkRuleSet' in specific_config:
                network_rules = specific_config.get('networkRuleSet', {})
                virtual_network_rules = network_rules.get('virtualNetworkRules', [])
                if not isinstance(virtual_network_rules, list):
                    log_failure(f"Unexpected format for 'virtualNetworkRules' in Storage Account {resource_id}. Expected list, got {type(virtual_network_rules)}.")
                    virtual_network_rules = []
                for vnet_rule in virtual_network_rules:
                    if isinstance(vnet_rule, dict) and 'id' in vnet_rule:
                        # This points to a subnet, we need to find the parent VNet
                        subnet_id = vnet_rule['id']
                        for potential_vnet in resources:
                            if potential_vnet.get('type') == 'microsoft.network/virtualnetworks':
                                if potential_vnet.get('id') and potential_vnet['id'] in subnet_id:
                                    confirmed_dependencies[resource_id].add(potential_vnet['id'])
    
    # Add common implicit dependencies based on resource types (potential dependencies)
    for resource in resources:
        resource_id = resource.get('id')
        resource_type = resource.get('type')

        if not resource_id:
            continue
        
        # Add implicit dependency for dashboard -> App Insights
        if resource_type == 'microsoft.portal/dashboards':
            for potential_dep in resources:
                if potential_dep.get('type') == 'microsoft.insights/components':
                    potential_dependencies[resource_id].add(potential_dep['id'])
        
        # Container App Environment -> App Insights
        if resource_type == 'microsoft.app/managedenvironments':
            for potential_dep in resources:
                if potential_dep.get('type') == 'microsoft.insights/components':
                    potential_dependencies[resource_id].add(potential_dep['id'])
    
    return confirmed_dependencies, potential_dependencies

def get_resource_data(subscription_id: Optional[str] = None, basic_mode: bool = False) -> Tuple[str, List[Dict[str, Any]], List[Dict[str, Any]], Dict[str, Set[str]], Dict[str, Set[str]]]:
    """
    Collect all Azure resource data needed for visualization.
    
    Args:
        subscription_id: The Azure subscription ID (if None, uses current subscription)
        basic_mode: If True, only gather basic resource information
        
    Returns:
        A tuple containing (subscription_id, resources, resource_groups, confirmed_dependencies, potential_dependencies)
    """
    # Check prerequisites
    if not check_az_cli_installed():
        logger.info("Error: Azure CLI not found. Please install it first: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli")
        return "", [], [], {}, {}
    
    if not check_az_cli_logged_in():
        logger.info("Error: Not logged in to Azure. Please run 'az login' first.")
        return "", [], [], {}, {} 
    
    # Get subscription ID
    if not subscription_id:
        subscription_id = get_subscription_id()
        if not subscription_id:
            logger.info("Error: Could not determine Azure subscription ID. Exiting.")
            return "", [], [], {}, {}

    truncated_sub_id = truncate_subscription_id(subscription_id)
    logger.info(f"Using subscription: {truncated_sub_id}")

    resource_groups: List[Dict[str, Any]] = []
    resources: List[Dict[str, Any]] = []
    confirmed_dependencies: Dict[str, Set[str]] = {}
    potential_dependencies: Dict[str, Set[str]] = {}

    # Enable resource graph related extensions
    logger.info("Ensuring Azure Resource Graph extension is installed...")
    run_az_command("az config set extension.use_dynamic_install=yes_without_prompt")
    run_az_command("az extension add --name resource-graph --yes")

    # Get resources and resource groups
    logger.info("Fetching resource groups...")
    resource_groups = list_resource_groups(subscription_id)
    logger.info(f"Found {len(resource_groups)} resource groups")
    
    # Get resources (basic or enhanced mode)
    resources = list_resources(subscription_id, basic_mode)
    logger.info(f"Found {len(resources)} resources {'(basic mode)' if basic_mode else '(enhanced mode)'}")
    
    # Analyze dependencies using enhanced resource data
    confirmed_dependencies, potential_dependencies = get_resource_dependencies(subscription_id, resources)
    
    # logger.info summary of enhanced data collected
    enhanced_count = sum(1 for r in resources if any(key in r for key in ['networkInfo', 'environmentVariables', 'specificConfiguration']))
    logger.info(f"Enhanced {enhanced_count}/{len(resources)} resources with detailed information")
    
    # logger.info dependency summary
    total_confirmed_deps = sum(len(deps) for deps in confirmed_dependencies.values())
    total_potential_deps = sum(len(deps) for deps in potential_dependencies.values())
    logger.info(f"Discovered {total_confirmed_deps} confirmed dependencies and {total_potential_deps} potential dependencies")
    
    return subscription_id, resources, resource_groups, confirmed_dependencies, potential_dependencies
