# Kubernetes Chaos Flux Codebundle
The `k8s-chaos-flux` codebundle is built to facility chaos tests on Flux managed resources. 

## TaskSet
The TaskSet provides the following tasks:

- `Suspend the Flux Resource Reconciliation`: This task is responsible for pausing a Flux resource temporarily so that chaos tasks can be performed on it.
- `Find Random FluxCD Workload as Chaos Target`: [Optional]This task inspects a Flux resource and randomly selects a specific part of it to be the target for chaos testing.
- `Execute Chaos Command`: This task executes a specific chaos command within the chosen target resource, causing controlled chaos to occur. The command can be run multiple times if needed.
- `Execute Additional Chaos Command`: This task executes an additional chaos command, if provided, within the chosen target resource. It allows for more flexibility in performing custom chaos operations.
- `Resume Flux Resource Reconciliation`: This task resumes the normal operation of the Flux resource after chaos testing is completed, allowing it to function as before.


## ELI5 Writeup "ala chatGPT" for Fun
This code is like a set of instructions for a robot that works with a special technology called Flux in a place called Kubernetes. The robot's job is to make things a bit chaotic on purpose, but only for testing. It can stop or pause a particular thing it's working on, like pressing a pause button. It can also randomly select something to play with, like picking a toy from a box. The robot can run special commands to make things go a bit crazy, but it knows how many times to do it, just like counting to 10. Sometimes it can even do some extra commands if we ask it nicely. And when it's done, the robot knows how to resume its work and make things normal again.