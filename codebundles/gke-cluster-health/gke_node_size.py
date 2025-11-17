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
from typing import List, Dict

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
    pod_names = {}  # uid -> name mapping
    try:
        data=json.loads(run(["kubectl","get","pods","-A","-o","json"]))
    except subprocess.CalledProcessError as e:
        print(f"Warning: Failed to get pods - {e}")
        return pod, node, pod_names
    
    for it in data["items"]:
        if it["status"].get("phase") not in LIVE or it["metadata"].get("deletionTimestamp"):
            continue
        uid=it["metadata"]["uid"]; nd=it["spec"].get("nodeName","UNSCHED")
        name=it["metadata"]["name"]; namespace=it["metadata"]["namespace"]
        pod_names[uid] = f"{namespace}/{name}"
        rc=rm=lc=lm=0
        for c in it["spec"]["containers"]:
            res=c.get("resources",{}); req=res.get("requests",{}); lim=res.get("limits",{})
            rc+=cpu(req.get("cpu","0"));          rm+=mem(req.get("memory","0"))
            lc+=cpu(lim.get("cpu",req.get("cpu","0"))); lm+=mem(lim.get("memory",req.get("memory","0")))
        pod[uid]={"node":nd,"rc":rc,"rm":rm,"lc":lc,"lm":lm,"name":pod_names[uid]}
        n=node[nd]; n["rc"]+=rc; n["rm"]+=rm; n["lc"]+=lc; n["lm"]+=lm; n["pods"].append(uid)
    
    print(f"Gathered {len(pod)} pods across {len([n for n in node if n != 'UNSCHED'])} nodes")
    if "UNSCHED" in node and len(node["UNSCHED"]["pods"]) > 0:
        print(f"Warning: {len(node['UNSCHED']['pods'])} unscheduled pods found")
    
    return pod,node,pod_names

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

# node_usage() removed - cluster_health.sh provides better utilization analysis

def catalogue(region):
    # Get machine types from GCP API
    mts=json.loads(run(["gcloud","compute","machine-types","list",
                        f"--filter=zone~{region}*",
                        "--format=json(name,guestCpus,memoryMb,zone)",
                        "--page-size","500","--limit","9999"]))
    cat=defaultdict(lambda:{"cpu":0,"mem":0,"zones":set()})
    
    # Filter to only include valid, current machine types suitable for GKE
    valid_prefixes = [
        "n2-standard-", "n2-highcpu-", "n2-highmem-",
        "n1-standard-", "n1-highcpu-", "n1-highmem-",
        "e2-standard-", "e2-highcpu-", "e2-highmem-",
        "c2-standard-", "c2d-standard-",
        "m1-", "m2-", "m3-",
        "t2d-standard-", "t2a-standard-"
    ]
    
    # Exclude deprecated, invalid, or problematic machine types
    invalid_types = {
        "g1-small", "f1-micro",  # Legacy types
        "g2-standard-12",  # Invalid type that sometimes appears in API
    }
    
    for m in mts:
        n=m["name"]; z=Path(m["zone"]).name
        
        # Only include valid machine types
        if (any(n.startswith(prefix) for prefix in valid_prefixes) and 
            n not in invalid_types and
            m["guestCpus"] >= 1 and m["memoryMb"] >= 1024):  # Minimum viable specs
            cat[n]["cpu"]=m["guestCpus"]; cat[n]["mem"]=m["memoryMb"]; cat[n]["zones"].add(z)
    
    return cat

issues=[]
def note(cl,sev,ttl,det,nxt, summary: str = None):
    issues.append({"severity":sev,"title":f"{ttl} in cluster `{cl}`",
                   "details":det,"next_steps":nxt, 
                   "summary": summary})

# ── per‑cluster analysis ────────────────────────────────────────────────
def analyse(cl:str, loc:str):
    flag="--region" if re.fullmatch(r"[a-z0-9-]+[0-9]$",loc) else "--zone"
    retry(["gcloud","container","clusters","get-credentials",cl,flag,loc,"--quiet"])

    pod,node,pod_names=gather_pods(); alloc=allocatable()

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
    
    # Note: Removed node count validation - GKE API reports counts inconsistently for multi-zone clusters
    # (sometimes per-zone, sometimes total) causing false positive warnings.
    # node_pool_health.sh does proper cross-validation with compute instances instead.

    valid=[n for n in node if n in alloc and alloc[n].get("ready", True)]
    unready_nodes = [n for n in alloc if not alloc[n].get("ready", True)]
    
    if unready_nodes:
        num_unready_nodes = len(unready_nodes)
        unready_node_names = ", ".join([f"`{node_nm}`" for node_nm in unready_nodes])
        
        summary = textwrap.dedent(f"""
            {num_unready_nodes} nodes ({unready_node_names}) in the `{cl}` GKE 
            cluster were detected as unready, reducing overall cluster capacity. The 
            issue indicated that the cluster was at or near capacity and might require 
            additional or healthy nodes. Recommended actions included investigating 
            node health and readiness, checking control plane and node communication, 
            and validating component health checks.""").strip()
        
        note(cl=cl,sev=2,ttl="Unready nodes detected",
             det=f"{num_unready_nodes} nodes are not ready: {', '.join(unready_nodes)}. "
             f"This reduces available cluster capacity.",
             nxt=f"Investigate node health and readiness issues in cluster `{cl}`.",
             summary = summary)
    
    if not valid:
        summary = textwrap.dedent(f"""
            The analysis for cluster `{cl}` failed due to the absence of schedulable nodes. 
            Recommended actions include checking the control plane, reviewing node taints and 
            labels, assessing resource quota utilization, and investigating recent node 
            provisioning failures in `{cl}`""").strip()

        note(cl=cl,sev=2,ttl="Analysis failed",det="No schedulable nodes found.",
             nxt="No schedulable nodes found.",
             summary = summary); return

    busiest=max(valid,key=lambda n:(node[n]['rc'],node[n]['rm']))
    a_b=alloc[busiest]; busy=node[busiest]
    
    # Ensure we have pod data to analyze
    all_pods = list(pod.values())
    if not all_pods:
        summary = textwrap.dedent(f"""
                Cluster {cl} was found with no running pods, preventing sizing analysis. 
                The issue indicated that GKE nodes were at capacity or unavailable. Recommended 
                actions included deploying workloads, verifying node health, inspecting control 
                plane events, and validating network and IAM configurations.""").strip()
            
        note(cl=cl,sev=3,ttl="No pods found",
             det=f"No pods found in cluster `{cl}`. Cannot perform sizing analysis.",
             nxt=f"Deploy workloads to cluster `{cl}` for meaningful analysis.",
             summary = summary)
        return
    
    biggest=max(all_pods, key=lambda p:(p["rc"],p["rm"]))

    pr=lambda v:f"{v:6.1f}%"
    print(textwrap.dedent(f"""
    =============================================================================
    Cluster `{cl}`   Location `{loc}`   {ctype}
    -----------------------------------------------------------------------------
    Largest pod : `{biggest['name']}`  {biggest['rc']}m / {biggest['rm']}MiB

    Busiest node: `{busiest}`  (type {a_b['type']})
      Requests : {busy['rc']}m ({pr(busy['rc']/a_b['cpu']*100)})   {busy['rm']}MiB ({pr(busy['rm']/a_b['mem']*100)})
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
        overloaded_node_names = ", ".join([f"`{node_nm}`" for node_nm in overloaded])

        summary = textwrap.dedent(f"""
            The `{cl}` experienced capacity issues where {overloaded_node_names} exceeded 
            their allocatable resource limits, leading to an overloaded state. This indicated 
            that the cluster had insufficient available node capacity to handle current workloads 
            effectively. Investigations focused on optimizing workload distribution, reviewing 
            recent deployment impacts, and validating resource quotas and limits to prevent 
            future overutilization.""").strip()
        
        note(cl=cl,sev=2,ttl="Node overloaded",
             det=f"{len(overloaded)} nodes exceed requests allocatable: {', '.join(overloaded)}.",
             nxt=f"Reschedule pods or scale the pool in cluster `{cl}`.",
             summary = summary)

    # ── limits over‑commit table ────────────────────────────────────────
    limit_over=[]
    for n in valid:
        a=alloc[n]; d=node[n]
        if (d["lc"]/a["cpu"]>MAX_CPU_LIMIT_OVERCOMMIT or
            d["lm"]/a["mem"]>MAX_MEM_LIMIT_OVERCOMMIT):
            limit_over.append(n)
    if limit_over:
        num_limit_over = len(limit_over)
        limit_over_nodes_str = ", ".join([f'`{node_nm}`' for node_nm in limit_over])

        summary = textwrap.dedent(f"""
            {num_limit_over} nodes in cluster `{cl}` are over-committed, exceeding CPU and 
            memory thresholds, which has resulted in the cluster reaching capacity and 
            lacking available nodes. The expected state is for the GKE cluster to have 
            available nodes, but currently, additional resources or adjustments are needed. 
            Recommended actions include lowering pod limits, splitting workloads, or 
            scaling the node pool; no comments were provided and no resolving task is noted.
        """).strip()

        note(cl=cl,sev=2,ttl="Node limits over-committed",
             det=(f"{num_limit_over} nodes beyond limit thresholds "
              f"(>{MAX_CPU_LIMIT_OVERCOMMIT}× CPU or "
              f">{MAX_MEM_LIMIT_OVERCOMMIT}× MEM): {', '.join(limit_over)}."),
             nxt="Lower pod limits, split workload or scale the node-pool.",
             summary = summary)

    # Skip rescheduling hint calculation - cluster_health.sh handles capacity analysis

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

    # ── intelligent sizing section ──────────────────────────────────────
    # Get current node specifications for comparison
    current_node_cpu = a_b['cpu']  # Current node allocatable CPU in millicores
    current_node_mem = a_b['mem']  # Current node allocatable memory in MiB
    
    # Get actual machine type specs from catalogue (not allocatable)
    cat=catalogue(region)
    current_machine_type = a_b['type']
    current_machine_specs = cat.get(current_machine_type, {"cpu": current_node_cpu // 1000, "mem": current_node_mem})
    actual_current_vcpu = current_machine_specs['cpu']  # Actual vCPU count from machine type
    
    # Calculate sizing based on largest pod requirements (not busiest node's total workload)
    # The goal is to ensure the machine type can handle individual pods, not to fit entire node workload on one machine
    
    # Minimum based on largest single pod with headroom
    pod_based_cpu = math.ceil(biggest['rc'] * 1.5)  # 50% headroom for largest pod
    pod_based_mem = math.ceil(biggest['rm'] * 1.5)  # 50% headroom for largest pod
    
    # Also consider if current node type can handle typical workload density
    # Use average pod size from busiest node as a proxy for typical density
    avg_pod_cpu = busy['rc'] // max(len(busy['pods']), 1) if len(busy['pods']) > 0 else biggest['rc']
    avg_pod_mem = busy['rm'] // max(len(busy['pods']), 1) if len(busy['pods']) > 0 else biggest['rm']
    
    # Node should comfortably fit 3-5 average pods (with headroom)
    density_based_cpu = math.ceil(avg_pod_cpu * 4)  # 4 average pods
    density_based_mem = math.ceil(avg_pod_mem * 4)
    
    # Choose the larger of: biggest pod requirement OR typical density requirement
    need_cpu = max(pod_based_cpu, density_based_cpu)
    need_mem = max(pod_based_mem, density_based_mem)
    
    # Don't recommend smaller nodes than current unless there's a compelling reason
    min_recommended_cpu = max(need_cpu, current_node_cpu // 2)  # At least half current CPU
    min_recommended_mem = max(need_mem, current_node_mem // 2)  # At least half current memory
    
    # If current utilization is very low, allow smaller recommendations
    cpu_utilization = (busy['rc'] / current_node_cpu) * 100
    mem_utilization = (busy['rm'] / current_node_mem) * 100
    
    if cpu_utilization < 30 and mem_utilization < 30:
        # Very low utilization - allow smaller nodes
        min_recommended_cpu = need_cpu
        min_recommended_mem = need_mem
        sizing_reason = "Low utilization allows downsizing"
    elif cpu_utilization > 70 or mem_utilization > 70:
        # High utilization - recommend larger nodes
        min_recommended_cpu = max(need_cpu, current_node_cpu)
        min_recommended_mem = max(need_mem, current_node_mem)
        sizing_reason = "High utilization requires maintaining or increasing capacity"
    else:
        # Moderate utilization - be conservative
        sizing_reason = "Moderate utilization suggests maintaining similar capacity"

    # cat already loaded above, just use it
    mts=[{"name":n,"cpu":v["cpu"],"mem":v["mem"],"zones":v["zones"]} for n,v in cat.items()]
    fits=[m for m in mts if zones.issubset(m["zones"]) and m["cpu"]*1000>=min_recommended_cpu and m["mem"]>=min_recommended_mem] \
         or [m for m in mts if m["cpu"]*1000>=min_recommended_cpu and m["mem"]>=min_recommended_mem]

    try:
        fits.sort(key=lambda m:(m["cpu"],m["mem"])); best=fits[0]
        zones_n=len(zones); cap_cpu,cap_mem=best["cpu"]*1000,best["mem"]
        
        # Calculate minimum nodes needed based on resource requirements
        min_nodes_cpu = math.ceil(min_recommended_cpu / cap_cpu)
        min_nodes_mem = math.ceil(min_recommended_mem / cap_mem)
        min_nodes_required = max(min_nodes_cpu, min_nodes_mem, 1)
        
        # Get current node pool information for realistic autoscaler sizing
        current_nodes = cur_nodes
        
        # Calculate realistic autoscaler bounds based on current usage and headroom
        if cpu_utilization < 30 and mem_utilization < 30:
            # Low utilization - can scale down
            suggested_min = max(min_nodes_required, math.ceil(current_nodes * 0.5))
            suggested_max = max(suggested_min * 2, current_nodes)
        elif cpu_utilization > 70 or mem_utilization > 70:
            # High utilization - need more capacity
            suggested_min = max(min_nodes_required, current_nodes)
            suggested_max = max(suggested_min * 2, math.ceil(current_nodes * 1.5))
        else:
            # Moderate utilization - maintain similar capacity
            suggested_min = max(min_nodes_required, math.ceil(current_nodes * 0.8))
            suggested_max = max(suggested_min, math.ceil(current_nodes * 1.2))
        
        # For regional clusters, distribute across zones
        if ctype == "REGIONAL" and zones_n > 1:
            min_per_zone = math.ceil(suggested_min / zones_n)
            max_per_zone = math.ceil(suggested_max / zones_n)
            autoscaler_desc = f"{min_per_zone}-{max_per_zone} per zone (total: {min_per_zone * zones_n}-{max_per_zone * zones_n})"
            min_n, max_n = min_per_zone, max_per_zone
        else:
            autoscaler_desc = f"{suggested_min}-{suggested_max} total"
            min_n, max_n = suggested_min, suggested_max

        print(f"\nSIZING ANALYSIS:")
        print(f"Current node: {a_b['type']} ({actual_current_vcpu} vCPU, allocatable: {current_node_cpu}m CPU / {current_node_mem} MiB RAM)")
        print(f"Current nodes: {current_nodes}")
        print(f"Largest pod: {biggest['rc']}m CPU, {biggest['rm']} MiB RAM")
        print(f"Average pod on busiest node: {avg_pod_cpu}m CPU, {avg_pod_mem} MiB RAM")
        print(f"Busiest node utilization: {cpu_utilization:.1f}% CPU | {mem_utilization:.1f}% Memory")
        print(f"Sizing reason: {sizing_reason}")
        print(f"Recommended node capacity: {min_recommended_cpu}m CPU, {min_recommended_mem} MiB memory")
        
        # Only recommend a different machine type if it makes sense
        recommended_cpu_cores = best['cpu']
        
        if (recommended_cpu_cores == actual_current_vcpu and 
            abs(best['mem'] - current_machine_specs['mem']) < (current_machine_specs['mem'] * 0.2)):
            # Very similar specs - don't recommend change or create issue
            print(f"\n{EMO['OK']}  Current machine type `{a_b['type']}` is appropriate")
            print(f"No machine type change recommended - current specs are suitable")
            # Don't create an issue when no action is needed
        else:
            print(f"\n{EMO['NODE']}  *** RECOMMENDED NODE: {best['name']} "
                  f"(vCPU {best['cpu']}, Mem {best['mem']}MiB) ***")
            print(f"Suggested autoscaler: {autoscaler_desc}")
            print("\nOther machine types that also fit (top 5):")
            for m in fits[:5]:
                mark = "← recommended" if m is best else ""
                print(f"{m['name']:<20} {m['cpu']:>4} vCPU {m['mem']:>6} MiB {mark}")
            print()

            # Provide better context in the issue
            # Only create issue if change is significant (>20% difference)
            size_change_pct = abs(best['cpu'] - actual_current_vcpu) / actual_current_vcpu * 100 if actual_current_vcpu > 0 else 100
            
            if size_change_pct > 20:
                comparison = ""
                if best['cpu'] > actual_current_vcpu:
                    comparison = f"Upgrade from {actual_current_vcpu} to {best['cpu']} vCPU ({size_change_pct:.0f}% increase)"
                elif best['cpu'] < actual_current_vcpu:
                    comparison = f"Optimize from {actual_current_vcpu} to {best['cpu']} vCPU ({size_change_pct:.0f}% reduction)"
                else:
                    comparison = f"Maintain {best['cpu']} vCPU with better memory ratio"

                summary = textwrap.dedent(f"""Moderate utilization was observed in cluster `{cl}`, 
                    indicating an opportunity to optimize node-pool sizing by transitioning to `{best['name']}` 
                    nodes (optimize from {actual_current_vcpu} to {best['cpu']} vCPU)""").strip()

                # Severity=4 (informational) since this is optimization, not a critical issue
                note(cl=cl, sev=4, ttl="Node‑pool sizing optimization opportunity",
                     det=f"Consider `{best['name']}` in `{cl}` ({comparison}); autoscaler {autoscaler_desc}. {sizing_reason}.",
                     nxt=f"Create new node pool with `{best['name']}` and migrate workloads from current pool in `{cl}`",
                     summary=summary
                     )
            else:
                print(f"Note: Recommended type very similar to current - no change needed")

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
