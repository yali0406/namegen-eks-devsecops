# Random Name Generator and Saver App - EKS + CI/CD Final Project

DevSecOps final project: deploy the [namegen](https://github.com/redhat-developer-demos/namegen)
Node.js + MongoDB demo application on Amazon EKS, provisioned with `eksctl`
(EKS Auto Mode), exposed via an AWS Network Load Balancer, backed by a
MongoDB StatefulSet with persistent storage, and shipped through a GitHub
Actions CI/CD pipeline.

## Architecture

See [`diagram/architecture.drawio`](diagram/architecture.drawio) (open in
[draw.io](https://app.diagrams.net/)). Summary:

1. Developer pushes to `main` on GitHub.
2. GitHub Actions (`.github/workflows/deploy.yml`) builds the Docker image,
   pushes it to **Amazon ECR**, then applies the Kubernetes manifests and
   updates the running Deployment on **EKS**.
3. The app is exposed to the internet via a **Network Load Balancer (NLB)**,
   provisioned automatically by the AWS Load Balancer Controller that ships
   with **EKS Auto Mode**.
4. The app (2 replicas) talks to **MongoDB** (a `StatefulSet` with a
   `PersistentVolume` backed by EBS) over the cluster-internal headless
   service `mongodb`.

## Repository layout

```
.
├── Dockerfile                     # Container image for the Node.js app
├── .dockerignore
├── eksctl/
│   ├── cluster.yaml                # EKS Auto Mode cluster definition
│   └── README.md                   # Infra provisioning instructions
├── k8s/
│   ├── 00-namespace.yaml
│   ├── 01-mongodb-secret.yaml      # genuser/password + MONGODB_URL
│   ├── 02-mongodb-init-configmap.yaml  # creates the genuser DB user on first boot
│   ├── 03-mongodb-service.yaml     # headless service "mongodb"
│   ├── 03b-storageclass.yaml       # "auto-ebs-sc" StorageClass required by EKS Auto Mode
│   ├── 04-mongodb-statefulset.yaml # mongo:3.6 + PVC (PersistentVolume)
│   ├── 05-app-deployment.yaml      # namegen-app Deployment
│   └── 06-app-service-nlb.yaml     # LoadBalancer Service -> AWS NLB
├── iam-policies/
│   └── cicd-eks-describe-policy.json  # least-privilege policy for the CI/CD IAM user
├── .github/workflows/deploy.yml    # CI/CD pipeline
├── diagram/architecture.drawio     # Architecture + pipeline diagram
├── screenshots/                    # Evidence of the running system
├── package.json / server.js / ...  # namegen application source code
└── README.md
```

## Application

* Source: https://github.com/redhat-developer-demos/namegen (Node.js +
  Express, EJS/HTML front end, MongoDB via Mongoose).
* Listens on port `8080` by default (`SERVER_PORT` env var to override).
* Reads the MongoDB connection string from `MONGODB_URL`:
  `mongodb://genuser:password@mongodb/namegen`
* Endpoints: `GET /` (UI), `GET /api/random_name`, `POST /api/names`,
  `GET /api/names`, `DELETE /api/names`.

## Infrastructure - EKS Auto Mode (eksctl)

We use **EKS Auto Mode** so AWS manages nodes/autoscaling, the AWS Load
Balancer Controller, and the EBS CSI driver - no manual add-on installs.
See [`eksctl/README.md`](eksctl/README.md) for full setup/teardown commands.

```bash
eksctl create cluster -f eksctl/cluster.yaml
aws ecr create-repository --repository-name namegen-app --region us-east-1
```

## Database - MongoDB StatefulSet + PersistentVolume

* Image: `mongo:3.6` (per project requirements), started with `--auth`.
* `02-mongodb-init-configmap.yaml` seeds the database on first boot,
  creating a `genuser` user scoped to the `namegen` database (matches the
  required `MONGODB_URL` exactly, with no `authSource` needed).
* `04-mongodb-statefulset.yaml` requests a `5Gi` PVC (`storageClassName:
  auto-ebs-sc`), dynamically provisioned as an EBS volume through the
  StorageClass defined in `03b-storageclass.yaml`. EKS Auto Mode does not
  create a default StorageClass, so this one must be applied explicitly
  (it references the `ebs.csi.eks.amazonaws.com` provisioner).
* A headless `Service` (`clusterIP: None`) named `mongodb` gives the app a
  stable DNS name to connect to.

## Deploying manually

```bash
aws eks update-kubeconfig --name namegen-cluster --region us-east-1

kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-mongodb-secret.yaml
kubectl apply -f k8s/02-mongodb-init-configmap.yaml
kubectl apply -f k8s/03-mongodb-service.yaml
kubectl apply -f k8s/03b-storageclass.yaml
kubectl apply -f k8s/04-mongodb-statefulset.yaml

# Build & push the app image first (see CI/CD section), then:
kubectl apply -f k8s/05-app-deployment.yaml   # after replacing <ECR_IMAGE_URI>
kubectl apply -f k8s/06-app-service-nlb.yaml

kubectl get svc namegen-app-nlb -n namegen   # get the NLB hostname
```

## CI/CD pipeline (GitHub Actions)

`.github/workflows/deploy.yml` runs on every push to `main`:

1. Configure AWS credentials from repo secrets.
2. Log in to ECR, build the Docker image, tag it with the commit SHA and
   `latest`, push both tags.
3. Update kubeconfig for the EKS cluster.
4. `kubectl apply` all manifests in `k8s/`.
5. `kubectl set image` on the `namegen-app` Deployment with the new image,
   then wait for the rollout to finish.
6. Print the NLB service endpoint.

### Required GitHub repository secrets

| Secret name             | Description                                   |
|--------------------------|-----------------------------------------------|
| `AWS_ACCESS_KEY_ID`      | Access key of a dedicated, least-privilege IAM user (see below) |
| `AWS_SECRET_ACCESS_KEY`  | Matching secret key                           |

**Security note:** CI/CD does not use the AWS root account. A dedicated IAM
user (`namegen-cicd`) was created with only the permissions it needs:
`AmazonEC2ContainerRegistryPowerUser` (push/pull to ECR) plus a minimal
inline policy allowing `eks:DescribeCluster` / `eks:ListClusters` (see
`iam-policies/cicd-eks-describe-policy.json`). IAM permissions alone are not
enough to run `kubectl` against the cluster - the user was also granted
access inside the cluster itself via an EKS Access Entry:

```bash
aws eks create-access-entry --cluster-name namegen-cluster --region us-east-1 \
  --principal-arn arn:aws:iam::<account-id>:user/namegen-cicd

aws eks associate-access-policy --cluster-name namegen-cluster --region us-east-1 \
  --principal-arn arn:aws:iam::<account-id>:user/namegen-cicd \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

## Accessing the app

Once the NLB is provisioned (a few minutes after `06-app-service-nlb.yaml`
is applied):

```bash
kubectl get svc namegen-app-nlb -n namegen
```

Open the `EXTERNAL-IP` hostname shown (port 80) in a browser.

## Cleanup

To avoid ongoing AWS charges, tear everything down after the project has
been graded:

```bash
# Kubernetes workloads (also releases the EBS-backed PersistentVolume)
kubectl delete namespace namegen

# EKS cluster (deletes the VPC, control plane, and Auto Mode nodes)
eksctl delete cluster -f eksctl/cluster.yaml

# ECR repository and images
aws ecr delete-repository --repository-name namegen-app --region us-east-1 --force

# Dedicated CI/CD IAM user (access key, inline + managed policy, user)
aws iam list-access-keys --user-name namegen-cicd   # note the AccessKeyId(s)
aws iam delete-access-key --user-name namegen-cicd --access-key-id <AccessKeyId>
aws iam delete-user-policy --user-name namegen-cicd --policy-name EKSDescribe
aws iam detach-user-policy --user-name namegen-cicd --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam delete-user --user-name namegen-cicd
```

## Screenshots

See [`screenshots/`](screenshots/) for evidence of the cluster, pods, PVC,
NLB, running app, and a successful GitHub Actions run.

## Notes / assumptions

* Region: `us-east-1` (change in `eksctl/cluster.yaml` and the workflow
  `env.AWS_REGION` if needed).
* `genuser` / `password` are used as required by the assignment spec; for a
  real deployment these should be sourced from a secrets manager rather than
  a base64 `Secret` committed to git.
* EKS Auto Mode was chosen over self-managed/managed node groups so that
  node provisioning, the load balancer controller, and the storage driver
  are all handled by AWS, keeping the setup within the scope of the course.
