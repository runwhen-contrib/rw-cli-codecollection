import requests, argparse, subprocess, os, logging, time
from collections import OrderedDict


logger = logging.getLogger(__name__)

SYMBOL_PASS = "\u2705"
SYMBOL_FAIL = "\u274C"
api_token = None
session = None
SESSION_TAGS = ["testing"]
POLL_DURATION = 60
MAX_POLLS = 10


def get_current_git_hash() -> str:
    command = "git rev-parse HEAD"
    process = subprocess.Popen(command, stdout=subprocess.PIPE, shell=True)
    output, _ = process.communicate()
    stdout_string = output.decode("utf-8").strip()
    return stdout_string


def hash_matches_codecollection(cc_name: str, base_url: str, current_hash: str, branch: str = "main") -> bool:
    cc_hash = None
    codecollections = session.get(f"{base_url}/codecollections")
    if codecollections.status_code != 200:
        raise AssertionError(
            f"Received non-200 response during codecollection get: {codecollections.status_code} {codecollections.json()}"
        )
    codecollections = codecollections.json()
    results = codecollections["results"]
    for res in results:
        if not ("spec" in res and "repoURL" in res["spec"]):
            continue
        if cc_name == res["spec"]["repoURL"]:
            cc_hash = res["status"]["versions"][branch]
            break
    if cc_hash == current_hash:
        return True
    return False


def get_codebundles_in_last_commit(runall: bool = False) -> set[str]:
    codebundles: set[str] = []
    if runall:
        command = "ls ../../codebundles"
        process = subprocess.Popen(command, stdout=subprocess.PIPE, shell=True)
        output, _ = process.communicate()
        stdout_string = output.decode("utf-8").strip()
        if len(stdout_string) > 0:
            codebundles: set[str] = set([line for line in stdout_string.split("\n")])
    else:
        command = "git show --name-only | grep codebundles | grep .robot || true"
        process = subprocess.Popen(command, stdout=subprocess.PIPE, shell=True)
        output, _ = process.communicate()
        stdout_string = output.decode("utf-8").strip()
        if len(stdout_string) > 0:
            codebundles: set[str] = set([line.split("/")[1] for line in stdout_string.split("\n")])
    return codebundles


def get_workspace_codebundles(base_url, workspace_name) -> set[str]:
    codebundle_names: set[str] = []
    workspace_entities: list[dict] = []
    cb_stats_rsp = session.get(f"{base_url}/workspaces/{workspace_name}/codebundle-stats")
    if not cb_stats_rsp.status_code == 200:
        raise AssertionError(f"Received non-200 response: {cb_stats_rsp}")
    cb_stats = cb_stats_rsp.json()
    workspace_entities = cb_stats["taskSets"]  # + cb_stats["slis"]
    codebundle_names = set([wse["codeBundleName"] for wse in workspace_entities])
    return codebundle_names


def create_session(user, token, base_url) -> None:
    global api_token
    global session
    token_url = f"{base_url}/token/"
    rsp = requests.post(
        token_url,
        json={"username": user, "password": token},
        headers={"Accept": "application/json"},
    )
    if not rsp.status_code == 200:
        raise AssertionError(f"Received non-200 response: {rsp.json()}")
    api_token = rsp.json()["access"]
    session = requests.Session()
    session.headers.update(
        {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
    )


def run_codebundles_in_workspace(base_url, workspace_name, session_name, cb_list: set[str]) -> {}:
    tasks_running = {}
    slxs_rsp = session.get(f"{base_url}/workspaces/{workspace_name}/slxs")
    runsessions_rsp = session.get(f"{base_url}/workspaces/{workspace_name}/runsessions")
    slxs: list = []
    slxs = [slx["name"] for slx in slxs_rsp.json()["results"]]
    tasksets: list = []
    for slx in slxs:
        shortname = slx.split("--")[1]
        taskset_rsp = session.get(f"{base_url}/workspaces/{workspace_name}/slxs/{shortname}/runbook")
        if taskset_rsp.status_code == 200 and taskset_rsp.json():
            taskset_data = taskset_rsp.json()
            cb_name = None
            if "spec" in taskset_data and "codeBundle" in taskset_data["spec"]:
                cb_name = taskset_data["spec"]["codeBundle"]["pathToRobot"].split("/")[1]
            if cb_name and cb_name in cb_list:
                tasks_running[slx] = taskset_data
    # prep for runsession request
    rrs = [{"slxName": slx, "taskTitles": ["*"]} for slx in tasks_running.keys()]
    runsession_json = {
        "runRequests": rrs,
        "generateName": session_name,
        "tags": ["testing"],
        # "alias": {"key": "src", "value": "testing"},  # uncomment to dedupe with alias
    }
    # print(f"rs post: {runsession_json}")
    rs_rsp = session.post(f"{base_url}/workspaces/{workspace_name}/runsessions", json=runsession_json)
    if not (rs_rsp.status_code == 200 or rs_rsp.status_code == 201):
        raise AssertionError(
            f"Received non-200/201 response during runsession post: {rs_rsp.status_code} {rs_rsp.json()}"
        )
    tasks_running["runsession_data"] = rs_rsp.json()
    return tasks_running


def poll_runsessions_complete(task_data, base_url, workspace_name) -> bool:
    # get the name of the runsession we just created to house tasks
    session_display_name = None
    aliases = task_data["runsession_data"]["aliases"]
    for alias in aliases:
        if alias["key"] == "displayName":
            session_display_name = alias["value"]
    # now get all live runsessions and find ours
    ci_runsession = None
    runsessions_rsp = session.get(f"{base_url}/workspaces/{workspace_name}/runsessions")
    if runsessions_rsp.status_code != 200:
        raise AssertionError(f"Received non-200 response during runsession get: {rs_rsp.status_code} {rs_rsp.json()}")
    for rsr in runsessions_rsp.json()["results"]:
        aliases = rsr["aliases"]
        for alias in aliases:
            if alias["key"] == "displayName" and alias["value"] == session_display_name:
                ci_runsession = rsr
    if not ci_runsession or not session_display_name:
        print(f"No CI runsession or display name found: {ci_runsession}, {session_display_name}")
        return False
    for rr in ci_runsession["runRequests"]:
        short_name = rr["slxShortName"]
        # somehow ran an empty SLX
        if not rr["passedTitles"] and not rr["failedTitles"] and not rr["skippedTitles"] and rr["responseTime"]:
            continue
        # not finished
        if rr["responseTime"] is None:
            print(f"Runrequest from {short_name} under {session_display_name} is not finished, waiting...")
            return False
        # completed runrequest
        # if rr["responseTime"] is not None:
        # if we make it past all rr short circuit returns then assume we iterated over results and it completed
    return True


def get_runsession_ci_results(task_data, base_url, workspace_name) -> dict:
    results: dict = {}
    # get the name of the runsession we just created to house tasks
    session_display_name = None
    aliases = task_data["runsession_data"]["aliases"]
    for alias in aliases:
        if alias["key"] == "displayName":
            session_display_name = alias["value"]
    # now get all live runsessions and find ours
    ci_runsession = None
    runsessions_rsp = session.get(f"{base_url}/workspaces/{workspace_name}/runsessions")
    if runsessions_rsp.status_code != 200:
        raise AssertionError(f"Received non-200 response during runsession get: {rs_rsp.status_code} {rs_rsp.json()}")
    for rsr in runsessions_rsp.json()["results"]:
        aliases = rsr["aliases"]
        for alias in aliases:
            if alias["key"] == "displayName" and alias["value"] == session_display_name:
                ci_runsession = rsr
    if not ci_runsession or not session_display_name:
        return results
    for rr in ci_runsession["runRequests"]:
        # somehow ran an empty SLX
        if not rr["passedTitles"] and not rr["failedTitles"] and not rr["skippedTitles"] and rr["responseTime"]:
            continue
        # not finished
        if rr["responseTime"] is None:
            return False
        # completed runrequest
        if rr["responseTime"] is not None:
            memos = rr["memo"]
            for memo in memos:
                if "fail" in memo and "pass" in memo:
                    results[rr["slxShortName"]] = {}
                    results[rr["slxShortName"]]["pass"] = memo["pass"]
                    results[rr["slxShortName"]]["fail"] = memo["fail"]
    return results


def decorate_results(base_url, workspace_name, results: dict) -> dict:
    # print(results)
    for slx in results.keys():
        taskset_rsp = session.get(f"{base_url}/workspaces/{workspace_name}/slxs/{slx}/runbook")
        if taskset_rsp.status_code != 200:
            raise AssertionError(
                f"Received non-200 response during runsession get: {taskset_rsp.status_code} {taskset_rsp.json()}"
            )
        taskset_data = taskset_rsp.json()
        results[slx]["codebundle"] = None
        if "spec" in taskset_data and "codeBundle" in taskset_data["spec"]:
            cb_name = taskset_data["spec"]["codeBundle"]["pathToRobot"].split("/")[1]
            results[slx]["codebundle"] = cb_name
    return results


def process_results(workspace_name, results) -> None:
    exit_failure = False
    print(f"CI Result in workspace {workspace_name}:")
    for slx, test_results in results.items():
        passes = test_results["pass"]
        fails = test_results["fail"]
        cb_name = test_results["codebundle"]
        has_fails = fails > 0
        if has_fails:
            exit_failure = has_fails
        print(
            f'{f"{cb_name} results in SLX {slx}":<128} ...    Passed: {passes}, Failed: {fails} {SYMBOL_FAIL if has_fails else SYMBOL_PASS}'
        )
    if exit_failure:
        exit(1)
    exit(0)


if __name__ == "__main__":
    USER: str = os.environ.get("API_USER")
    TOKEN: str = os.environ.get("API_TOKEN")
    if not USER or not TOKEN:
        print("API User not provided - please set API_USER and API_TOKEN environment variables")
    parser = argparse.ArgumentParser(
        description="A script that can be used to run end to end tests with codebundles in a given workspace."
    )
    required_named = parser.add_argument_group("required named arguments")
    required_named.add_argument(
        "e2e_workspace", help="The workspace used to create a testing session and search for runnable codebundles."
    )
    required_named.add_argument("papi_url", help="The url of the public API used to make requests against.")
    required_named.add_argument(
        "codecollection_git",
        help="The git url of the codecollection.",
    )
    parser.add_argument(
        "--session_name", default="ci-session", help="The name of the runsession to organize results under."
    )
    parser.add_argument(
        "--runall",
        dest="runall",
        default=False,
        action="store_true",
        help="Flag used to run all codebundles in this codecollection if they're found in the workspace, regardless of recent changes",
    )
    args = parser.parse_args()
    print(f"Current Arguments: {args}")
    # TODO: trace python deps and run dependent codebundles
    create_session(USER, TOKEN, args.papi_url)
    current_hash = get_current_git_hash()
    print("Waiting for CodeCollection changes to reconcile...")
    poll_amount = 0
    while not hash_matches_codecollection(args.codecollection_git, args.papi_url, current_hash):
        print("...")
        time.sleep(POLL_DURATION)
        poll_amount += 1
        if poll_amount >= MAX_POLLS:
            print(
                "CI exceeded max polls waiting for codecollection to reconcile with latest changes before CI - check modelsync/corestate"
            )
            exit(1)
    changed_codebundles: list[str] = []
    changed_codebundles = get_codebundles_in_last_commit(args.runall)
    print("Found the following codebundles to test:")
    print("\n".join(changed_codebundles))
    print("...")
    if len(changed_codebundles) == 0:
        print(f"No codebundles found in last set of changes - found ({changed_codebundles}) , exiting...")
        exit(0)
    codebundles_in_ws: list[str] = []
    codebundles_in_ws = get_workspace_codebundles(args.papi_url, args.e2e_workspace)
    print(f"Found the following taskset codebundles in the {args.e2e_workspace} workspace:")
    print("\n".join(codebundles_in_ws))
    print("...")
    codebundles_to_run: set[str] = set([cb for cb in changed_codebundles if cb in codebundles_in_ws])
    if len(codebundles_to_run) == 0:
        print("Found no codebundles to run, exiting...")
        exit(0)
    print("Queueing following codebundles for testing:")
    print("\n".join(codebundles_to_run))
    print("...")
    task_data = run_codebundles_in_workspace(args.papi_url, args.e2e_workspace, args.session_name, codebundles_to_run)
    print("Beginning polling for results")
    poll_amount = 0
    while not poll_runsessions_complete(task_data, args.papi_url, args.e2e_workspace):
        print("...")
        time.sleep(POLL_DURATION)
        poll_amount += 1
        if poll_amount >= MAX_POLLS:
            print(
                "CI exceeded max polls waiting for a runrequest to finish. Check the logs and investigate the runrequest."
            )
            exit(1)
    print("CI Runsession finished - collecting results...")
    print("...")
    ci_results = get_runsession_ci_results(task_data, args.papi_url, args.e2e_workspace)
    # decorate results with codebundles
    ci_results = decorate_results(args.papi_url, args.e2e_workspace, ci_results)
    # display the results and exit the script appropriately so that CI can determine the overall status
    process_results(args.e2e_workspace, ci_results)
