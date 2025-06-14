"""
ARG Library for Robot Framework
This library provides functionality to create an Azure Resource Graph (ARG) by querying Azure resources and their dependencies.
# It supports both basic and enhanced modes for resource analysis.
# It can output the resource graph data to a JSON file and includes options for confirmed and potential dependencies.
#
Usage:
```
*** Settings ***
Library    ARG
*** Keywords ***
Create Azure Resource Graph
    Create Azure Resource Graph    subscription=your_subscription_id    no_potential_deps=True/False    output=your_output_file    basic_mode=True/False
```

Scope: Global
"""

import json, logging
from robot.libraries.BuiltIn import BuiltIn
from typing import Optional, List, Dict, Any, Set
from .azure_resource_graph_helper import get_resource_data, log_failure, _failed_operations_log

logger = logging.getLogger(__name__)

ROBOT_LIBRARY_SCOPE = "GLOBAL"

def create_azure_resource_graph(
    subscription: Optional[str] = None,
    no_potential_deps: bool = False,
    output: str = 'azure_resource_graph',
    basic_mode: bool = False
):
    # Determine whether to collect data or use existing file
    data_file = f"{output}.json"
    
    subscription_id: Optional[str] = subscription
    resources: List[Dict[str, Any]] = []
    resource_groups: List[Dict[str, Any]] = []
    confirmed_dependencies: Dict[str, Set[str]] = {}
    potential_dependencies: Dict[str, Set[str]] = {}
    
    # Query Azure for resource data
    subscription_id, resources, resource_groups, confirmed_dependencies, potential_dependencies = get_resource_data(subscription_id, basic_mode)
    
    # Save data to file
    deps_serializable = {k: list(v) for k, v in confirmed_dependencies.items()}
    total_confirmed_deps = sum(len(deps) for deps in confirmed_dependencies.values())
    total_potential_deps = sum(len(deps) for deps in potential_dependencies.values())
    data = {
        'subscription_id': subscription_id,
        'resources': resources,
        'resource_groups': resource_groups,
        'confirmed_dependencies': deps_serializable,
        'potential_dependencies': {k: list(v) for k, v in potential_dependencies.items()},
        'metadata': {
            'enhanced_mode': not basic_mode,
            'total_resources': len(resources),
            'total_confirmed_dependencies': total_confirmed_deps,
            'total_potential_dependencies': total_potential_deps,
            'enhanced_resources': sum(1 for r in resources if any(key in r for key in ['networkInfo', 'environmentVariables', 'specificConfiguration'])) if not basic_mode else 0
        }
    }
    try:
        with open(data_file, 'w') as f:
            json.dump(data, f, indent=2)
        logger.info(f"Resource data saved to {data_file}")
        if not basic_mode:
            logger.info(f"Enhanced data includes network info, environment variables, and detailed configurations")
    except IOError as e:
        log_failure(f"Error saving data to file {data_file}: {e}")


    include_potential_deps = not no_potential_deps
    
    # logger.info final summary
    mode_msg = "basic mode (faster, less comprehensive)" if basic_mode else "enhanced mode (comprehensive resource analysis)"
    logger.info(f"\n✅ Resource graph generation completed using {mode_msg}")

    if include_potential_deps:
        logger.info("Included both confirmed and potential dependencies.")
    else:
        logger.info("Included only confirmed dependencies. Potential dependencies were excluded.")
    
    if not basic_mode:
        logger.info("Enhanced features included:")
        logger.info("  - Network information (IPs, hostnames, endpoints)")
        logger.info("  - Environment variables and configuration settings")
        logger.info("  - Resource-specific detailed configurations")
        logger.info("  - Advanced dependency detection using configuration data")
    else:
        logger.info("To get more detailed resource information and better dependency detection, run without --basic-mode")

    if _failed_operations_log:
        logger.info("\n--- Summary of Failed Operations (Non-Fatal) ---")
        for msg in _failed_operations_log:
            logger.info(f"- {msg}")
        logger.info("-------------------------------------------------")

    return {
        'subscription_id': subscription_id,
        'resources': resources,
        'resource_groups': resource_groups,
        'confirmed_dependencies': confirmed_dependencies,
        'potential_dependencies': potential_dependencies,
        'data_file': data_file
    }