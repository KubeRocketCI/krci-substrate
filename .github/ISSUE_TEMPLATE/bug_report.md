---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**

#### What did you do?

<!-- A clear and concise description of the steps you took (or insert a code snippet). -->

#### What did you expect to see?

<!-- A clear and concise description of what you expected to happen (or insert a code snippet). -->

#### What did you see instead? Under which circumstances?

<!-- A clear and concise description of what ACTUALLY happened (or insert a code snippet). -->

**Chart version:**

<!-- `helm list -A | grep krci-substrate`, or the version in the Argo CD Application. -->

**Values that differ from the defaults:**

<!-- Remove secrets, bucket names and account IDs. -->

**Kubernetes cluster type and version:**

<!-- For example "EKS 1.36", "kind 1.37". Output of `kubectl version`. -->

**Pod status and logs:**

<!-- `kubectl -n ate-system get pods`, and the logs of the failing pod. -->

**Additional context**
Add any other context about the problem here.
