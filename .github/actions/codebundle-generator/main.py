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

# Try to import OpenAI
try:
    import openai
    OPENAI_AVAILABLE = True
except ImportError:
    OPENAI_AVAILABLE = False

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class CodebundleGenerator:
    def __init__(self, issue_number: int, github_token: str, openai_api_key: Optional[str] = None):
        self.gh = Github(github_token)
        self.repo = self.gh.get_repo(os.environ['GITHUB_REPOSITORY'])
        self.issue = self.repo.get_issue(issue_number)
        self.openai_api_key = openai_api_key
        
        # Set workspace first, then load config
        # Set workspace - find the repository root
        current_dir = Path.cwd()
        # If we're in the action directory, go up to find the repo root
        if '.github/actions' in str(current_dir):
            # Go up from .github/actions/codebundle-generator to repo root
            self.workspace_root = current_dir.parent.parent.parent
        else:
            # We're already in the repo root or GitHub Actions workspace
            self.workspace_root = current_dir
        
        self.config = self._load_config()
        self.prompts = self._load_prompts()
        
        # Initialize OpenAI if available and configured
        ai_service = self.config.get('ai', {}).get('service', 'template')
        logger.info(f"AI service configuration: {ai_service}")
        logger.info(f"OpenAI available: {OPENAI_AVAILABLE}")
        logger.info(f"OpenAI API key provided: {'Yes' if openai_api_key else 'No'}")
        
        if OPENAI_AVAILABLE and openai_api_key and ai_service in ['openai', 'hybrid']:
            openai.api_key = openai_api_key
            self.ai_enabled = True
            logger.info("🤖 AI generation enabled with OpenAI")
        else:
            self.ai_enabled = False
            if not OPENAI_AVAILABLE:
                logger.info("📝 Using template-based generation (OpenAI package not available)")
            elif not openai_api_key:
                logger.info("📝 Using template-based generation (no OpenAI API key provided)")
            elif ai_service == 'template':
                logger.info("📝 Using template-based generation (configured for templates)")
            else:
                logger.info(f"📝 Using template-based generation (service: {ai_service})")
            
            # If AI service is configured but not available, warn user
            if ai_service == 'openai' and not openai_api_key:
                logger.warning("⚠️  AI service is set to 'openai' but no API key provided. Add OPENAI_API_KEY to secrets for AI generation.")
        
        logger.info(f"Initialized generator for issue #{issue_number}")
        logger.info(f"Current directory: {current_dir}")
        logger.info(f"Workspace root: {self.workspace_root}")
        logger.info(f"Codebundles directory: {self.workspace_root / 'codebundles'}")
        logger.info(f"Codebundles exists: {(self.workspace_root / 'codebundles').exists()}")
        
    def _load_config(self) -> Dict:
        """Load configuration from config file"""
        try:
            config_path = self.workspace_root / '.github' / 'codebundle-generator-config.yml'
            if config_path.exists():
                with open(config_path, 'r') as f:
                    return yaml.safe_load(f)
        except Exception as e:
            logger.warning(f"Failed to load config: {e}")
        return {}
    
    def _load_prompts(self) -> Dict:
        """Load prompts from prompts file"""
        try:
            # Try action directory first
            prompts_path = Path(__file__).parent / 'prompts.yml'
            if prompts_path.exists():
                with open(prompts_path, 'r') as f:
                    return yaml.safe_load(f)
            
            # Fallback to workspace
            prompts_path = self.workspace_root / '.github' / 'actions' / 'codebundle-generator' / 'prompts.yml'
            if prompts_path.exists():
                with open(prompts_path, 'r') as f:
                    return yaml.safe_load(f)
        except Exception as e:
            logger.warning(f"Failed to load prompts: {e}")
        return {}
        
    def _get_reference_codebundles(self, requirements: Dict) -> List[Dict]:
        """Get reference codebundles for AI guidance"""
        platform = requirements['platform']
        purpose = requirements['purpose']
        
        # Get reference codebundle names from config
        ref_config = self.config.get('reference_codebundles', {})
        ref_names = ref_config.get(platform, {}).get(purpose, [])
        
        if not ref_names:
            # Fallback to any codebundles for the platform
            ref_names = []
            for purpose_key, bundles in ref_config.get(platform, {}).items():
                ref_names.extend(bundles[:2])  # Limit to 2 per purpose
        
        # Load actual codebundle content
        reference_bundles = []
        for name in ref_names[:3]:  # Limit to 3 references
            bundle_path = self.workspace_root / 'codebundles' / name
            if bundle_path.exists():
                bundle_data = self._load_codebundle_content(bundle_path)
                if bundle_data:
                    reference_bundles.append(bundle_data)
        
        return reference_bundles
    
    def _load_codebundle_content(self, bundle_path: Path) -> Optional[Dict]:
        """Load content from a reference codebundle"""
        try:
            content = {
                'name': bundle_path.name,
                'meta': {},
                'scripts': [],
                'robot_content': '',
                'readme': ''
            }
            
            # Load meta.yaml
            meta_path = bundle_path / 'meta.yaml'
            if meta_path.exists():
                with open(meta_path, 'r') as f:
                    content['meta'] = yaml.safe_load(f)
            
            # Load scripts
            for script_file in bundle_path.glob('*.sh'):
                with open(script_file, 'r') as f:
                    content['scripts'].append({
                        'name': script_file.name,
                        'content': f.read()[:1000]  # Limit content
                    })
            
            # Load robot file
            robot_path = bundle_path / 'runbook.robot'
            if robot_path.exists():
                with open(robot_path, 'r') as f:
                    content['robot_content'] = f.read()[:1000]  # Limit content
            
            # Load README
            readme_path = bundle_path / 'README.md'
            if readme_path.exists():
                with open(readme_path, 'r') as f:
                    content['readme'] = f.read()[:500]  # Limit content
            
            return content
        except Exception as e:
            logger.warning(f"Failed to load reference codebundle {bundle_path.name}: {e}")
            return None
    
    def _generate_with_ai(self, prompt: str, context: str = "", component_type: str = "content") -> Optional[str]:
        """Generate content using OpenAI"""
        if not self.ai_enabled:
            logger.info(f"🚫 AI disabled for {component_type} generation")
            return None
        
        try:
            ai_config = self.config.get('ai', {}).get('openai', {})
            model = ai_config.get('model', 'gpt-4')
            max_tokens = ai_config.get('max_tokens', 2000)
            temperature = ai_config.get('temperature', 0.3)
            
            logger.info(f"🤖 Calling OpenAI for {component_type} generation")
            logger.info(f"📋 Model: {model}, Max tokens: {max_tokens}, Temperature: {temperature}")
            
            # Log prompt (truncated for readability)
            prompt_preview = prompt[:200] + "..." if len(prompt) > 200 else prompt
            logger.info(f"💬 Prompt preview: {prompt_preview}")
            
            # Get system prompt from config
            system_prompt = self.prompts.get('system_prompt', 
                "You are an expert DevOps engineer creating RunWhen codebundles. Generate high-quality, production-ready code following best practices.")
            
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": f"{context}\n\n{prompt}"}
            ]
            
            response = openai.ChatCompletion.create(
                model=model,
                messages=messages,
                max_tokens=max_tokens,
                temperature=temperature
            )
            
            generated_content = response.choices[0].message.content.strip()
            logger.info(f"✅ OpenAI response received for {component_type}")
            logger.info(f"📊 Response length: {len(generated_content)} characters")
            
            # Log response preview
            response_preview = generated_content[:200] + "..." if len(generated_content) > 200 else generated_content
            logger.info(f"📝 Response preview: {response_preview}")
            
            return generated_content
        
        except Exception as e:
            logger.error(f"❌ AI generation failed for {component_type}: {e}")
            if self.config.get('ai', {}).get('fallback_to_template', True):
                logger.info("🔄 Falling back to template generation")
            return None
    
    def _build_reference_context(self, reference_bundles: List[Dict], requirements: Dict) -> str:
        """Build context string from reference codebundles"""
        if not reference_bundles:
            return "No reference codebundles available."
        
        context_parts = [
            f"Reference codebundles for {requirements['platform']} {requirements['purpose']} tasks:",
            ""
        ]
        
        for bundle in reference_bundles:
            context_parts.append(f"## {bundle['name']}")
            
            if bundle.get('meta'):
                context_parts.append(f"Description: {bundle['meta'].get('description', 'N/A')}")
            
            if bundle.get('scripts'):
                context_parts.append("Example scripts:")
                for script in bundle['scripts'][:2]:  # Limit to 2 scripts per bundle
                    context_parts.append(f"### {script['name']}")
                    context_parts.append(f"```bash\n{script['content'][:500]}...\n```")
            
            context_parts.append("")
        
        return "\n".join(context_parts)
        
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
            
            # Generate SLI content
            sli_content = self.generate_sli_robot(requirements, templates)
            
            # Write files
            self._write_scripts(codebundle_dir, scripts)
            self._write_robot_file(codebundle_dir, robot_content)
            self._write_sli_file(codebundle_dir, sli_content)
            self._write_meta_yaml(codebundle_dir, meta_content)
            self._write_readme(codebundle_dir, readme_content)
            self._write_cursorrules(codebundle_dir, cursorrules_content)
            self._create_test_directory(codebundle_dir, requirements)
            self._create_runwhen_directory(codebundle_dir, requirements)
            
            # Set outputs for GitHub Action
            self._set_github_outputs(requirements, scripts, robot_content)
            
            logger.info("Codebundle generation completed successfully")
            return True
            
        except Exception as e:
            logger.error(f"Failed to generate codebundle: {e}")
            return False
    
    def generate_scripts(self, requirements: Dict, templates: Dict) -> Dict[str, str]:
        """Generate bash scripts for each task (AI-enhanced)"""
        logger.info("Generating bash scripts...")
        
        # Check if AI should be used for scripts
        use_ai = (self.ai_enabled and 
                  self.config.get('ai', {}).get('use_ai_for', {}).get('scripts', False))
        
        logger.info(f"🔧 Script generation method: {'AI' if use_ai else 'Template'}")
        
        if use_ai:
            return self._generate_scripts_with_ai(requirements, templates)
        else:
            return self._generate_scripts_with_templates(requirements, templates)
    
    def _generate_scripts_with_ai(self, requirements: Dict, templates: Dict) -> Dict[str, str]:
        """Generate scripts using AI with reference codebundle guidance"""
        scripts = {}
        
        # Get reference codebundles for context
        reference_bundles = self._get_reference_codebundles(requirements)
        
        # Build context from reference bundles
        context = self._build_reference_context(reference_bundles, requirements)
        
        for i, task in enumerate(requirements['tasks']):
            script_name = self._task_to_script_name(task)
            
            # Get prompt template from config
            prompt_template = self.prompts.get('script_generation', {}).get('prompt', 
                """Generate a bash script for this task: {task}

Platform: {platform}
Service Type: {service_type}
Purpose: {purpose}

Requirements:
- Follow the patterns shown in the reference examples
- Include proper error handling and logging
- Use platform-specific CLI commands
- Add helpful comments
- Return meaningful exit codes
- Include validation steps

The script should be production-ready and follow DevOps best practices.""")
            
            prompt = prompt_template.format(
                task=task,
                platform=requirements['platform'],
                service_type=requirements['service_type'],
                purpose=requirements['purpose']
            )
            
            ai_content = self._generate_with_ai(prompt, context, f"script-{script_name}")
            
            if ai_content:
                scripts[script_name] = ai_content
                logger.info(f"✅ Generated script {script_name} with AI")
            else:
                # Fallback to template generation
                script_content = self._generate_script_content(task, requirements['platform'], 
                                                             self._get_script_template(requirements['platform'], templates))
                scripts[script_name] = script_content
                logger.info(f"Generated script {script_name} with template fallback")
        
        return scripts
    
    def _generate_scripts_with_templates(self, requirements: Dict, templates: Dict) -> Dict[str, str]:
        """Generate scripts using templates (original method)"""
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
        """Generate Robot Framework tasks (AI-enhanced)"""
        logger.info("Generating Robot Framework tasks...")
        
        # Check if AI should be used for robot tasks
        use_ai = (self.ai_enabled and 
                  self.config.get('ai', {}).get('use_ai_for', {}).get('robot_tasks', False))
        
        logger.info(f"🤖 Robot tasks generation method: {'AI' if use_ai else 'Template'}")
        
        if use_ai:
            return self._generate_robot_tasks_with_ai(requirements, templates)
        else:
            return self._generate_robot_tasks_with_templates(requirements, templates)
    
    def _generate_robot_tasks_with_ai(self, requirements: Dict, templates: Dict) -> str:
        """Generate Robot Framework tasks using AI"""
        # Get reference codebundles for context
        reference_bundles = self._get_reference_codebundles(requirements)
        context = self._build_reference_context(reference_bundles, requirements)
        
        # Get prompt template from config
        prompt_template = self.prompts.get('robot_framework', {}).get('prompt',
            """Generate a Robot Framework file for these tasks: {tasks}

Platform: {platform}
Service Type: {service_type}
Purpose: {purpose}
Codebundle Name: {codebundle_name}

Requirements:
- Follow Robot Framework syntax exactly
- Include proper documentation and metadata
- Use RW.Core library for bash script execution
- Include proper error handling
- Add meaningful tags
- Follow the patterns from reference examples
- Include Suite Setup with environment variables

Generate a complete Robot Framework file with *** Settings ***, *** Tasks ***, and *** Keywords *** sections.""")
        
        prompt = prompt_template.format(
            tasks=', '.join(requirements['tasks']),
            platform=requirements['platform'],
            service_type=requirements['service_type'],
            purpose=requirements['purpose'],
            codebundle_name=requirements['codebundle_name']
        )
        
        ai_content = self._generate_with_ai(prompt, context, "robot-framework")
        
        if ai_content:
            logger.info("✅ Generated Robot Framework tasks with AI")
            return ai_content
        else:
            logger.info("🔄 Falling back to template-based Robot Framework generation")
            return self._generate_robot_tasks_with_templates(requirements, templates)
    
    def _generate_robot_tasks_with_templates(self, requirements: Dict, templates: Dict) -> str:
        """Generate Robot Framework tasks using templates (original method)"""
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
    
    def generate_sli_robot(self, requirements: Dict, templates: Dict) -> str:
        """Generate SLI Robot Framework file"""
        logger.info("Generating SLI Robot Framework file...")
        
        platform = requirements['platform']
        codebundle_name = requirements['codebundle_name']
        
        # Generate SLI tasks (simplified versions that return metrics)
        sli_tasks = []
        for task in requirements['tasks'][:3]:  # Limit to 3 SLI tasks
            script_name = self._task_to_script_name(task)
            task_name = task.replace('Check ', '').replace('check ', '')
            
            sli_task = f'''{task} SLI
    [Documentation]    SLI for {task}
    [Tags]    {platform}    sli    {task_name.lower().replace(' ', '-')}
    ${{result}}=    RW.CLI.Run Bash File
    ...    bash_file={script_name}
    ...    env=${{env}}
    ...    include_in_history=false
    
    # Parse result and push metric
    ${{issues}}=    RW.CLI.Run CLI    cat ${{OUTPUT_DIR}}/results.json | jq '.issues | length'
    ${{metric_value}}=    Set Variable If    ${{issues.stdout}} == 0    1    0
    RW.Core.Push Metric    ${{metric_value}}'''
            
            sli_tasks.append(sli_task)
        
        sli_content = f'''*** Settings ***
Documentation       SLI for {requirements['title']}
Metadata            Author    auto-generated
Metadata            Display Name    {codebundle_name.replace('-', ' ').title()} SLI
Metadata            Supports    {platform.upper()}

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
{chr(10).join(sli_tasks)}

*** Keywords ***
Suite Initialization
    RW.Core.Import Service    bash
    RW.Core.Import Service    k8s
    RW.Core.Import Service    curl
    Set Suite Variable    ${{OUTPUT_DIR}}    /tmp/rwi_output
    Create Directory    ${{OUTPUT_DIR}}
'''
        
        return sli_content
    
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
        """Generate README.md content (AI-enhanced)"""
        logger.info("Generating README.md...")
        
        # Check if AI should be used for documentation
        use_ai = (self.ai_enabled and 
                  self.config.get('ai', {}).get('use_ai_for', {}).get('documentation', False))
        
        logger.info(f"📚 Documentation generation method: {'AI' if use_ai else 'Template'}")
        
        if use_ai:
            return self._generate_readme_with_ai(requirements)
        else:
            return self._generate_readme_with_templates(requirements)
    
    def _generate_readme_with_ai(self, requirements: Dict) -> str:
        """Generate README using AI"""
        # Get reference codebundles for context
        reference_bundles = self._get_reference_codebundles(requirements)
        context = self._build_reference_context(reference_bundles, requirements)
        
        # Get prompt template from config
        prompt_template = self.prompts.get('documentation', {}).get('prompt',
            """Generate a comprehensive README.md for this codebundle:

Name: {codebundle_name}
Platform: {platform}
Service Type: {service_type}
Purpose: {purpose}
Tasks: {tasks}

Requirements:
- Follow markdown format
- Include clear overview and description
- List all tasks with explanations
- Include usage instructions
- Add prerequisites and setup steps
- Include troubleshooting section
- Follow the style and structure of reference examples
- Be comprehensive but concise

Generate a professional, well-structured README.md file.""")
        
        prompt = prompt_template.format(
            codebundle_name=requirements['codebundle_name'],
            platform=requirements['platform'],
            service_type=requirements['service_type'],
            purpose=requirements['purpose'],
            tasks=', '.join(requirements['tasks'])
        )
        
        ai_content = self._generate_with_ai(prompt, context, "readme")
        
        if ai_content:
            logger.info("✅ Generated README with AI")
            return ai_content
        else:
            logger.info("🔄 Falling back to template-based README generation")
            return self._generate_readme_with_templates(requirements)
    
    def _generate_readme_with_templates(self, requirements: Dict) -> str:
        """Generate README using templates (original method)"""
        
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
        purpose = requirements['purpose']
        codebundle_name = requirements['codebundle_name']
        
        return f'''# {codebundle_name.replace('-', ' ').title()} Codebundle - Cursor Rules

## Overview
This codebundle provides {purpose} monitoring for {platform} {service_type.replace('-', ' ')}, including automated checks, validation, and reporting.

## File Structure and Patterns

### Robot Framework Files (.robot)
- **runbook.robot**: Main execution file with tasks and keywords for troubleshooting
- **sli.robot**: Service Level Indicator definitions for monitoring
- Follow Robot Framework syntax and conventions
- Use consistent task naming: `Check/Get/Fetch [Entity] [Action] for [Resource] In [Scope]`
- Always include proper documentation and tags for each task

### Bash Scripts (.sh)
- All scripts must be executable (`chmod +x`)
- Use consistent naming: `[entity]_[action].sh`
- Include comprehensive error handling and validation
- Provide clear stdout output with structured formatting
- Generate both human-readable and machine-readable outputs
- Output JSON results to `$OUTPUT_DIR/results.json`

## Issue Reporting Standards

### Issue Severity Levels
- **Severity 1**: Critical issues affecting service availability
- **Severity 2**: High-impact issues requiring immediate attention
- **Severity 3**: Medium-impact issues that should be addressed (warnings, recommendations)
- **Severity 4**: Low-impact informational issues (configuration recommendations)

### Issue Titles
- **MUST** include entity name and resource information
- **MUST** include resource group/namespace context
- **MUST** be clear, concise, and descriptive
- **Format**: `"[Entity] '[name]' in [Resource] '[resource_name]' has [issue_description]"`

### Issue Details
- **MUST** include complete context (Resource, Group, Subscription/Cluster)
- **MUST** include time period information when relevant
- **MUST** include relevant metrics with clear labels
- **MUST** include specific detected issues with values
- **MUST** include actionable next steps for troubleshooting
- **Format**: Structured sections with clear headers and bullet points

## Configuration Variables

### Required Variables
{self._generate_required_vars(platform)}

### Optional Threshold Variables
- `TIME_PERIOD_MINUTES`: Time period for analysis (default: 30)
- `ERROR_RATE_THRESHOLD`: Error rate threshold % (default: 10)
- `PERFORMANCE_THRESHOLD`: Performance threshold for alerts

## Script Development Guidelines

### Error Handling
- Always validate required environment variables at script start
- Provide meaningful error messages with context
- Use proper exit codes (0 for success, non-zero for errors)
- Handle missing or null data gracefully

### Output Generation
- Generate JSON output to `$OUTPUT_DIR/results.json`
- Include timestamps in reports
- Provide both summary and detailed information
- **JSON Validation**: Always validate JSON output before writing
- **Error Handling**: Provide fallback JSON if validation fails

### {platform.upper()} Integration
{self._generate_platform_guidelines(platform)}

## Testing Requirements

### Script Validation
- All scripts must pass syntax validation (`bash -n`)
- Test with mock data to ensure output generation
- Validate JSON structure and content
- Test error handling scenarios

### Integration Testing
- Test with real {platform} resources when possible
- Verify issue detection and reporting
- Test threshold configurations
- Validate portal/console link generation

## Security Considerations

### Authentication
- Use service principal/service account authentication
- Never hardcode credentials in scripts
- Validate CLI authentication before operations
- Handle authentication errors gracefully

### Data Handling
- Sanitize output data for sensitive information
- Use appropriate permissions for resource access
- Log operations for audit purposes
- Handle PII data appropriately

## Performance Guidelines

### Resource Usage
- Minimize API calls where possible
- Use appropriate time intervals for metrics
- Cache results when appropriate
- Handle large datasets efficiently

### Timeout Handling
- Set appropriate timeouts for long-running operations
- Provide progress indicators for lengthy operations
- Handle partial failures gracefully
'''
    
    def _generate_required_vars(self, platform: str) -> str:
        """Generate required variables section for platform"""
        if platform == 'azure':
            return '''- `AZ_RESOURCE_GROUP`: Azure resource group name
- `AZURE_RESOURCE_SUBSCRIPTION_ID`: Azure subscription ID (optional)'''
        elif platform == 'k8s':
            return '''- `CONTEXT`: Kubernetes context name
- `NAMESPACE`: Kubernetes namespace'''
        elif platform == 'aws':
            return '''- `AWS_REGION`: AWS region
- `AWS_ACCOUNT_ID`: AWS account ID (optional)'''
        elif platform == 'gcp':
            return '''- `GCP_PROJECT_ID`: GCP project ID
- `GCP_REGION`: GCP region (optional)'''
        else:
            return '''- Platform-specific configuration variables as needed'''
    
    def _generate_platform_guidelines(self, platform: str) -> str:
        """Generate platform-specific guidelines"""
        if platform == 'azure':
            return '''- Use Azure CLI for resource management and queries
- Follow Azure Resource Manager patterns
- Include proper subscription and resource group context
- Use Azure Monitor APIs for metrics collection
- Generate Azure Portal links for easy navigation'''
        elif platform == 'k8s':
            return '''- Use kubectl for cluster operations
- Follow Kubernetes API conventions
- Include proper namespace and context handling
- Use Kubernetes metrics APIs when available
- Generate cluster dashboard links when possible'''
        elif platform == 'aws':
            return '''- Use AWS CLI for resource management
- Follow AWS API patterns and conventions
- Include proper region and account context
- Use CloudWatch for metrics collection
- Generate AWS Console links for resources'''
        elif platform == 'gcp':
            return '''- Use gcloud CLI for resource management
- Follow Google Cloud API patterns
- Include proper project and region context
- Use Cloud Monitoring for metrics
- Generate Google Cloud Console links'''
        else:
            return '''- Follow platform-specific best practices
- Use appropriate CLI tools and APIs
- Include proper authentication and context
- Generate relevant console/dashboard links'''
    
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
    
    def _write_sli_file(self, codebundle_dir: Path, content: str):
        """Write SLI Robot Framework file"""
        with open(codebundle_dir / 'sli.robot', 'w') as f:
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
    
    def _create_test_directory(self, codebundle_dir: Path, requirements: Dict):
        """Create .test directory structure"""
        test_dir = codebundle_dir / '.test'
        test_dir.mkdir(exist_ok=True)
        
        # Create basic test README
        test_readme = f'''# Test Infrastructure for {requirements['codebundle_name']}

This directory contains testing infrastructure for the {requirements['codebundle_name']} codebundle.

## Structure

- **README.md**: This file
- **terraform/**: Terraform configurations for test resources (if needed)
- **test_data/**: Sample data for testing
- **scripts/**: Test automation scripts

## Usage

This test infrastructure is designed to validate the codebundle functionality in a controlled environment.

### Prerequisites

- Appropriate cloud credentials configured
- Test environment access
- Required CLI tools installed

### Running Tests

```bash
# Navigate to the codebundle directory
cd codebundles/{requirements['codebundle_name']}

# Run the runbook for testing
ro runbook.robot

# Run the SLI for testing  
ro sli.robot
```

## Test Data

Test data should be placed in the `test_data/` directory and should include:

- Sample configuration files
- Mock API responses
- Expected output examples

## Automation

Test automation scripts should:

- Set up test resources
- Execute the codebundle
- Validate outputs
- Clean up resources

---

*Auto-generated test infrastructure*
'''
        
        with open(test_dir / 'README.md', 'w') as f:
            f.write(test_readme)
    
    def _create_runwhen_directory(self, codebundle_dir: Path, requirements: Dict):
        """Create .runwhen directory structure with templates"""
        runwhen_dir = codebundle_dir / '.runwhen'
        runwhen_dir.mkdir(exist_ok=True)
        
        # Create generation-rules directory
        gen_rules_dir = runwhen_dir / 'generation-rules'
        gen_rules_dir.mkdir(exist_ok=True)
        
        # Create templates directory
        templates_dir = runwhen_dir / 'templates'
        templates_dir.mkdir(exist_ok=True)
        
        codebundle_name = requirements['codebundle_name']
        platform = requirements['platform']
        service_type = requirements['service_type']
        
        # Generate generation rules
        generation_rules = self._generate_generation_rules(requirements)
        with open(gen_rules_dir / f"{codebundle_name}.yaml", 'w') as f:
            f.write(generation_rules)
        
        # Generate SLI template
        sli_template = self._generate_sli_template(requirements)
        with open(templates_dir / f"{codebundle_name}-sli.yaml", 'w') as f:
            f.write(sli_template)
        
        # Generate taskset template
        taskset_template = self._generate_taskset_template(requirements)
        with open(templates_dir / f"{codebundle_name}-taskset.yaml", 'w') as f:
            f.write(taskset_template)
        
        # Generate SLX template
        slx_template = self._generate_slx_template(requirements)
        with open(templates_dir / f"{codebundle_name}-slx.yaml", 'w') as f:
            f.write(slx_template)
        
        # Generate workflow template
        workflow_template = self._generate_workflow_template(requirements)
        with open(templates_dir / f"{codebundle_name}-workflow.yaml", 'w') as f:
            f.write(workflow_template)
    
    def _generate_generation_rules(self, requirements: Dict) -> str:
        """Generate generation rules YAML"""
        codebundle_name = requirements['codebundle_name']
        platform = requirements['platform']
        
        # Map platform to resource types
        resource_types = {
            'azure': 'azure_network_security_groups' if 'network' in requirements['service_type'] else 'azure_resources',
            'aws': 'aws_security_groups' if 'network' in requirements['service_type'] else 'aws_resources', 
            'gcp': 'gcp_firewall_rules' if 'network' in requirements['service_type'] else 'gcp_resources',
            'k8s': 'kubernetes_network_policies' if 'network' in requirements['service_type'] else 'kubernetes_resources'
        }
        
        return f'''apiVersion: runwhen.com/v1
kind: GenerationRules
spec:
  platform: {platform}
  generationRules:
    - resourceTypes:
        - {resource_types.get(platform, f'{platform}_resources')}
      matchRules:
        - type: pattern
          pattern: ".+"
          properties: [name]
          mode: substring
      slxs:
        - baseName: {codebundle_name}
          qualifiers: ["resource", "resource_group"]
          baseTemplateName: {codebundle_name}
          levelOfDetail: basic
          outputItems:
            - type: slx
            - type: sli
            - type: runbook
              templateName: {codebundle_name}-taskset.yaml
            - type: workflow
'''
    
    def _generate_sli_template(self, requirements: Dict) -> str:
        """Generate SLI template YAML"""
        codebundle_name = requirements['codebundle_name']
        platform = requirements['platform']
        
        # Platform-specific config
        config_vars = self._get_platform_config_vars(platform)
        auth_include = self._get_platform_auth_include(platform)
        
        return f'''apiVersion: runwhen.com/v1
kind: ServiceLevelIndicator
metadata:
  name: {{{{slx_name}}}}
  labels:
    {{% include "common-labels.yaml" %}}
  annotations:
    {{% include "common-annotations.yaml" %}}
spec:
  displayUnitsLong: OK
  displayUnitsShort: ok
  locations:
    - {{{{default_location}}}}
  description: Measures the {requirements['purpose']} of {platform} {requirements['service_type'].replace('-', ' ')}.
  codeBundle:
    {{% if repo_url %}}
    repoUrl: {{{{repo_url}}}}
    {{% else %}}
    repoUrl: https://github.com/runwhen-contrib/rw-cli-codecollection.git
    {{% endif %}}
    {{% if ref %}}
    ref: {{{{ref}}}}
    {{% else %}}
    ref: main
    {{% endif %}}
    pathToRobot: codebundles/{codebundle_name}/sli.robot
  intervalStrategy: intermezzo
  intervalSeconds: 300
  configProvided:{config_vars}
  secretsProvided:{auth_include}
  alerts:
    warning:
      operator: <
      threshold: '1'
      for: '20m'
    ticket:
      operator: <
      threshold: '1'
      for: '30m'
    page:
      operator: '=='
      threshold: '0'
      for: ''
'''
    
    def _generate_taskset_template(self, requirements: Dict) -> str:
        """Generate taskset template YAML"""
        codebundle_name = requirements['codebundle_name']
        platform = requirements['platform']
        
        config_vars = self._get_platform_config_vars(platform)
        auth_include = self._get_platform_auth_include(platform)
        
        return f'''apiVersion: runwhen.com/v1
kind: Runbook
metadata:
  name: {{{{slx_name}}}}
  labels:
    {{% include "common-labels.yaml" %}}
  annotations:
    {{% include "common-annotations.yaml" %}}
spec:
  location: {{{{default_location}}}}
  description: Analyzes {platform} {requirements['service_type'].replace('-', ' ')} for {requirements['purpose']} issues
  codeBundle:
    {{% if repo_url %}}
    repoUrl: {{{{repo_url}}}}
    {{% else %}}
    repoUrl: https://github.com/runwhen-contrib/rw-cli-codecollection.git
    {{% endif %}}
    {{% if ref %}}
    ref: {{{{ref}}}}
    {{% else %}}
    ref: main
    {{% endif %}}
    pathToRobot: codebundles/{codebundle_name}/runbook.robot
  configProvided:{config_vars}
  secretsProvided:{auth_include}
'''
    
    def _generate_slx_template(self, requirements: Dict) -> str:
        """Generate SLX template YAML"""
        codebundle_name = requirements['codebundle_name']
        
        return f'''apiVersion: runwhen.com/v1
kind: ServiceLevelX
metadata:
  name: {{{{slx_name}}}}
  labels:
    {{% include "common-labels.yaml" %}}
  annotations:
    {{% include "common-annotations.yaml" %}}
spec:
  description: {requirements['purpose'].title()} monitoring for {requirements['platform']} {requirements['service_type'].replace('-', ' ')}
  sli:
    name: {{{{slx_name}}}}-sli
  runbook:
    name: {{{{slx_name}}}}-runbook
'''
    
    def _generate_workflow_template(self, requirements: Dict) -> str:
        """Generate workflow template YAML"""
        codebundle_name = requirements['codebundle_name']
        
        return f'''apiVersion: runwhen.com/v1
kind: Workflow
metadata:
  name: {{{{slx_name}}}}
  labels:
    {{% include "common-labels.yaml" %}}
  annotations:
    {{% include "common-annotations.yaml" %}}
spec:
  description: Automated {requirements['purpose']} workflow for {requirements['platform']} {requirements['service_type'].replace('-', ' ')}
  location: {{{{default_location}}}}
  steps:
    - name: check-{requirements['purpose']}
      runbook:
        name: {{{{slx_name}}}}-runbook
      triggers:
        - type: sli
          sliName: {{{{slx_name}}}}-sli
          operator: <
          threshold: 1
'''
    
    def _get_platform_config_vars(self, platform: str) -> str:
        """Get platform-specific config variables for templates"""
        if platform == 'azure':
            return '''
    - name: AZ_RESOURCE_GROUP
      value: {{resource_group.name}}
    - name: AZURE_RESOURCE_SUBSCRIPTION_ID
      value: "{{ subscription_id }}"
    - name: AZURE_SUBSCRIPTION_NAME
      value: "{{ subscription_name }}"'''
        elif platform == 'k8s':
            return '''
    - name: CONTEXT
      value: {{context}}
    - name: NAMESPACE
      value: {{namespace}}'''
        elif platform == 'aws':
            return '''
    - name: AWS_REGION
      value: {{region}}
    - name: AWS_ACCOUNT_ID
      value: "{{ account_id }}"'''
        elif platform == 'gcp':
            return '''
    - name: GCP_PROJECT_ID
      value: {{project_id}}
    - name: GCP_REGION
      value: {{region}}'''
        else:
            return '''
    - name: PLATFORM_CONFIG
      value: {{platform_config}}'''
    
    def _get_platform_auth_include(self, platform: str) -> str:
        """Get platform-specific auth include for templates"""
        if platform == 'azure':
            return '''
  {% if wb_version %}
    {% include "azure-auth.yaml" ignore missing %}
  {% else %}
    - name: azure_credentials
      workspaceKey: AUTH DETAILS NOT FOUND
  {% endif %}'''
        elif platform == 'k8s':
            return '''
  {% if wb_version %}
    {% include "k8s-auth.yaml" ignore missing %}
  {% else %}
    - name: kubeconfig
      workspaceKey: AUTH DETAILS NOT FOUND
  {% endif %}'''
        elif platform == 'aws':
            return '''
  {% if wb_version %}
    {% include "aws-auth.yaml" ignore missing %}
  {% else %}
    - name: aws_credentials
      workspaceKey: AUTH DETAILS NOT FOUND
  {% endif %}'''
        elif platform == 'gcp':
            return '''
  {% if wb_version %}
    {% include "gcp-auth.yaml" ignore missing %}
  {% else %}
    - name: gcp_credentials
      workspaceKey: AUTH DETAILS NOT FOUND
  {% endif %}'''
        else:
            return '''
    - name: platform_credentials
      workspaceKey: AUTH DETAILS NOT FOUND'''
    
    def _set_github_outputs(self, requirements: Dict, scripts: Dict, robot_content: str):
        """Set GitHub Action outputs"""
        
        # Set outputs for GitHub Action
        github_output = os.environ.get('GITHUB_OUTPUT')
        logger.info(f"GITHUB_OUTPUT environment variable: {github_output}")
        
        if github_output:
            logger.info(f"Writing outputs to: {github_output}")
            with open(github_output, 'a') as f:
                f.write(f"codebundle-name={requirements['codebundle_name']}\n")
                f.write(f"generated-files={', '.join(scripts.keys())}\n")
                f.write(f"generated-tasks={len(requirements['tasks'])}\n")
                f.write(f"success=true\n")
            logger.info("Outputs written successfully")
        else:
            logger.warning("GITHUB_OUTPUT environment variable not set - outputs will not be available")

def main():
    """Main entry point"""
    try:
        # Debug: Log all environment variables starting with INPUT_
        logger.info("=== ACTION INPUTS DEBUG ===")
        for key, value in os.environ.items():
            if key.startswith('INPUT_'):
                # Mask sensitive values
                display_value = value if key != 'INPUT_OPENAI_API_KEY' else ('***' + value[-4:] if value else 'NOT_SET')
                logger.info(f"{key}: {display_value}")
        logger.info("=== END INPUTS DEBUG ===")
        
        # Get inputs from environment
        issue_number = int(os.environ['INPUT_ISSUE_NUMBER'])
        github_token = os.environ['INPUT_GITHUB_TOKEN']
        openai_api_key = os.environ.get('INPUT_OPENAI_API_KEY', '')
        
        logger.info(f"Starting codebundle generation for issue #{issue_number}")
        logger.info(f"OpenAI API key length: {len(openai_api_key) if openai_api_key else 0}")
        
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
