# RBAC

Starting Platform9 Managed Kubernetes (PMK) 3.3 RBAC would be enabled by default in all PMK clusters.

The yaml examples here show how RBAC, roles and rolebindings can be used to control access to Kubernetes resources.

## Roles
`pod-reader.yaml` Defines a ClusterRole which allows users to view pods.

## RoleBindings

Roles can be associated with users and groups using different role bindings.

`pod-reader-rb.yaml` is an example of ClusterRoleBinding where a specific user is assigned pod-reader role at Cluster level. 

`pod-reader-rb-default.yaml` is an example of RoleBinding where  a specific user is assigned pod-reader role only for the `default` namespace.

`pod-reader-rb-group.yaml` is an example of ClusterRoleBinding where a specific group is assigned pod-reader role at Cluster level

`pod-reader-rb-ssu.yaml` is an example of ClusterRoleBinding where a special group `ssu_users` is assigned pod-reader role at Cluster level. Any user with a `_member_` role for a project is by default member of this group. 