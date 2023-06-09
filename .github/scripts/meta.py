"""
Utility file to generate metadata file for each 
runbook. Initial purpose is to hold static 
command explainations for use with runwhen-local 
documentation. 

parse_robot_file written by Kyle Forster

Author: Shea Stewart
"""
import sys
import os
import fnmatch
import re
import requests
import yaml
from urllib.parse import urlencode
from robot.api import TestSuite


def parse_robot_file(fpath):
    """
    Parses a robot file in to a python object that is
    json serializable, representing all kinds of interesting
    bits and pieces about the file contents (for UI purposes).
    """
    suite = TestSuite.from_file_system(fpath)
    # pprint.pprint(dir(suite))
    ret = {}
    ret["doc"] = suite.doc  # The doc string
    ret["type"] = suite.name.lower()
    ret["tags"] = []

    for k, v in suite.metadata.items():
        if k.lower() in ["author", "name"]:
            ret[k.lower()] = v
    tasks = []
    for task in suite.tests:
        tags = [str(tag) for tag in task.tags if tag not in ["skipped"]]
        # print (task.body)
        tasks.append(
            {
                "id": task.id,
                "name": task.name,
                # "tags": tags,
                "doc": str(task.doc),
                "keywords": task.body
            }
        )
        ret["tags"] = list(set(ret["tags"] + tags))
    ret["tasks"] = tasks
    resourcefile = suite.resource
    ret["imports"] = []
    for i in resourcefile.imports:
        ret["imports"].append(i.name)
    return ret

def find_files(directory, pattern):
    """
    Search for files given directory and its subdirectories matching a pattern.

    Args:
        directory (str): The path of the directory to search.

    Returns:
        A list of file paths that match the search criteria.
    """
    matches = []
    for root, dirnames, filenames in os.walk(directory):
        for filename in fnmatch.filter(filenames, pattern):
            matches.append(os.path.join(root, filename))
    return matches

def parse_yaml (fpath):
    with open(fpath, 'r') as file:
        data = yaml.safe_load(file)
    return data

def search_keywords(parsed_robot, search_list):
    """
    Search through the list of keywords in the robot file,
    looking for interesting patterns that we can extrapolate. 


    Args:
        parsed_robot (object): The parsed robot contents. 
        search_list (list): A list of strings to match desired keywords on. 

    Returns:
        A list of commands that matched the search pattern. 
    """
    commands = []
    for task in parsed_robot['tasks']:
        for keyword in task['keywords']: 
            if hasattr(keyword,  'name'):
                for item  in search_list: 
                    # if item in keyword.name:
                    ## Switched to args to only match on  render_in_commandlist=true
                    ## Not sure if this is the most scalable approach, so it's just 
                    ## a test for now
                    if item in keyword.args:
                        # commands.append(f'#{task["name"]}  \n')
                        # cmd = cmd_expansion(keyword.args, parsed_runbook_config)
                        # commands.append(f'{cmd}  \n')
                        command = {
                                "name": task["name"],
                                "command": cmd_expansion(keyword.args)
                                }
                        commands.append(command)
    return commands

def remove_escape_chars(cmd):
    cmd = cmd.replace('\\\%', '%')
    cmd = cmd.replace('\\\n', '')
    cmd = cmd.replace('\\\\', '\\')
    cmd = cmd.encode().decode('unicode_escape')
    ## Handle cases where a wrapped quote has returned
    if cmd[0] == cmd[-1] == '"':
        cmd=cmd[1:-1]
    if cmd[0] == cmd[-1] == "'":
        cmd=cmd[1:-1]    
    return cmd


def cmd_expansion(keyword_arguments):
    """
    Cleans up the command details as sent in from robot parsing.
    Substitutes major binaries in for better command explaination,  
    and escapes special characters. 


    Args:
        keyword_arguments (object): The cmd arguments as parsed from robot.  

    Returns:
        A cleaned up and variable expanded command string. 
    """
    cmd_components = str(keyword_arguments)

    ## Clean up the parsed cmd from robot
    cmd_components = cmd_components.lstrip('(').rstrip(')')
    cmd_components = cmd_components.rstrip(')')
    cmd_components = cmd_components.replace('cmd=', '')
    ## TODO Search for render_in_commandlist=true to include in docs. Can't do this right now 
    ## until we update codebundles that we're using for this. 

    ## Split by comma if comma is not wrapped in single or escaped quotes
    ## this is needed to separate the command from the args as 
    ## parsed by the robot parser
    split_regex = re.compile(r'''((?:[^,'"]|'(?:(?:\\')|[^'])*'|"(?:\\"|[^"])*")+)''')
    cmd_components = split_regex.split(cmd_components)[1::2]

    ## Substitute in the proper binary
    ## TODO Consider a check for Distribution type
    ## Jon Funk mentioned that distrubiton type might not be used 
    cmd_str=cmd_components[0]

    if "binary_name" in cmd_str: 
        cmd_str = cmd_str.replace('${binary_name}', 'kubectl')
    if "BINARY_USED" in cmd_str: 
        cmd_str = cmd_str.replace('${BINARY_USED}', 'kubectl')
    if "KUBERNETES_DISTRIBUTION_BINARY" in cmd_str: 
        cmd_str = cmd_str.replace('${KUBERNETES_DISTRIBUTION_BINARY}', 'kubectl')
    
    # Set var for public command before configProvided substitutiuon
    # This is used for the Explain function and guarantees no sensitive information
    cmd = remove_escape_chars(cmd_str)

    return cmd


def generate_metadata(directory_path):
    """
    Gets passed in a directory to scan for robot files. 
    Performs variable substitution only for command binaries, 
    written out  metadata file. 

    Args:
        args (str): The path the output contents from map-builder. 

    Returns:
        Object 
    """
    explainUrl=f'https://backend-services.dev.project-468.com/bow/raw?prompt='
    search_list = ['render_in_commandlist=true']
    runbook_files = find_files(directory_path, 'runbook.robot')
    for runbook in runbook_files:
        print(f'generating meta for {runbook}')
        parsed_robot = parse_robot_file(runbook)
        interesting_commands = search_keywords(parsed_robot, search_list)
        commands = []

        for item in interesting_commands:
            name = item['name']
            command = item['command']
            # Convert name to lower snake case
            name_snake_case = re.sub(r'\W+', '_', name.lower())
            query = f'Please%20explain%20this%20command%20as%20if%20I%20was%20new%20to%20Kubernetes: {command}'
            print(f'generating explanation for {name_snake_case}')
            explain_query = urlencode({'prompt': query})
            url = f'{explainUrl}{explain_query}'   
            response = requests.get(url)
            # Check if the request was successful (status code 200)
            if response.status_code == 200:
                data = response.json()  # Full response content as JSON

                command_meta = {
                    'name': name_snake_case,
                    'command': command,
                    'explanation': data['explanation']
                }
                
                # Add the command meta to the list of commands
                commands.append(command_meta)
            else:
                print("Request failed with status code:", response.status_code)
        # Create a dictionary with the commands list
        yaml_data = {'commands': commands}

        # Write out the YAML file
        dir_path = os.path.dirname(runbook)
        file_path = os.path.join(dir_path, 'meta.yaml')
        with open(file_path, 'w') as f:
            yaml.dump(yaml_data, f)
        print(f'writing meta.yml for {runbook}')



if __name__ == "__main__":
    generate_metadata(sys.argv[1])