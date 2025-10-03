#!/usr/bin/env python3
"""
gke_node_size.py — node‑sizer & over‑commit analyser
2025‑04‑18   •   grouped "node‑overloaded" issues + limit‑overcommit checks

What's new?
────────────
▸ still raises **Node overloaded** when requests exceed allocatable  
▸ now also raises **Node limits over‑committed** when *limits / allocatable*
  is above the tunables below  
▸ sizing logic is driven by the **worst‑case limits** (no extra head‑room)  
"""

from __future__ import annotations
import json, math, os, re, subprocess, sys, textwrap, time, traceback
from collections import defaultdict
from pathlib import Path

# ── tunables ────────────────────────────────────────────────────────────
MAX_CPU_LIMIT_OVERCOMMIT = float(os.getenv("MAX_CPU_LIMIT_OVERCOMMIT", "3.0"))  # 300 %
MAX_MEM_LIMIT_OVERCOMMIT = float(os.getenv("MAX_MEM_LIMIT_OVERCOMMIT", "1.5"))  # 150 %
MIN_HEADROOM_NODES       = 3          # unchanged – for "can I just reschedule?"
EMO = {"OK":"✅","ERR":"⚠️","RES":"🔄","NODE":"🆕"}

workdir_path = os.getenv("CODEBUNDLE_TEMP_DIR", ".")
issues_file  = os.path.join(workdir_path, "node_size_issues.json")

# ── helpers ─────────────────────────────────────────────────────────────
def run(cmd:list[str]) -> str: return subprocess.check_output(cmd, text=True)

def retry(cmd:list[str], n=3, d=5):
    for i in range(n):
        try: return run(cmd)
        except subprocess.CalledProcessError:
            if i == n-1: raise
            time.sleep(d); d *= 2

def cpu(v:str)->int: return int(v[:-1]) if v.endswith("m") else int(float(v)*1000)

_FACT={"Ki":1/1024,"Mi":1,"Gi":1024,"Ti":1024**2,
       "K":1/(1024/1000),"M":1000**2/1024**2,"G":1000**3/1024**2}
def mem(v:str)->int:
    for s,f in _FACT.items():
        if v.endswith(s): return int(float(v[:-len(s)])*f)
    return int(int(v)/1_048_576)

# ── cluster snapshots ───────────────────────────────────────────────────
LIVE={"Running","Pending","Unknown"}
def gather_pods():
    pod,node={},defaultdict(lambda:{"rc":0,"rm":0,"lc":0,"lm":0,"pods":[]})
    try:
        data=json.loads(run(["kubectl","get","pods","-A","-o","json"]))
    except subprocess.CalledProcessError as e:
        print(f"Warning: Failed to get pods - {e}")
        return pod, node
    
    for it in data["items"]:
        if it["status"].get("phase") not in LIVE or it["metadata"].get("deletionTimestamp"):
            continue
        uid=it["metadata"]["uid"]; nd=it["spec"].get("nodeName","UNSCHED")
        rc=rm=lc=lm=0
        for c in it["spec"]["containers"]:
            res=c.get("resources",{}); req=res.get("requests",{}); lim=res.get("limits",{})
            rc+=cpu(req.get("cpu","0"));          rm+=mem(req.get("memory","0"))
            lc+=cpu(lim.get("cpu",req.get("cpu","0"))); lm+=mem(lim.get("memory",req.get("memory","0")))
        pod[uid]={"node":nd,"rc":rc,"rm":rm,"lc":lc,"lm":lm}
        n=node[nd]; n["rc"]+=rc; n["rm"]+=rm; n["lc"]+=lc; n["lm"]+=lm; n["pods"].append(uid)
    
    print(f"Gathered {len(pod)} pods across {len([n for n in node if n != 'UNSCHED'])} nodes")
    if "UNSCHED" in node and len(node["UNSCHED"]["pods"]) > 0:
        print(f"Warning: {len(node['UNSCHED']['pods'])} unscheduled pods found")
    
    return pod,node

def allocatable():
    try:
        data=json.loads(run(["kubectl","get","nodes","-o","json"]))
    except subprocess.CalledProcessError as e:
        print(f"Warning: Failed to get nodes - {e}")
        return {}
    
    out={}
    for n in data["items"]:
        node_name = n["metadata"]["name"]
        
        # Check node conditions for readiness
        conditions = n.get("status", {}).get("conditions", [])
        ready_condition = next((c for c in conditions if c["type"] == "Ready"), None)
        if ready_condition and ready_condition["status"] != "True":
            print(f"Warning: Node {node_name} is not ready - {ready_condition.get('reason', 'Unknown')}")
        
        lbl=n["metadata"]["labels"]
        t=lbl.get("node.kubernetes.io/instance-type",
                  lbl.get("beta.kubernetes.io/instance-type","unknown"))
        
        # Get node taints that might affect scheduling
        taints = n.get("spec", {}).get("taints", [])
        if taints:
            taint_effects = [taint.get("effect", "Unknown") for taint in taints]
            if "NoSchedule" in taint_effects or "NoExecute" in taint_effects:
                print(f"Warning: Node {node_name} has scheduling taints: {taint_effects}")
        
        a=n["status"]["allocatable"]
        out[node_name]={
            "cpu":cpu(a["cpu"]+"m" if "m" not in a["cpu"] else a["cpu"]),
            "mem":mem(a["memory"]), "type":t,
            "ready": ready_condition["status"] == "True" if ready_condition else False}
    
    print(f"Found {len(out)} total nodes")
    ready_nodes = sum(1 for node_data in out.values() if node_data.get("ready", False))
    print(f"{ready_nodes}/{len(out)} nodes are ready")
    
    return out

def node_usage():
    try: raw=run(["kubectl","top","nodes","--no-headers"])
    except subprocess.CalledProcessError: return {}
    u={}
    for l in raw.strip().splitlines():
        f=l.split(); n=f[0]
        cpu_v=next((x for x in f[1:] if x.endswith("m")),None)
        mem_v=next((x for x in f[1:] if x.endswith(("Ki","Mi","Gi"))),None)
        if cpu_v and mem_v: u[n]={"cpu":cpu(cpu_v),"mem":mem(mem_v)}
    return u

def catalogue(region):
    mts=json.loads(run(["gcloud","compute","machine-types","list",
                        f"--filter=zone~{region}*",
                        "--format=json(name,guestCpus,memoryMb,zone)",
                        "--page-size","500","--limit","9999"]))
    cat=defaultdict(lambda:{"cpu":0,"mem":0,"zones":set()})
    for m in mts:
        n=m["name"]; z=Path(m["zone"]).name
        cat[n]["cpu"]=m["guestCpus"]; cat[n]["mem"]=m["memoryMb"]; cat[n]["zones"].add(z)
    return cat

issues=[]
def note(cl,sev,ttl,det,nxt):
    issues.append({"severity":sev,"title":f"{ttl} in cluster `{cl}`",
                   "details":det,"next_steps":nxt})

# ── per‑cluster analysis ────────────────────────────────────────────────
def analyse(cl:str, loc:str):
    flag="--region" if re.fullmatch(r"[a-z0-9-]+[0-9]$",loc) else "--zone"
    retry(["gcloud","container","clusters","get-credentials",cl,flag,loc,"--quiet"])

    pod,node=gather_pods(); alloc=allocatable(); usage=node_usage()

    meta=json.loads(run(["gcloud","container","clusters","describe",cl,flag,loc,
                         "--format=json(locations,locationType)"]))
    zones=set(meta.get("locations",[loc])); ctype=meta.get("locationType") or ("REGIONAL" if len(zones)>1 else "ZONAL")
    region=loc[:-2] if flag=="--zone" else loc

    # Cross-validate nodes from different sources
    kubectl_nodes = set(alloc.keys())
    scheduled_nodes = set(n for n in node if n != "UNSCHED" and n in alloc)
    
    # Check for discrepancies
    if len(kubectl_nodes) != len(scheduled_nodes):
        print(f"Warning: Node count mismatch - kubectl found {len(kubectl_nodes)} nodes, "
              f"but only {len(scheduled_nodes)} have scheduled pods")
        missing_nodes = kubectl_nodes - scheduled_nodes
        if missing_nodes:
            print(f"Nodes without scheduled pods: {missing_nodes}")
    
    # Validate against expected node pools
    try:
        pools_info = json.loads(run(["gcloud","container","node-pools","list",
                                    "--cluster",cl,flag,loc,
                                    "--format=json(name,currentNodeCount,initialNodeCount)"]))
        expected_total_nodes = sum(p.get("currentNodeCount", p.get("initialNodeCount", 0)) for p in pools_info)
        print(f"Expected nodes from node pools: {expected_total_nodes}, Found: {len(kubectl_nodes)}")
        if expected_total_nodes != len(kubectl_nodes):
            note(cl,2,"Node count mismatch",
                 f"Expected {expected_total_nodes} nodes from node pools but found {len(kubectl_nodes)} nodes. "
                 f"This may indicate nodes failed to join the cluster or are stuck in provisioning.",
                 f"Check GCP Console for node pool status and instance health in cluster `{cl}`.")
    except subprocess.CalledProcessError:
        print("Warning: Could not verify node pool information")

    valid=[n for n in node if n in alloc and alloc[n].get("ready", True)]
    unready_nodes = [n for n in alloc if not alloc[n].get("ready", True)]
    
    if unready_nodes:
        note(cl,2,"Unready nodes detected",
             f"{len(unready_nodes)} nodes are not ready: {', '.join(unready_nodes)}. "
             f"This reduces available cluster capacity.",
             f"Investigate node health and readiness issues in cluster `{cl}`.")
    
    if not valid:
        note(cl,2,"Analysis failed","No schedulable nodes found.",
             f"Check control plane for `{cl}`."); return

    busiest=max(valid,key=lambda n:(node[n]['rc'],node[n]['rm']))
    a_b=alloc[busiest]; busy=node[busiest]; use_b=usage.get(busiest,{"cpu":0,"mem":0})
    
    # Ensure we have pod data to analyze
    all_pods = list(pod.values())
    if not all_pods:
        note(cl,3,"No pods found",
             f"No pods found in cluster `{cl}`. Cannot perform sizing analysis.",
             f"Deploy workloads to cluster `{cl}` for meaningful analysis.")
        return
    
    biggest=max(all_pods, key=lambda p:(p["rc"],p["rm"]))

    pr=lambda v:f"{v:6.1f}%"
    print(textwrap.dedent(f"""
    =============================================================================
    Cluster `{cl}`   Location `{loc}`   {ctype}
    -----------------------------------------------------------------------------
    Largest pod : `{biggest['node']}`  {biggest['rc']}m / {biggest['rm']}MiB

    Busiest node: `{busiest}`  (type {a_b['type']})
      Requests : {busy['rc']}m ({pr(busy['rc']/a_b['cpu']*100)})   {busy['rm']}MiB ({pr(busy['rm']/a_b['mem']*100)})
      Usage    : {use_b['cpu']}m ({pr(use_b['cpu']/a_b['cpu']*100)})   {use_b['mem']}MiB ({pr(use_b['mem']/a_b['mem']*100)})
      Limits   : {busy['lc']}m ({pr(busy['lc']/a_b['cpu']*100)})   {busy['lm']}MiB ({pr(busy['lm']/a_b['mem']*100)})
      Pods     : {len(busy['pods'])}
    """).rstrip())

    # ── requests‑overloaded table ───────────────────────────────────────
    overloaded=[]
    for n in valid:
        a=alloc[n]; d=node[n]
        if d['rc']>a['cpu'] or d['rm']>a['mem']:
            overloaded.append(n)
    if overloaded:
        note(cl,2,"Node overloaded",
             f"{len(overloaded)} nodes exceed requests allocatable: {', '.join(overloaded)}.",
             f"Reschedule pods or scale the pool in cluster `{cl}`.")

    # ── limits over‑commit table ────────────────────────────────────────
    limit_over=[]
    for n in valid:
        a=alloc[n]; d=node[n]
        if (d["lc"]/a["cpu"]>MAX_CPU_LIMIT_OVERCOMMIT or
            d["lm"]/a["mem"]>MAX_MEM_LIMIT_OVERCOMMIT):
            limit_over.append(n)
    if limit_over:
        note(cl,2,"Node limits over‑committed",
             (f"{len(limit_over)} nodes beyond limit thresholds "
              f"(>{MAX_CPU_LIMIT_OVERCOMMIT}× CPU or "
              f">{MAX_MEM_LIMIT_OVERCOMMIT}× MEM): {', '.join(limit_over)}."),
             "Lower pod limits, split workload or scale the node‑pool.")

    # can we just reschedule?
    nodes_ok=sum(1 for n,a in alloc.items()
                 if n in usage
                 and a["cpu"]-usage[n]["cpu"]>=biggest["rc"]
                 and a["mem"]-usage[n]["mem"]>=biggest["rm"])
    resched_hint=nodes_ok>=MIN_HEADROOM_NODES

    # ── pool / autoscaler info ──────────────────────────────────────────
    pools=json.loads(run(["gcloud","container","node-pools","list",
                          "--cluster",cl,flag,loc,
                          "--format=json(name,config.machineType,currentNodeCount,initialNodeCount,autoscaling)"]))
    cur_pool=next((p for p in pools if p["config"]["machineType"]==a_b["type"]),pools[0])
    cur_nodes=cur_pool.get("currentNodeCount") or cur_pool["initialNodeCount"]
    max_nodes=cur_pool.get("autoscaling", {}).get("maxNodeCount", cur_nodes)
    can_scale=cur_nodes<max_nodes
    print(f"\n{EMO['RES']}  Pool can scale out ({cur_nodes}/{max_nodes}) — larger node options follow.\n"
          if can_scale else
          f"\n{EMO['RES']}  Pool already at max ({cur_nodes}/{max_nodes}); a larger node is required.\n")

    # ── sizing section (driven by *limits*, not head‑room) ──────────────
    need_cpu = math.ceil(busy['lc'] / MAX_CPU_LIMIT_OVERCOMMIT)
    need_mem = math.ceil(busy['lm'] / MAX_MEM_LIMIT_OVERCOMMIT)


    cat=catalogue(region)
    mts=[{"name":n,"cpu":v["cpu"],"mem":v["mem"],"zones":v["zones"]} for n,v in cat.items()]
    fits=[m for m in mts if zones.issubset(m["zones"]) and m["cpu"]*1000>=need_cpu and m["mem"]>=need_mem] \
         or [m for m in mts if m["cpu"]*1000>=need_cpu and m["mem"]>=need_mem]

    try:
        fits.sort(key=lambda m:(m["cpu"],m["mem"])); best=fits[0]
        zones_n=len(zones); cap_cpu,cap_mem=best["cpu"]*1000,best["mem"]
        total=max(math.ceil(need_cpu/cap_cpu), math.ceil(need_mem/cap_mem), 3)
        if ctype=="REGIONAL":
            per_zone=math.ceil(total/zones_n); min_n,max_n=per_zone,per_zone*3
        else:
            min_n,max_n=total,total*3

        print(f"{EMO['NODE']}  *** RECOMMENDED NODE: {best['name']} "
              f"(vCPU {best['cpu']}, Mem {best['mem']}MiB) ***")
        print(f"Suggested autoscaler {min_n}-{max_n}"
              f" ({'per zone' if ctype=='REGIONAL' else 'total'})\n")
        print("Other machine types that also fit (top 10):")
        for m in fits[:10]:
            mark="← recommended" if m is best else ""
            print(f"{m['name']:<20} {m['cpu']:>4} {m['mem']:<8}{mark}")
        print()

        note(cl,3,"Node‑pool sizing recommendation",
             f"Use `{best['name']}` in `{cl}`; autoscaler {min_n}-{max_n}.",
             f"Cordon, drain and delete old nodes in `{cl}`; move workload to new pool.")

    except Exception as exc:
        traceback.print_exc()
        note(cl,2,"Sizing failed",
             f"{type(exc).__name__}: {exc}",
             f"See debug log for cluster `{cl}`.")

# ── main ────────────────────────────────────────────────────────────────
if __name__=="__main__":
    proj=os.getenv("CLOUDSDK_CORE_PROJECT") or os.getenv("GCP_PROJECT_ID")
    if not proj: sys.exit("Set CLOUDSDK_CORE_PROJECT or GCP_PROJECT_ID")
    clusters=json.loads(run(["gcloud","container","clusters","list",
                             "--project",proj,"--format=json(name,location,status)"]))
    for c in clusters:
        try: analyse(c["name"], c["location"])
        except Exception as e:
            traceback.print_exc()
            note(c["name"],2,"Analysis failed",
                 f"{type(e).__name__}: {e}",
                 f"Debug cluster `{c['name']}`.")
    with open(issues_file,"w") as fp: json.dump(issues, fp, indent=2)
    print(f"\n{EMO['OK']}  issues.json written with {len(issues)} entries\n")
