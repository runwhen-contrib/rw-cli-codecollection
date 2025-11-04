#!/usr/bin/env python3
"""
Main Templated Issue metadata Generation library class

Author: akshayrw25
"""

import os
import glob
from typing import List, Union, Set

import textwrap

from robot.api.deco import keyword, library
from robot.api import logger


@library(scope='GLOBAL', auto_keywords=True, doc_format='reST')
class IssueMetadataGenerator:
    """"""

    def __init__(self):
        self.ROBOT_LIBRARY_SCOPE = 'GLOBAL'
    
    @keyword
    def generate_issue_metadata(self, cb_name: str, task_id_str: str, **kwargs):
        """
        """
        result, metadata = False, {}

        if cb_name == "gke-cluster-health" and task_id_str == "gke-nodesize-validate":
            if 'cluster' in kwargs and 'title_template' in kwargs:

                cluster, title_template = kwargs['cluster'], kwargs['title_template']

                if title_template == "Unready nodes detected":
                    if 'unready_nodes' in kwargs:
                        unready_nodes = kwargs["unready_nodes"]
                        num_unready_nodes = len(unready_nodes)
                        unready_node_names = ", ".join([f"`{node_nm}`" for node_nm in unready_nodes])
                        
                        summary = textwrap.dedent(f"""
                            {num_unready_nodes} nodes ({unready_node_names}) in the `{cluster}` GKE 
                            cluster were detected as unready, reducing overall cluster capacity. The 
                            issue indicated that the cluster was at or near capacity and might require 
                            additional or healthy nodes. Recommended actions included investigating 
                            node health and readiness, checking control plane and node communication, 
                            and validating component health checks.""").strip()
                        
                        observations = [
                            {
                                "observation": f"{num_unready_nodes} nodes, {unready_node_names}, in cluster `{cluster}` were reported as unready, reducing cluster capacity.",
                                "category": "infrastructure"
                            },
                            {
                                "observation": f"The `{cluster}` currently lacks sufficient available node capacity compared to expected operational levels.",
                                "category": "performance"
                            }
                        ]

                        next_steps = [
                            f"Run GKE node diagnostics for `{cluster}`",
                            f"Check control plane and node communication status in `{cluster}`",
                            f"Validate GKE cluster component health checks for `{cluster}`"
                        ]
                        next_steps_str = "\n".join(next_steps)

                        metadata = {
                            "summary": summary,
                            "observations": observations,
                            "next_steps": next_steps_str
                        }
                elif title_template == "Analysis failed":
                    if 'no_valid_nodes' in kwargs:
                        summary = textwrap.dedent(f"""
                            The analysis for cluster `{cluster}` failed due to the absence of schedulable nodes. 
                            Recommended actions include checking the control plane, reviewing node taints and 
                            labels, assessing resource quota utilization, and investigating recent node 
                            provisioning failures in `{cluster}`""").strip()
                        
                        observations = [
                            {
                                "observation": f"{num_unready_nodes} nodes, {unready_node_names}, in cluster `{cluster}` were reported as unready, reducing cluster capacity.",
                                "category": "infrastructure"
                            },
                            {
                                "observation": f"The `{cluster}` currently lacks sufficient available node capacity compared to expected operational levels.",
                                "category": "performance"
                            }
                        ]

                        next_steps = [
                            f"Evaluate node taints and labels in `{cluster}`",
                            f"Assess resource quota utilization in `{cluster}`",
                            f"Investigate recent node provisioning failures in `{cluster}`"
                        ]
                        next_steps_str = "\n".join(next_steps)

                        metadata = {
                            "summary": summary,
                            "observations": observations,
                            "next_steps": next_steps_str
                        }

                elif title_template == "No pods found":
                    summary = textwrap.dedent(f"""
                            Cluster {cluster} was found with no running pods, preventing sizing analysis. 
                            The issue indicated that GKE nodes were at capacity or unavailable. Recommended 
                            actions included deploying workloads, verifying node health, inspecting control 
                            plane events, and validating network and IAM configurations.""").strip()
                        
                    observations = [
                        {
                            "observation": f"Cluster `{cluster}` had no active pods detected, preventing resource sizing analysis.",
                            "category": "operational"
                        },
                        {
                            "observation": f"IAM or network misconfigurations may have affected resource provisioning in `{cluster}`.",
                            "category": "configuration"
                        }
                    ]
                    
                    next_steps = [
                        f"Verify node health and readiness in `{cluster}`",
                        f"Inspect control plane events for `{cluster}`",
                        f"Validate network and IAM configurations in `{cluster}`"
                    ]
                    next_steps_str = "\n".join(next_steps)

                    metadata = {
                        "summary": summary,
                        "observations": observations,
                        "next_steps": next_steps_str
                    }
                elif title_template == "Node overloaded":
                    if "overloaded" in kwargs:
                        overloaded_nodes = kwargs["overloaded"]
                        overloaded_node_names = ", ".join([f"`{node_nm}`" for node_nm in overloaded_nodes])

                        summary = textwrap.dedent(f"""
                            The `{cluster}` experienced capacity issues where {overloaded_node_names} exceeded 
                            their allocatable resource limits, leading to an overloaded state. This indicated 
                            that the cluster had insufficient available node capacity to handle current workloads 
                            effectively. Investigations focused on optimizing workload distribution, reviewing 
                            recent deployment impacts, and validating resource quotas and limits to prevent 
                            future overutilization.""").strip()
                        
                        observations = [
                            {
                                "observation": f"{overloaded_node_names} in `{cluster}` exceeded their allocatable resource requests.",
                                "category": "performance"
                            },
                            {
                                "observation": f"Recent deployment activity may have contributed to increased resource pressure on {overloaded_node_names}.",
                                "category": "configuration"
                            },
                            {
                                "observation": f"Resource quotas and limits in `{cluster}` may not align with current workload demands.",
                                "category": "configuration"
                            }
                        ]


                        next_steps = [
                            f"Investigate workload distribution efficiency in `{cluster}`",
                            f"Audit recent deployment activities impacting {overloaded_node_names} in `{cluster}`",
                            f"Validate resource quota and limit configurations in `{cluster}`"
                        ]
                        next_steps_str = "\n".join(next_steps)

                        metadata = {
                            "summary": summary,
                            "observations": observations,
                            "next_steps": next_steps_str
                        }
                    
                elif title_template == "Node limits over-committed":
                    if 'limit_over_nodes' in kwargs and 'max_cpu_limit' in kwargs and 'max_mem_limit' in kwargs:
                        limit_over_nodes = kwargs['limit_over_nodes']
                        limit_over_nodes_str = ", ".join([f'`{node_nm}`' for node_nm in limit_over_nodes])
                        num_limit_over = len(limit_over_nodes)

                        max_cpu_limit, max_mem_limit = kwargs['max_cpu_limit'], kwargs['max_mem_limit']

                        result = True
                        summary = textwrap.dedent(f"""
                            {num_limit_over} nodes in cluster `{cluster}` are over-committed, exceeding CPU and 
                            memory thresholds, which has resulted in the cluster reaching capacity and 
                            lacking available nodes. The expected state is for the GKE cluster to have 
                            available nodes, but currently, additional resources or adjustments are needed. 
                            Recommended actions include lowering pod limits, splitting workloads, or 
                            scaling the node pool; no comments were provided and no resolving task is noted.
                        """).strip()

                        observations = [
                            {
                                "category": "infrastructure",
                                "observation": textwrap.dedent(f"""
                                    Nodes {limit_over_nodes_str} in cluster `{cluster}` have exceeded 
                                    CPU (> {max_cpu_limit}) or memory (> {max_mem_limit}) limit thresholds.""").strip()
                            },
                            {
                                "category": "operational",
                                "observation": textwrap.dedent(f"""
                                    Actual state shows GKE clusters in `{cluster}` are at capacity or require new nodes, 
                                    differing from the expected state of available node capacity.""").strip()
                            }
                        ]

                        next_steps = [
                            f"Analyze resource allocation patterns in `{cluster}` cluster",
                            f"Inspect pod scheduling events in `{cluster}` cluster",
                            f"Review node performance metrics for `{cluster}` cluster",
                            f"Analyze node resource allocation in `{cluster}`",
                            f"Review recent pod scheduling events in `{cluster}`",
                            f"Inspect historical CPU and memory usage trends for `{cluster}`"
                        ]
                        next_steps_str = "\n".join(next_steps)

                        metadata = {
                            "summary": summary,
                            "observations": observations,
                            "next_steps": next_steps_str
                        }
        elif cb_name == "k8s-istio-system-health" and task_id_str == "sidecar-injection":

            if 'deployment' in kwargs and 'namespace' in kwargs:

                deployment, namespace = kwargs['deployment'], kwargs['namespace']
            
                summary = textwrap.dedent(f"""
                    Deployment `{deployment}` in namespace `{namespace}` does not have Istio sidecar injection 
                    configured, as both the namespace-level injection and required annotation are missing. 
                    The expected configuration is for Istio injection to be enabled for this deployment. 
                    Action is needed to enable namespace-level Istio injection in `{namespace}`.
                """).strip()

                observations = [
                    {
                        "category": "configuration",
                        "observation": textwrap.dedent(f"""
                            `{deployment}` in namespace `{namespace}` is missing both namespace-level Istio 
                            injection and required annotation.
                        """).strip()
                    }
                ]

                metadata = {
                    "summary": summary,
                    "observations": observations
                }
                result = True
        
        return result, metadata
