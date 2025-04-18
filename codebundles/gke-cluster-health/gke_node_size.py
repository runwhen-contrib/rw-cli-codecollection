#!/usr/bin/env python3
"""
gke_node_size.py — usage‑aware node‑sizer with inline debug prints
2025‑04‑18 • grouped “node‑overloaded” issues
"""

from __future__ import annotations
import json, math, os, re, subprocess, sys, textwrap, time, traceback
from collections import defaultdict
from pathlib import Path

HEADROOM_CPU, HEADROOM_MEM, MIN_HEADROOM_NODES = 1.25, 1.10, 3
EMO = {"OK": "✅", "ERR": "⚠️", "RES": "🔄", "NODE": "🆕"}

workdir_path = os.getenv("CODEBUNDLE_TEMP_DIR", ".")  
issues_file  = os.path.join(workdir_path, "node_size_issues.json")


# ───────────────────────── helpers ──────────────────────────
def run(cmd): return subprocess.check_output(cmd, text=True)

def retry(cmd, n=3, d=5):
    for i in range(n):
        try:
            return run(cmd)
        except subprocess.CalledProcessError:
            if i == n - 1: raise
            time.sleep(d); d *= 2

def cpu(v): return int(v[:-1]) if v.endswith("m") else int(float(v) * 1000)

_FACT = {"Ki": 1/1024, "Mi": 1, "Gi": 1024, "Ti": 1024**2,
         "K": 1/(1024/1000), "M": 1000**2/1024**2, "G": 1000**3/1024**2}
def mem(v):
    for s,f in _FACT.items():
        if v.endswith(s):
            return int(float(v[:-len(s)])*f)
    return int(int(v)/1_048_576)

# ───────────────────── cluster snapshots ────────────────────
LIVE = {"Running","Pending","Unknown"}
def gather_pods():
    pod,node={},defaultdict(lambda:{"rc":0,"rm":0,"lc":0,"lm":0,"pods":[]})
    data=json.loads(run(["kubectl","get","pods","-A","-o","json"]))
    for it in data["items"]:
        if it["status"].get("phase") not in LIVE or it["metadata"].get("deletionTimestamp"):
            continue
        uid=it["metadata"]["uid"]; nd=it["spec"].get("nodeName","UNSCHED")
        rc=rm=lc=lm=0
        for c in it["spec"]["containers"]:
            res=c.get("resources",{}); req=res.get("requests",{}); lim=res.get("limits",{})
            rc+=cpu(req.get("cpu","0")); rm+=mem(req.get("memory","0"))
            lc+=cpu(lim.get("cpu",req.get("cpu","0"))); lm+=mem(lim.get("memory",req.get("memory","0")))
        pod[uid]={"node":nd,"rc":rc,"rm":rm,"lc":lc,"lm":lm}
        n=node[nd]; n["rc"]+=rc; n["rm"]+=rm; n["lc"]+=lc; n["lm"]+=lm; n["pods"].append(uid)
    return pod,node

def allocatable():
    data=json.loads(run(["kubectl","get","nodes","-o","json"]))
    out={}
    for n in data["items"]:
        lbl=n["metadata"]["labels"]
        t=lbl.get("node.kubernetes.io/instance-type",
                  lbl.get("beta.kubernetes.io/instance-type","unknown"))
        a=n["status"]["allocatable"]
        out[n["metadata"]["name"]]={"cpu":cpu(a["cpu"]+"m" if "m" not in a["cpu"] else a["cpu"]),
                                    "mem":mem(a["memory"]),"type":t}
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

# ───────────────── per‑cluster analysis ────────────────────
def analyse(cl, loc):
    flag="--region" if re.fullmatch(r"[a-z0-9-]+[0-9]$",loc) else "--zone"
    retry(["gcloud","container","clusters","get-credentials",cl,flag,loc,"--quiet"])

    pod,node=gather_pods(); alloc=allocatable(); usage=node_usage()

    meta=json.loads(run(["gcloud","container","clusters","describe",cl,flag,loc,
                         "--format=json(locations,locationType)"]))
    zones=set(meta.get("locations",[loc])); ctype=meta.get("locationType") or ("REGIONAL" if len(zones)>1 else "ZONAL")
    region=loc[:-2] if flag=="--zone" else loc

    valid=[n for n in node if n in alloc]
    if not valid:
        note(cl,2,"Analysis failed","No schedulable nodes found.",
             f"Check control plane for `{cl}`."); return

    busiest=max(valid,key=lambda n:(node[n]['rc'],node[n]['rm']))
    a_b=alloc[busiest]; busy=node[busiest]; use_b=usage.get(busiest,{"cpu":0,"mem":0})
    biggest=max(pod.values(), key=lambda p:(p["rc"],p["rm"]))

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

    # oversized nodes table …
    over=[]
    for n in valid:
        a=alloc[n]; d=node[n]
        if d['rc']>a['cpu'] or d['rm']>a['mem'] or d['lc']>a['cpu'] or d['lm']>a['mem']:
            uc=usage.get(n,{}).get("cpu"); um=usage.get(n,{}).get("mem")
            over.append((n,d['rc']/a['cpu'],d['rm']/a['mem'],
                         d['lc']/a['cpu'],d['lm']/a['mem'],
                         None if uc is None else uc/a['cpu'],
                         None if um is None else um/a['mem']))
    if over:
        w=min(max(len(n) for n,*_ in over)+2,60)
        print("\nNodes exceeding allocatable:")
        print("NAME".ljust(w)+"ReqCPU% ReqMEM% LimCPU% LimMEM% UseCPU% UseMEM%")
        for n,rc,rm,lc,lm,uc,um in over:
            uc_s="--" if uc is None else f"{uc*100:6.0f}%"
            um_s="--" if um is None else f"{um*100:6.0f}%"
            print(f"{n:<{w}} {rc*100:6.0f}% {rm*100:6.0f}% "
                  f"{lc*100:6.0f}% {lm*100:6.0f}% {uc_s:>6} {um_s:>6}")

        # NEW: single grouped issue entry
        nodes_list = ", ".join(n for n,*_ in over)
        note(cl,2,"Node overloaded",
             f"{len(over)} nodes exceed allocatable: {nodes_list}.",
             f"Reschedule pods or scale the pool in cluster `{cl}`.")

    # head‑room check
    nodes_ok=sum(1 for n,a in alloc.items()
                 if n in usage
                 and all((a["cpu"]-node[n]["rc"]>=biggest["rc"],
                          a["mem"]-node[n]["rm"]>=biggest["rm"],
                          a["cpu"]-usage[n]["cpu"]>=biggest["rc"],
                          a["mem"]-usage[n]["mem"]>=biggest["rm"])))
    resched_hint=nodes_ok>=MIN_HEADROOM_NODES

    # autoscaling info
    pools=json.loads(run(["gcloud","container","node-pools","list",
                          "--cluster",cl,flag,loc,
                          "--format=json(name,config.machineType,currentNodeCount,initialNodeCount,autoscaling)"]))
    cur_pool=next((p for p in pools if p["config"]["machineType"]==a_b["type"]),pools[0])
    cur_nodes=cur_pool.get("currentNodeCount") or cur_pool["initialNodeCount"]
    max_nodes=cur_pool["autoscaling"]["maxNodeCount"]
    can_scale=cur_nodes < max_nodes

    print(f"\n{EMO['RES']}  Pool can scale out ({cur_nodes}/{max_nodes}) — larger node options follow.\n"
          if can_scale else
          f"\n{EMO['RES']}  Pool already at max ({cur_nodes}/{max_nodes}); a larger node is required.\n")

    # sizing section
    need_cpu=int(max(busy['rc'],biggest['rc'],use_b['cpu'])*HEADROOM_CPU)
    need_mem=int(max(busy['rm'],biggest['rm'],use_b['mem'])*HEADROOM_MEM)

    cat=catalogue(region)
    mts=[{"name":n,"cpu":v["cpu"],"mem":v["mem"],"zones":v["zones"]} for n,v in cat.items()]
    fits=[m for m in mts if zones.issubset(m["zones"]) and m["cpu"]*1000>=need_cpu and m["mem"]>=need_mem] \
         or [m for m in mts if m["cpu"]*1000>=need_cpu and m["mem"]>=need_mem]

    try:
        fits.sort(key=lambda m:(m["cpu"],m["mem"]))
        best=fits[0]

        zones_n=len(zones)
        cap_cpu,cap_mem=best["cpu"]*1000, best["mem"]
        total=max(math.ceil(busy['rc']/cap_cpu), math.ceil(busy['rm']/cap_mem), 3)

        if ctype == "REGIONAL":
            per_zone = math.ceil(total / zones_n)
            min_n, max_n = per_zone, per_zone*3
        else:
            min_n, max_n = total, total*3

        print(f"{EMO['NODE']}  *** RECOMMENDED NODE: {best['name']} (vCPU {best['cpu']}, Mem {best['mem']}MiB) ***")
        print(f"Suggested autoscaler {min_n}-{max_n} ({'per zone' if ctype=='REGIONAL' else 'total'})\n")
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

# ─────────────────────────  main  ──────────────────────────
if __name__=="__main__":
    proj=os.getenv("CLOUDSDK_CORE_PROJECT") or os.getenv("GCP_PROJECT_ID")
    if not proj:
        sys.exit("Set CLOUDSDK_CORE_PROJECT or GCP_PROJECT_ID")
    clusters=json.loads(run(["gcloud","container","clusters","list",
                             "--project",proj,"--format=json(name,location,status)"]))
    for c in clusters:
        try:
            analyse(c["name"], c["location"])
        except Exception as e:
            traceback.print_exc()
            note(c["name"],2,"Analysis failed",
                 f"{type(e).__name__}: {e}",
                 f"Debug cluster `{c['name']}`.")
    with open(f"{issues_file}","w") as fp:
        json.dump(issues, fp, indent=2)
    print(f"\n{EMO['OK']}  issues.json written with {len(issues)} entries\n")
