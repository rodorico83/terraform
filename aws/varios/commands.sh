################
##### SERVICE ##
#################
# Get name for ELB from nginx-controller  k8s-ingressn-ingressn-ca266c18de-e07b0c34172fb759.elb.eu-south-2.amazonaws.com
kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath="{.status.loadBalancer.ingress[*].hostname}"

##################
#### SECRETS #####
##################
# Get ArgoCD default admin password YJVbYEOHLEqbcsBT
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 --decode; echo ""
# Get Grafana default admin password SUg5mIx3wgIOtC9wplA3T6Ol6nw4RjtS
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 --decode; echo ""
# Kibana y1KgknxFhLDxxBH1TTWOfGYn
kubectl get secret elasticsearch-es-elastic-user -n logging -o jsonpath="{.data.elastic}" | base64 --decode
# Replace secret definition to apply for instance eks secret KMS encrypt on already created cluster with already secrets on it.
kubectl get secrets --all-namespaces -o json | kubectl replace -f -

######################
#### AWS SECRETS #####
######################
aws secretsmanager get-secret-value --secret-id "dev/grafana/admin-password" --query SecretString --output text
# get secret  ubJAW8xSFH4YiSGKxFt6z0yTFmb9lF0x
aws secretsmanager get-secret-value --secret-id dev/grafana/admin-password --query SecretString --output text --region eu-south-2
# Force deletion of secret, otherwise is scheduled for deletion up to 30 days, can cause problem if you re-run your infraestrucutre after destroy
aws secretsmanager delete-secret   --secret-id dev/grafana/admin-password   --force-delete-without-recovery   --region eu-south-2


############
## APPLY ###
############
# For ArgoCD Appproject creation
export APP_NAME="rabbitmq-tester" && envsubst < template.yaml | kubectl apply -f -

#####################
### PORT FORWARD ####
#####################
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090

###############
#### EXEC #####
###############
# Execute in node via ssm
ssm send-command   --region eu-south-2   --instance-ids $NODE_ID   --document-name "AWS-RunShellScript"   --parameters 'commands=["nc -zv -w 3 10.0.142.186 5432"]'

# Execute in container
kubectl exec -i deployment/db-connectivity-tester -n dev -c <nombre-del-contenedor> -- nslookup name
kubectl exec -i deployment/db-connectivity-tester -n dev -- traceroute -n -m 5 database.cf4acwm6m1ht.eu-south-2.rds.amazonaws.com
kubectl exec -i deployment/db-connectivity-tester -n db-connectivity-tester -- nc -zv -w 3 database.cf4acwm6m1ht.eu-south-2.rds.amazonaws.com 5432
# Open shell in container via pod instance name
kubectl exec -it db-connectivity-tester-7d49b846f4-x9z2p -c my-app-container -n dev -- /bin/sh
# Print injected variables
kubectl exec -it db-connectivity-tester-6f6b464dbb-vblpk -n db-connectivity-tester -- printenv | grep -E "host|username|password"
kubectl exec -i deployment/kube-prometheus-stack-grafana -n monitoring -c grafana -- wget -qO- http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/-/ready
kubectl exec -it daemonset/aws-node-termination-handler -n kube-system -- wget -qO- http://localhost:9092/metrics | grep aws_node_termination_handler

######################
### ROLLING UPDATE ###
######################
# Rolling update
kubectl apply -f archivo.yaml
# Rolling restart and status
kubectl rollout restart daemonset aws-node -n kube-system
kubectl rollout restart statefulset argocd-application-controller -n argocd
kubectl rollout undo deployment/web             # revert to previous revision
kubectl rollout undo deployment/web --to-revision=3
kubectl rollout history deployment/web          # see history
kubectl rollout status deployment/web           # watch rollout progress
kubectl rollout status deployment -n argocd -l app.kubernetes.io/part-of=argocd
kubectl rollout status daemonset/aws-node -n kube-system
kubectl rollout pause deployment/web            # pause (useful for canary-by-hand)
kubectl rollout resume deployment/web
# Argo Rollouts (No deployments)
kubectl argo rollouts restart <nombre-rollout> -n <namespace>

# get servicio
kubectl get svc -n monitoring | grep alertmanager
kubectl get deployment karpenter -n kube-system -o yaml

###########
## SCALE ##
###########
# Scale a replica set named 'foo' to 3
kubectl scale --replicas=3 rs/foo
# Scale a resource identified by type and name specified in "foo.yaml" to 3
kubectl scale --replicas=3 -f foo.yaml
# If the deployment named mysql's current size is 2, scale mysql to 3
kubectl scale --current-replicas=2 --replicas=3 deployment/mysql
# Scale multiple replication controllers
kubectl scale --replicas=5 rc/example1 rc/example2 rc/example3
# Scale stateful set named 'web' to 3
kubectl scale --replicas=3 statefulset/web


#######################
#### SET ENV VARS #####
#######################
kubectl set env daemonset/aws-node -n kube-system ANNOTATE_POD_IP=true
kubectl set env daemonset/aws-node -n kube-system ANNOTATE_POD_IP-
kubectl set env daemonset/aws-node -n kube-system --list
# increase EIP by node (delegación de prefijos en la CNI)
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true

# Set in helm app
helm upgrade <NOMBRE_RELEASE> <RUTA_O_NOMBRE_CHART> -n <NAMESPACE> --reuse-values --set env.MI_VARIABLE_DEBUG=true

##########
### TOP ##
##########
kubectl top pod <nombre-del-pod> -n <namespace> --containers

##############
#### LOGS ####
##############
# Container logs by pod label match
kubectl logs -n kube-system -l k8s-app=aws-node -c aws-node --tail=50 | grep -E -i "error|ipam|eni|assign"
# Logs by pod instance name
kubectl logs db-connectivity-tester-bd7d5fcc5-4w8f8 -n db-connectivity-tester -c web-validator
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --all-containers=true
# Logs of container using Deployment
kubectl logs deployment/argocd-server -n argocd -c argo-rollouts-extension
# Log of previous container instance in pod
kubectl logs ztunnel-zdrfc -n istio-system -c istio-proxy --previous


################
#### EVENTS ####
################
kubectl get events -n istio-system --sort-by='.metadata.creationTimestamp'

#############
#### CRD ####
#############
kubectl get crd rollouts.argoproj.io
kubectl get crd -l app.kubernetes.io/name=gateway-api
kubectl api-resources | grep virtualservice

##################
#### GET ####
##################
# get status termination of containers
kubectl get pod <nombre-del-pod> -n <namespace> -o jsonpath='{.status.containerStatuses[*].terminated}'
kubectl get pods -n <namespace> -o=custom-columns=NAME:.metadata.name,STATUS:.status.phase,REASON:.status.containerStatuses[*].state.terminated.reason,EXIT_CODE:.status.containerStatuses[*].state.terminated.exitCode

kubectl get events -n namespace

##################
#### PODS ####
##################
# Get container from pod
kubectl get pod -n kube-system -l k8s-app=aws-node -o jsonpath='{.items[*].spec.containers[*].name}'
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[*].spec.initContainers[*].name}'
kubectl get pods --field-selector spec.nodeName=<NODE_NAME> --all-namespaces
# Get specific pod containers
kubectl get pod  aws-node-nzshf -n kube-system -o jsonpath='{.spec.containers[*].name}'
# get argo apps
kubectl get applications.argoproj.io -A # Get Argo applications in all namespaces

# Get pods with container statuses
kubectl get pods -n <namespace> -o=custom-columns=NAME:.metadata.name,STATUS:.status.phase,REASON:.status.containerStatuses[*].state.terminated.reason,EXIT_CODE:.status.containerStatuses[*].state.terminated.exitCode
kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node")].env[?(@.name=="ENABLE_PREFIX_DELEGATION")].value}'

###################
#### GET NODES ####
###################
# Get nodes table with karpenter pool/ASG group info
kubectl get nodes -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels."karpenter\.sh/nodepool",CAPACITY:.metadata.labels."karpenter\.sh/capacity-type",MANAGED-BY:.metadata.labels."eks\.amazonaws\.com/nodegroup"
kubectl get nodes -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels."karpenter\.sh/nodepool",MANAGED-BY:.metadata.labels."eks\.amazonaws\.com/nodegroup"
kubectl get nodes -o custom-columns=NAME:.metadata.name,MAX-PODS:.status.allocatable.pods
kubectl get node <nombre-del-nodo> -o jsonpath='{.status.capacity.pods}'


############
### WAIT ###
############
kubectl wait deployment/mi-servicio --for=condition=Available --timeout=120s
kubectl wait node/ip-10-0-1-50.ec2.internal --for=condition=Ready --timeout=90s
kubectl wait node --selector=karpenter.sh/nodepool=low-cost-pool --for=delete --timeout=300s
kubectl wait job/migracion-db --for=condition=Complete --timeout=300s

###################
###### HPA ########
###################
# Option 1
# To scale to 0 first delete HPAs temporarily
kubectl delete hpa --all -n monitoring
# now scale Deployments to 0
kubectl scale deployment --all --replicas=0 -n monitoring

# Option2 via helm so hpa does not need to be deleted
helm upgrade <RELEASE_NAME> <CHART_NAME> -n monitoring --set replicaCount=0 --set autoscaling.enabled=false

################################
###### NODE MAINTENANCE ########
################################
kubectl cordon # set node on maintenance no pods will be scheduled
kubectl drain <node name>

############
#### AUTH/TOKENS ##
############
kubectl auth can-i list deployments --as=system:serviceaccount:argocd:argocd-application-controller -n default
kubectl auth can-i create networkpolicy   --as=system:serviceaccount:argocd:argocd-application-controller   --as-group=argocd:business-operators  -n default
kubectl auth can-i create serviceaccounts/token -n istio-system
kubectl create token <NOMBRE_SERVICE_ACCOUNT> [-n <NAMESPACE>]

#############
#### AWS ####
#############

# Update .kube
aws eks update-kubeconfig --region eu-south-2 --name dev-aws-cluster

#### RDS
aws rds describe-db-instances --region eu-south-2 --query "DBInstances[*].[DBInstanceIdentifier, DBInstanceStatus, Endpoint.Address]" --output table

#### EC2
aws ec2 describe-network-acls --region eu-south-2 --filters "Name=vpc-id,Values=vpc-0665404faa4df3d1" --query "NetworkAcls[*].Entries" --output json
aws ec2 describe-instances --region eu-south-2 --filters "Name=tag:kubernetes.io/cluster/dev-aws-cluster,Values=owned,shared" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text

aws ec2 describe-instances \
    --filters "Name=tag:karpenter.sh/nodepool,Values=low-cost-pool-infra" \
    --query "Reservations[*].Instances[*].{InstanceId:InstanceId, Type:InstanceType, State:State.Name, PrivateIP:PrivateIpAddress, AZ:Placement.AvailabilityZone, LaunchTime:LaunchTime}" \
    --output table

#### SUBNETS
aws ec2 describe-subnets --query "Subnets[*].[SubnetId,CidrBlock,AvailableIpAddressCount]" --output table
aws ec2 describe-subnets \
  --region eu-south-2 \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXXXXXXXXXXX" \
  --query "Subnets[*].[SubnetId, CidrBlock, AvailabilityZone, AvailableIpAddressCount, MapPublicIpOnLaunch]" \
  --output table


# ECR
# login registry for helm publishing
aws ecr get-login-password --region <region> | helm registry login --username AWS --password-stdin <tu-id>.dkr.ecr.<region>.amazonaws.com


#### ASG
# AWS Auto Scaling Groups (ASGs) Not scaling check
aws autoscaling describe-scaling-activities --region eu-south-2 --max-items 5 --query "Activities[*].[StartTime,StatusCode,StatusMessage]" --output table

#### EKS
aws eks update-addon --cluster-name dev-aws-cluster --addon-name vpc-cni --resolve-conflicts OVERWRITE --region eu-south-2
aws eks list-associated-access-policies --cluster-name dev-aws-cluster --principal-arn arn:aws:iam::555968473487:role/dev-argocd-deployer-role

#### IAM
aws iam list-attached-role-policies --role-name dev-eks-nodes-role --region eu-south-2

# AWS Shutdown spot instance
aws ec2 describe-instances \
    --instance-ids <i-xxxxxxxxx> \
    --query "Reservations[].Instances[].SpotInstanceRequestId" \
    --output text
aws ec2 cancel-spot-instance-requests --spot-instance-request-ids sir-it8fj1xg
aws ec2 terminate-instances --instance-ids i-0354899c2882c95ea


# AWS Create Registry and push Images/HelmCharts
aws ecr create-repository \
    --repository-name db-tester \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE
aws ecr get-login-password --region eu-south-2 | docker login --username AWS --password-stdin 555968473487.dkr.ecr.eu-south-2.amazonaws.com
aws ecr get-login-password --region eu-south-2 | helm registry login --username AWS --password-stdin 555968473487.dkr.ecr.eu-south-2.amazonaws.com
podman build -t db-tester .
podman tag db-tester:latest 555968473487.dkr.ecr.eu-south-2.amazonaws.com/aws-registry/db-tester:latest
podman push 555968473487.dkr.ecr.eu-south-2.amazonaws.com/aws-registry/db-tester:latest

################
#### ARGOCD ####
################
argocd app diff my-app
argocd app get my-app --refresh
# Check why a resource is unhealthy
argocd app resources my-app --output json | jq '.[] | select(.health.status != "Healthy")'
# disbale auto sync so the value change persist and is not detected by argo until you sync manually
argocd app set <APP_NAME> --sync-policy manual


#############
#### HELM ###
#############

# 1. GESTIÓN DE REPOSITORIOS
# ------------------------------------------------------------------------------
helm repo add <nombre-repo> <URL-repo>                  # Agregar un repositorio remoto
helm repo update                                        # Actualizar el catálogo local de charts
helm repo list                                          # Listar repositorios configurados
helm search repo <palabra-clave>                        # Buscar un chart en repositorios locales
helm repo remove <nombre-repo>                          # Eliminar un repositorio


# 2. INSPECCIÓN Y RENDERIZADO (DEBUG / GITOPS)
helm get values <nombre-release> -n <namespace>         # Ver el values.yaml aplicado en un release
helm get manifest <nombre-release> -n <namespace>       # Ver los manifiestos YAML de una release activa
helm get notes <nombre-release> -n <namespace>          # Ver notas e instrucciones posinstalación
helm install <release> <repo>/<chart> -f values.yaml --dry-run --debug -n <namespace> # Simular instalación sin aplicar
helm template mi-release ./mi-chart -f values.yaml | kubectl apply -f - # Apply kubectl file with a values file using Helm

# 3. INSTALACIÓN Y DESPLIEGUE
helm install <release> <repo>/<chart> -n <namespace> --create-namespace                # Instalar creando namespace
helm install <release> <repo>/<chart> -f values.yaml -n <namespace>                    # Instalar con archivo de valores
helm install <release> <repo>/<chart> --set key=value,key2=value2 -n <namespace>       # Sobrescribir variables por CLI
helm get manifest karpenter-crd -n kube-system | kubectl apply -f -

# 4. ACTUALIZACIÓN Y MANTENIMIENTO (UPGRADES)
helm upgrade <release> <repo>/<chart> -f values.yaml -n <namespace>                    # Actualizar release existente
helm upgrade --install <release> <repo>/<chart> -f values.yaml -n <namespace> --create-namespace # (instala o actualiza)
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd --version 1.0.6 -n kube-system --force
# Rollback automático si falla
helm upgrade <release> <repo>/<chart> -f values.yaml -n <namespace> --atomic  --timeout 3m
helm upgrade <RELEASE_NAME> <CHART_NAME> -n monitoring --set replicaCount=0 --set autoscaling.enabled=false

# 5. CONSULTAS E HISTORIAL
helm list -n <namespace>                               # Listar releases en un namespace especifico
helm list -A                                           # Listar releases en TODOS los namespaces
helm history <nombre-release> -n <namespace>           # Ver el historial de revisiones de una release

# 6. ROLLBACK Y RECUPERACIÓN ANTE FALLOS
helm rollback <nombre-release> <numero-revision> -n <namespace> # Volver a una versión previa (ej: revisión 2)

# 7. DESINSTALACIÓN Y LIMPIEZA
helm uninstall <nombre-release> -n <namespace>          # Eliminar release y sus recursos en Kubernetes
helm uninstall <nombre-release> --keep-history -n <namespace> # Eliminar manteniendo historial para auditoría


helm lint



# INFRA BOOT
terraform apply --target module.platform.aws_eks_node_group.private_nodes --auto-approve && \
cd ../3 -software && \
terraform apply --target module.software.kubectl_manifest.karpenter_node_pool --auto-approve