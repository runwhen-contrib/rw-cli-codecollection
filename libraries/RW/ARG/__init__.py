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
    ARG.Create Azure Resource Graph    subscription=your_subscription_id    no_potential_deps=True/False    output=your_output_file    basic_mode=True/False
```

Scope: Global
"""
from .ARG import *