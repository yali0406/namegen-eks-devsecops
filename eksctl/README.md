# Infrastructure - eksctl (EKS Auto Mode)

This project provisions the EKS cluster with **eksctl** using **EKS Auto Mode**,
so AWS manages the data plane (nodes, autoscaling), the AWS Load Balancer
Controller (needed for the NLB) and the EBS storage integration (needed for
the MongoDB PersistentVolume) automatically - no extra add-ons to install.
Note: Auto Mode still requires a `StorageClass` to be created explicitly
(see `k8s/03b-storageclass.yaml`) - it does not create a default one.

## Prerequisites

- AWS CLI v2, configured (`aws configure`) with an IAM user/role that has
  permissions to create EKS clusters, VPCs, IAM roles, EC2 instances, and
  Elastic Load Balancers.
- `eksctl` >= 0.190 (Auto Mode support)
- `kubectl`

## Create the cluster

```bash
eksctl create cluster -f eksctl/cluster.yaml
```

This takes roughly 15-20 minutes. `eksctl` automatically updates your local
`~/.kube/config`. You can also do it manually:

```bash
aws eks update-kubeconfig --name namegen-cluster --region us-east-1
kubectl get nodes
```

## Create the ECR repository (for the CI/CD pipeline)

```bash
aws ecr create-repository --repository-name namegen-app --region us-east-1
```

## Delete the cluster (cleanup, avoid charges)

```bash
eksctl delete cluster -f eksctl/cluster.yaml
```

## Terraform alternative

The assignment allows either eksctl or Terraform. We chose eksctl for
simplicity with EKS Auto Mode. If you prefer Terraform, the equivalent module
uses `terraform-aws-modules/eks/aws` (>= v20) with
`cluster_compute_config { enabled = true }` to turn on Auto Mode - see the
module docs: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
