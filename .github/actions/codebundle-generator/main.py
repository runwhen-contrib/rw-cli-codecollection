#!/usr/bin/env python3
"""
Codebundle Generator - Auto-generate codebundles from GitHub issues
"""

import os
import re
import json
import yaml
import logging
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from github import Github
from jinja2 import Template

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class CodebundleGenerator:
    def __init__(self, issue_number: int, github_token: str, openai_api_key: Optional[str] = None):
        self.gh = Github(github_token)
        self.repo = self.gh.get_repo(os.environ['GITHUB_REPOSITORY'])
        self.issue = self.repo.get_issue(issue_number)
        self.openai_api_key = openai_api_key
        # Set workspace - find the repository root
        current_dir = Path.cwd()
        # If we're in the action directory, go up to find the repo root
        if '.github/actions' in str(current_dir):
            # Go up from .github/actions/codebundle-generator to repo root
            self.workspace_root = current_dir.parent.parent.parent
        else:
            # We're already in the repo root or GitHub Actions workspace
            self.workspace_root = current_dir
        
        logger.info(f"Initialized generator for issue #{issue_number}")
        logger.info(f"Current directory: {current_dir}")
        logger.info(f"Workspace root: {self.workspace_root}")
        logger.info(f"Codebundles directory: {self.workspace_root / 'codebundles'}")
        logger.info(f"Codebundles exists: {(self.workspace_root / 'codebundles').exists()}")
        
    def parse_issue_requirements(self) -> Dict:
        """Parse GitHub issue to extract codebundle requirements"""
        logger.info("Parsing issue requirements...")
        
        title = self.issue.title.lower()
        body = self.issue.body or ""
        
        # Extract platform
        platform = self._extract_platform(title, body)
        
        # Extract service and purpose from title and body
        service_type, purpose = self._extract_service_and_purpose(title, body)
        
        # Extract tasks from body
        tasks = self._extract_tasks(body)
        
        # Generate codebundle name
        codebundle_name = f"{platform}-{service_type}-{purpose}"
        
        requirements = {
            'platform': platform,
            'service_type': service_type,
            'purpose': purpose,
            'codebundle_name': codebundle_name,
            'tasks': tasks,
            'title': self.issue.title,
            'body': body,
            'issue_number': self.issue.number
        }
        
        logger.info(f"Extracted requirements: {requirements}")
        return requirements
    
    def _extract_platform(self, title: str, body: str) -> str:
        """Extract platform from issue content"""
        text = (title + " " + body).lower()
        
        if any(keyword in text for keyword in ['azure', 'az ', 'aks', 'acr', 'nsg']):
            return 'azure'
        elif any(keyword in text for keyword in ['aws', 'eks', 'ec2', 's3', 'lambda']):
            return 'aws'
        elif any(keyword in text for keyword in ['gcp', 'gke', 'gcs', 'google cloud']):
            return 'gcp'
        elif any(keyword in text for keyword in ['kubernetes', 'k8s', 'kubectl', 'pod']):
            return 'k8s'
        else:
            return 'generic'
    
    def _extract_service_and_purpose(self, title: str, body: str) -> Tuple[str, str]:
        """Extract service type and purpose from issue content"""
        text = (title + " " + body).lower()
        
        # Service type mapping
        if any(keyword in text for keyword in ['firewall', 'nsg', 'network security', 'security group']):
            service_type = 'network-security'
        elif any(keyword in text for keyword in ['network', 'subnet', 'vnet', 'vpc']):
            service_type = 'network'
        elif any(keyword in text for keyword in ['storage', 'disk', 'volume']):
            service_type = 'storage'
        elif any(keyword in text for keyword in ['database', 'db', 'sql']):
            service_type = 'database'
        elif any(keyword in text for keyword in ['compute', 'vm', 'instance']):
            service_type = 'compute'
        else:
            service_type = 'general'
        
        # Purpose mapping
        if any(keyword in text for keyword in ['integrity', 'audit', 'compliance']):
            purpose = 'integrity'
        elif any(keyword in text for keyword in ['health', 'monitoring', 'check']):
            purpose = 'health'
        elif any(keyword in text for keyword in ['triage', 'troubleshoot', 'debug']):
            purpose = 'triage'
        elif any(keyword in text for keyword in ['ops', 'operations', 'management']):
            purpose = 'ops'
        else:
            purpose = 'check'
        
        return service_type, purpose
    
    def _extract_tasks(self, body: str) -> List[str]:
        """Extract specific tasks from issue body"""
        tasks = []
        
        # Look for task lists or bullet points
        task_patterns = [
            r'[-*]\s+(.+?)(?:\n|$)',  # Bullet points
            r'\d+\.\s+(.+?)(?:\n|$)',  # Numbered lists
        ]
        
        for pattern in task_patterns:
            matches = re.findall(pattern, body, re.MULTILINE | re.IGNORECASE)
            tasks.extend([match.strip() for match in matches if len(match.strip()) > 10])
        
        # If no structured tasks found, extract from key phrases
        if not tasks:
            # Look for common task indicators
            task_indicators = [
                r'detect\s+(.+?)(?:\.|;|\n)',
                r'compare\s+(.+?)(?:\.|;|\n)', 
                r'validate\s+(.+?)(?:\.|;|\n)',
                r'check\s+(.+?)(?:\.|;|\n)',
                r'monitor\s+(.+?)(?:\.|;|\n)',
                r'audit\s+(.+?)(?:\.|;|\n)'
            ]
            
            for pattern in task_indicators:
                matches = re.findall(pattern, body, re.IGNORECASE)
                tasks.extend([f"Check {match.strip()}" for match in matches])
        
        # Default tasks if none found
        if not tasks:
            tasks = [
                "Check resource configuration",
                "Validate security settings", 
                "Monitor resource health"
            ]
        
        return tasks[:5]  # Limit to 5 tasks max
    
    def find_similar_codebundles(self, requirements: Dict) -> List[str]:
        """Find existing codebundles to use as templates"""
        logger.info("Finding similar codebundles...")
        
        platform = requirements['platform']
        service_type = requirements['service_type']
        
        codebundles_dir = self.workspace_root / 'codebundles'
        similar_bundles = []
        
        if not codebundles_dir.exists():
            logger.warning("Codebundles directory not found")
            return []
        
        # Find codebundles with same platform
        for cb_dir in codebundles_dir.iterdir():
            if cb_dir.is_dir() and not cb_dir.name.startswith('.'):
                cb_name = cb_dir.name
                
                # Prioritize same platform
                if cb_name.startswith(platform):
                    similar_bundles.append(cb_name)
        
        # Sort by relevance (same service type gets priority)
        def relevance_score(cb_name):
            score = 0
            if service_type.replace('-', '') in cb_name:
                score += 10
            if any(word in cb_name for word in service_type.split('-')):
                score += 5
            return score
        
        similar_bundles.sort(key=relevance_score, reverse=True)
        
        logger.info(f"Found {len(similar_bundles)} similar codebundles: {similar_bundles[:3]}")
        return similar_bundles[:3]  # Return top 3
    
    def read_template_files(self, template_bundles: List[str]) -> Dict:
        """Read template files from existing codebundles"""
        logger.info("Reading template files...")
        
        templates = {
            'scripts': [],
            'robot_tasks': [],
            'meta_examples': [],
            'readme_examples': []
        }
        
        codebundles_dir = self.workspace_root / 'codebundles'
        
        for bundle_name in template_bundles:
            bundle_dir = codebundles_dir / bundle_name
            if not bundle_dir.exists():
                continue
                
            # Read bash scripts
            for script_file in bundle_dir.glob('*.sh'):
                try:
                    with open(script_file, 'r') as f:
                        content = f.read()
                        templates['scripts'].append({
                            'name': script_file.name,
                            'content': content[:2000],  # Limit content size
                            'bundle': bundle_name
                        })
                except Exception as e:
                    logger.warning(f"Could not read {script_file}: {e}")
            
            # Read robot files
            for robot_file in bundle_dir.glob('*.robot'):
                try:
                    with open(robot_file, 'r') as f:
                        content = f.read()
                        templates['robot_tasks'].append({
                            'name': robot_file.name,
                            'content': content[:2000],  # Limit content size
                            'bundle': bundle_name
                        })
                except Exception as e:
                    logger.warning(f"Could not read {robot_file}: {e}")
            
            # Read meta.yaml
            meta_file = bundle_dir / 'meta.yaml'
            if meta_file.exists():
                try:
                    with open(meta_file, 'r') as f:
                        content = f.read()
                        templates['meta_examples'].append({
                            'bundle': bundle_name,
                            'content': content[:1000]
                        })
                except Exception as e:
                    logger.warning(f"Could not read {meta_file}: {e}")
        
        logger.info(f"Read {len(templates['scripts'])} scripts, {len(templates['robot_tasks'])} robot files")
        return templates
    
    def generate_codebundle(self, requirements: Dict, templates: Dict) -> bool:
        """Generate the complete codebundle"""
        logger.info(f"Generating codebundle: {requirements['codebundle_name']}")
        
        codebundle_dir = self.workspace_root / 'codebundles' / requirements['codebundle_name']
        codebundle_dir.mkdir(parents=True, exist_ok=True)
        
        try:
            # Generate components
            scripts = self.generate_scripts(requirements, templates)
            robot_content = self.generate_robot_tasks(requirements, templates)
            meta_content = self.generate_meta_yaml(requirements, scripts)
            readme_content = self.generate_readme(requirements)
            cursorrules_content = self.generate_cursorrules(requirements)
            
            # Write files
            self._write_scripts(codebundle_dir, scripts)
            self._write_robot_file(codebundle_dir, robot_content)
            self._write_meta_yaml(codebundle_dir, meta_content)
            self._write_readme(codebundle_dir, readme_content)
            self._write_cursorrules(codebundle_dir, cursorrules_content)
            
            # Set outputs for GitHub Action
            self._set_github_outputs(requirements, scripts, robot_content)
            
            logger.info("Codebundle generation completed successfully")
            return True
            
        except Exception as e:
            logger.error(f"Failed to generate codebundle: {e}")
            return False
    
    def generate_scripts(self, requirements: Dict, templates: Dict) -> Dict[str, str]:
        """Generate bash scripts for each task"""
        logger.info("Generating bash scripts...")
        
        scripts = {}
        platform = requirements['platform']
        
        # Template for script generation
        script_template = self._get_script_template(platform, templates)
        
        for i, task in enumerate(requirements['tasks']):
            script_name = self._task_to_script_name(task)
            
            # Generate script content based on template and task
            script_content = self._generate_script_content(task, platform, script_template)
            scripts[script_name] = script_content
        
        logger.info(f"Generated {len(scripts)} scripts")
        return scripts
    
    def _get_script_template(self, platform: str, templates: Dict) -> str:
        """Get appropriate script template based on platform"""
        
        # Find a good template script
        template_script = None
        for script in templates['scripts']:
            if platform in script['bundle']:
                template_script = script['content']
                break
        
        if not template_script and templates['scripts']:
            template_script = templates['scripts'][0]['content']
        
        return template_script or self._get_default_script_template(platform)
    
    def _get_default_script_template(self, platform: str) -> str:
        """Get default script template for platform"""
        
        if platform == 'azure':
            return '''#!/bin/bash

# Check if AZURE_RESOURCE_SUBSCRIPTION_ID is set, otherwise get the current subscription ID
if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Initialize issues JSON
issues_json='{"issues": []}'

# TODO: Add specific task logic here

# Output results
echo "$issues_json" > "$OUTPUT_DIR/results.json"
cat "$OUTPUT_DIR/results.json"
'''
        
        elif platform == 'k8s':
            return '''#!/bin/bash

# Validate required environment variables
if [ -z "$CONTEXT" ] || [ -z "$NAMESPACE" ]; then
    echo "Please set CONTEXT and NAMESPACE environment variables."
    exit 1
fi

# Set kubectl context
kubectl config use-context "$CONTEXT" || { echo "Failed to set context."; exit 1; }

# Initialize issues JSON
issues_json='{"issues": []}'

# TODO: Add specific task logic here

# Output results
echo "$issues_json" > "$OUTPUT_DIR/results.json"
cat "$OUTPUT_DIR/results.json"
'''
        
        else:
            return '''#!/bin/bash

# Generic script template
# Initialize issues JSON
issues_json='{"issues": []}'

# TODO: Add specific task logic here

# Output results
echo "$issues_json" > "$OUTPUT_DIR/results.json"
cat "$OUTPUT_DIR/results.json"
'''
    
    def _task_to_script_name(self, task: str) -> str:
        """Convert task description to script filename"""
        # Clean and convert to snake_case
        name = re.sub(r'[^\w\s-]', '', task.lower())
        name = re.sub(r'[-\s]+', '_', name)
        return f"{name}.sh"
    
    def _generate_script_content(self, task: str, platform: str, template: str) -> str:
        """Generate script content for a specific task"""
        
        # Replace TODO comment with task-specific logic
        task_logic = self._generate_task_logic(task, platform)
        
        if template and "# TODO: Add specific task logic here" in template:
            return template.replace("# TODO: Add specific task logic here", task_logic)
        else:
            return self._get_default_script_template(platform).replace(
                "# TODO: Add specific task logic here", task_logic
            )
    
    def _generate_task_logic(self, task: str, platform: str) -> str:
        """Generate platform-specific logic for a task"""
        
        task_lower = task.lower()
        
        if platform == 'azure':
            if 'nsg' in task_lower or 'network security' in task_lower:
                return '''
# Check Network Security Groups
echo "Checking NSG configuration..."
NSG_LIST=$(az network nsg list --resource-group "$AZ_RESOURCE_GROUP" -o json)

if [ -z "$NSG_LIST" ] || [ "$NSG_LIST" = "[]" ]; then
    issues_json=$(echo "$issues_json" | jq \\
        --arg title "No NSG Found" \\
        --arg details "No Network Security Groups found in resource group $AZ_RESOURCE_GROUP" \\
        --arg severity "2" \\
        '.issues += [{"title": $title, "details": $details, "severity": ($severity | tonumber)}]')
else
    echo "Found NSGs: $(echo "$NSG_LIST" | jq -r '.[].name' | tr '\\n' ' ')"
fi
'''
            
            elif 'firewall' in task_lower:
                return '''
# Check Azure Firewall
echo "Checking Azure Firewall configuration..."
FIREWALL_LIST=$(az network firewall list --resource-group "$AZ_RESOURCE_GROUP" -o json)

if [ -z "$FIREWALL_LIST" ] || [ "$FIREWALL_LIST" = "[]" ]; then
    issues_json=$(echo "$issues_json" | jq \\
        --arg title "No Azure Firewall Found" \\
        --arg details "No Azure Firewall found in resource group $AZ_RESOURCE_GROUP" \\
        --arg severity "3" \\
        '.issues += [{"title": $title, "details": $details, "severity": ($severity | tonumber)}]')
else
    echo "Found Firewalls: $(echo "$FIREWALL_LIST" | jq -r '.[].name' | tr '\\n' ' ')"
fi
'''
            
            else:
                return f'''
# Task: {task}
echo "Executing task: {task}"

# Add your specific Azure CLI commands here
# Example: az resource list --resource-group "$AZ_RESOURCE_GROUP"

echo "Task completed: {task}"
'''
        
        elif platform == 'k8s':
            return f'''
# Task: {task}
echo "Executing Kubernetes task: {task}"

# Add your specific kubectl commands here
# Example: kubectl get pods -n "$NAMESPACE"

echo "Task completed: {task}"
'''
        
        else:
            return f'''
# Task: {task}
echo "Executing task: {task}"

# Add your specific commands here

echo "Task completed: {task}"
'''
    
    def generate_robot_tasks(self, requirements: Dict, templates: Dict) -> str:
        """Generate Robot Framework tasks"""
        logger.info("Generating Robot Framework tasks...")
        
        platform = requirements['platform']
        codebundle_name = requirements['codebundle_name']
        tasks = requirements['tasks']
        
        # Get robot template
        robot_template = self._get_robot_template(templates)
        
        # Generate task content
        task_content = ""
        for i, task in enumerate(tasks):
            script_name = self._task_to_script_name(task)
            task_content += self._generate_robot_task(task, script_name, platform)
            if i < len(tasks) - 1:
                task_content += "\n\n"
        
        # Complete robot file content
        robot_content = f'''*** Settings ***
Documentation       {requirements['title']}
Metadata            Author    auto-generated
Metadata            Display Name    {codebundle_name.replace('-', ' ').title()}
Metadata            Supports    {platform.upper()}

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
{task_content}

*** Keywords ***
Suite Initialization
    RW.Core.Import Service    bash
    RW.Core.Import Service    k8s
    RW.Core.Import Service    curl
    Set Suite Variable    ${{OUTPUT_DIR}}    /tmp/rwi_output
    Create Directory    ${{OUTPUT_DIR}}
'''
        
        return robot_content
    
    def _get_robot_template(self, templates: Dict) -> str:
        """Get Robot Framework template"""
        if templates['robot_tasks']:
            return templates['robot_tasks'][0]['content']
        return ""
    
    def _generate_robot_task(self, task: str, script_name: str, platform: str) -> str:
        """Generate individual Robot Framework task"""
        
        task_name = task.replace('Check ', '').replace('check ', '')
        
        return f'''{task}
    [Documentation]    {task}
    [Tags]    {platform}    {task_name.lower().replace(' ', '-')}    auto-generated
    ${{result}}=    RW.CLI.Run Bash File
    ...    bash_file={script_name}
    ...    env=${{env}}
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${{result.stdout}}
    
    # Parse results and create issues if needed
    ${{issues}}=    RW.CLI.Run CLI    cat ${{OUTPUT_DIR}}/results.json | jq -r '.issues[]'
    IF    "${{issues.stdout}}" != ""
        ${{issue_count}}=    RW.CLI.Run CLI    cat ${{OUTPUT_DIR}}/results.json | jq '.issues | length'
        RW.Core.Add To Report    Found ${{issue_count.stdout}} issues
        
        # Add each issue
        ${{parsed_issues}}=    RW.CLI.Run CLI    cat ${{OUTPUT_DIR}}/results.json | jq -c '.issues[]'
        FOR    ${{issue_line}}    IN    @{{parsed_issues.stdout.split('\\n')}}
            IF    "${{issue_line}}" != ""
                ${{issue}}=    Evaluate    json.loads('${{issue_line}}')    json
                RW.Core.Add Issue
                ...    severity=${{issue.get('severity', 3)}}
                ...    title=${{issue.get('title', 'Issue Detected')}}
                ...    details=${{issue.get('details', 'No details available')}}
                ...    next_steps=${{issue.get('next_steps', 'Please investigate the reported issue')}}
            END
        END
    END'''
    
    def generate_meta_yaml(self, requirements: Dict, scripts: Dict[str, str]) -> str:
        """Generate meta.yaml configuration"""
        logger.info("Generating meta.yaml...")
        
        commands = []
        for script_name, script_content in scripts.items():
            task_name = script_name.replace('.sh', '').replace('_', ' ').title()
            
            command = {
                'command': f'bash \'{script_name}\'',
                'doc_links': self._generate_doc_links(requirements['platform']),
                'explanation': f'This script {task_name.lower()} for {requirements["platform"]} resources.',
                'name': f'{task_name.lower().replace(" ", "_")}_for_{requirements["service_type"].replace("-", "_")}',
                'when_is_it_useful': self._generate_when_useful(task_name, requirements['platform'])
            }
            commands.append(command)
        
        meta_content = {'commands': commands}
        return yaml.dump(meta_content, default_flow_style=False, sort_keys=False)
    
    def _generate_doc_links(self, platform: str) -> str:
        """Generate documentation links for platform"""
        
        if platform == 'azure':
            return '''
    - [Azure CLI documentation](https://docs.microsoft.com/en-us/cli/azure/){:target="_blank"}
    - [Azure Resource Manager](https://docs.microsoft.com/en-us/azure/azure-resource-manager/){:target="_blank"}
    - [Azure Security Best Practices](https://docs.microsoft.com/en-us/azure/security/){:target="_blank"}'''
        
        elif platform == 'k8s':
            return '''
    - [Kubernetes documentation](https://kubernetes.io/docs/){:target="_blank"}
    - [kubectl reference](https://kubernetes.io/docs/reference/kubectl/){:target="_blank"}
    - [Kubernetes troubleshooting](https://kubernetes.io/docs/tasks/debug-application-cluster/){:target="_blank"}'''
        
        else:
            return '''
    - [General troubleshooting guide](https://docs.runwhen.com/){:target="_blank"}'''
    
    def _generate_when_useful(self, task_name: str, platform: str) -> str:
        """Generate when_is_it_useful content"""
        
        return f'''1. When troubleshooting {platform} resource issues and need to {task_name.lower()}
2. During regular health checks and monitoring of {platform} infrastructure
3. As part of compliance auditing and security assessments
4. When investigating performance or connectivity problems
5. For automated monitoring and alerting in CI/CD pipelines'''
    
    def generate_readme(self, requirements: Dict) -> str:
        """Generate README.md content"""
        logger.info("Generating README.md...")
        
        codebundle_name = requirements['codebundle_name']
        platform = requirements['platform']
        tasks = requirements['tasks']
        
        readme_content = f'''# {codebundle_name.replace('-', ' ').title()} Codebundle

This codebundle was auto-generated to address the requirements in issue #{requirements['issue_number']}.

## Overview

{requirements['title']}

This codebundle provides comprehensive checks for {platform} resources, focusing on {requirements['service_type']} {requirements['purpose']}.

## Tasks Included

'''
        
        for i, task in enumerate(tasks, 1):
            readme_content += f"{i}. **{task}**: Automated check for {task.lower()}\n"
        
        readme_content += f'''
## Usage

### Prerequisites

- {platform.upper()} CLI configured and authenticated
- Appropriate permissions for resource access
- Environment variables configured (see below)

### Environment Variables

'''
        
        if platform == 'azure':
            readme_content += '''- `AZ_RESOURCE_GROUP`: Azure resource group name
- `AZURE_RESOURCE_SUBSCRIPTION_ID`: Azure subscription ID (optional)
'''
        elif platform == 'k8s':
            readme_content += '''- `CONTEXT`: Kubernetes context name
- `NAMESPACE`: Kubernetes namespace
'''
        
        readme_content += '''
### Running the Codebundle

#### As SLI (Service Level Indicator)
```bash
ro sli.robot
```

#### As TaskSet (Troubleshooting)
```bash
ro runbook.robot
```

## Generated Components

This auto-generated codebundle includes:

- **Bash Scripts**: Automated checks and validations
- **Robot Framework Tasks**: Structured task execution
- **Documentation**: This README and inline documentation
- **Metadata**: Configuration for the RunWhen platform

## Customization

This codebundle was generated based on the issue requirements. You may need to:

1. Adjust environment variables for your specific setup
2. Modify script logic for your use case
3. Update documentation as needed
4. Add additional error handling or validation

## Support

For issues or questions about this auto-generated codebundle:

1. Check the original issue #{requirements['issue_number']} for context
2. Review the generated scripts for any needed customizations
3. Consult the platform-specific documentation linked in meta.yaml

---

*This codebundle was automatically generated by the RunWhen AI Codebundle Generator*
'''
        
        return readme_content
    
    def generate_cursorrules(self, requirements: Dict) -> str:
        """Generate .cursorrules file"""
        
        platform = requirements['platform']
        service_type = requirements['service_type']
        
        return f'''# {requirements['codebundle_name']} Cursor Rules

## Codebundle Context
This is an auto-generated codebundle for {platform} {service_type} {requirements['purpose']}.

## Platform-Specific Guidelines

### {platform.upper()} Best Practices
- Use appropriate CLI commands and error handling
- Follow established patterns from similar codebundles
- Include proper authentication and subscription management
- Generate structured JSON output for issue reporting

## Code Standards
- Bash scripts should include error handling and validation
- Robot Framework tasks should follow naming conventions
- All scripts should output to $OUTPUT_DIR/results.json
- Include meaningful logging and progress indicators

## Issue Reporting Format
Issues should be reported in JSON format with:
- title: Clear, descriptive issue title
- details: Specific details about the problem
- severity: 1-4 scale (1=Critical, 4=Low)
- next_steps: Actionable remediation steps
'''
    
    def _write_scripts(self, codebundle_dir: Path, scripts: Dict[str, str]):
        """Write bash scripts to codebundle directory"""
        for script_name, content in scripts.items():
            script_path = codebundle_dir / script_name
            with open(script_path, 'w') as f:
                f.write(content)
            # Make executable
            script_path.chmod(0o755)
    
    def _write_robot_file(self, codebundle_dir: Path, content: str):
        """Write Robot Framework file"""
        with open(codebundle_dir / 'runbook.robot', 'w') as f:
            f.write(content)
    
    def _write_meta_yaml(self, codebundle_dir: Path, content: str):
        """Write meta.yaml file"""
        with open(codebundle_dir / 'meta.yaml', 'w') as f:
            f.write(content)
    
    def _write_readme(self, codebundle_dir: Path, content: str):
        """Write README.md file"""
        with open(codebundle_dir / 'README.md', 'w') as f:
            f.write(content)
    
    def _write_cursorrules(self, codebundle_dir: Path, content: str):
        """Write .cursorrules file"""
        with open(codebundle_dir / '.cursorrules', 'w') as f:
            f.write(content)
    
    def _set_github_outputs(self, requirements: Dict, scripts: Dict, robot_content: str):
        """Set GitHub Action outputs"""
        
        # Set outputs for GitHub Action
        github_output = os.environ.get('GITHUB_OUTPUT')
        if github_output:
            with open(github_output, 'a') as f:
                f.write(f"codebundle-name={requirements['codebundle_name']}\n")
                f.write(f"generated-scripts={', '.join(scripts.keys())}\n")
                f.write(f"generated-tasks={len(requirements['tasks'])}\n")
                f.write(f"success=true\n")

def main():
    """Main entry point"""
    try:
        # Get inputs from environment
        issue_number = int(os.environ['INPUT_ISSUE_NUMBER'])
        github_token = os.environ['INPUT_GITHUB_TOKEN']
        openai_api_key = os.environ.get('INPUT_OPENAI_API_KEY', '')
        
        logger.info(f"Starting codebundle generation for issue #{issue_number}")
        
        # Initialize generator
        generator = CodebundleGenerator(issue_number, github_token, openai_api_key)
        
        # Parse requirements
        requirements = generator.parse_issue_requirements()
        
        # Find similar codebundles
        similar_bundles = generator.find_similar_codebundles(requirements)
        
        # Read templates
        templates = generator.read_template_files(similar_bundles)
        
        # Generate codebundle
        success = generator.generate_codebundle(requirements, templates)
        
        if success:
            logger.info("Codebundle generation completed successfully!")
        else:
            logger.error("Codebundle generation failed!")
            exit(1)
            
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        # Set failure output
        github_output = os.environ.get('GITHUB_OUTPUT')
        if github_output:
            with open(github_output, 'a') as f:
                f.write(f"success=false\n")
        exit(1)

if __name__ == "__main__":
    main()
