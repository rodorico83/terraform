################
##### SERVICE ##
#################
# Get name for ELB from nginx-controller  k8s-ingressn-ingressn-ca266c18de-e07b0c34172fb759.elb.eu-south-2.amazonaws.com
kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath="{.status.loadBalancer.ingress[*].hostname}"

##################
#### SECRETS #####
##################
# Get ArgoCD default admin password 2zI9l2Fc8e3cDR7S
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 --decode; echo ""
# Get Grafana default admin password ubJAW8xSFH4YiSGKxFt6z0yTFmb9lF0x
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 --decode; echo ""
# Kibana y1KgknxFhLDxxBH1TTWOfGYn
kubectl get secret elasticsearch-es-elastic-user -n logging -o jsonpath="{.data.elastic}" | base64 --decode

######################
#### AWS SECRETS #####
######################
aws secretsmanager get-secret-value --secret-id "dev/grafana/admin-password" --query SecretString --output text
# get secret  ubJAW8xSFH4YiSGKxFt6z0yTFmb9lF0x
aws secretsmanager get-secret-value --secret-id dev/grafana/admin-password --query SecretString --output text --region eu-south-2
# Force deletion of secret, otherwise is scheduled for deletion up to 30 days, can cause problem if you re-run your infraestrucutre after destroy
aws secretsmanager delete-secret   --secret-id dev/grafana/admin-password   --force-delete-without-recovery   --region eu-south-2




terraform state list | grep -E "helm_release|kubernetes_|kubectl_"
terraform state rm module.platform.helm_release.external_secrets

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
# Exec in specific container
kubectl exec -i <POD_NAME> -c <CONTAINER_NAME> -n <NAMESPACE> -- <COMMAND>
# Open shell in container via pod instance name
kubectl exec -it db-connectivity-tester-7d49b846f4-x9z2p -c my-app-container -n dev -- /bin/sh
# Print injected variables
kubectl exec -it db-connectivity-tester-6f6b464dbb-vblpk -n db-connectivity-tester -- printenv | grep -E "host|username|password"
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

kubectl exec -i deployment/kube-prometheus-stack-grafana -n monitoring -c grafana -- wget -qO- http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/-/ready

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

#############
#### CRD ####
#############
kubectl get crd rollouts.argoproj.io



# disbale auto sync so the value change persist and is not detected by argo until you sync manually
argocd app set <APP_NAME> --sync-policy manual

##############
### LABELS ###
#############
kubectl get pod <nombre-del-pod> -o jsonpath='{.metadata.labels}'

##################
#### PODS ####
##################
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager
# Get container from pod
kubectl get pod -n kube-system -l k8s-app=aws-node -o jsonpath='{.items[*].spec.containers[*].name}'
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[*].spec.initContainers[*].name}'
kubectl get pods --field-selector spec.nodeName=<NODE_NAME> --all-namespaces
# Get specific pod containers
kubectl get pod  aws-node-nzshf -n kube-system -o jsonpath='{.spec.containers[*].name}'
kubectl get applications.argoproj.io -A # Get Argo applications in all namespaces
# Delete Pod
kubectl delete pod -n dev db-connectivity-tester-57d658cf8c-nqjpn

###################
#### GET NODES ####
###################

# Get nodes table with karpenter pool/ASG group info
kubectl get nodes -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels."karpenter\.sh/nodepool",CAPACITY:.metadata.labels."karpenter\.sh/capacity-type",MANAGED-BY:.metadata.labels."eks\.amazonaws\.com/nodegroup"

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
#### AUTH ##
############
kubectl auth can-i list deployments --as=system:serviceaccount:argocd:argocd-application-controller -n default
kubectl auth can-i create networkpolicy   --as=system:serviceaccount:argocd:argocd-application-controller   --as-group=argocd:business-operators   -n default

#############
#### AWS ####
#############

#### RDS
aws rds describe-db-instances --region eu-south-2 --query "DBInstances[*].[DBInstanceIdentifier, DBInstanceStatus, Endpoint.Address]" --output table

#### EC2
aws ec2 describe-network-acls --region eu-south-2 --filters "Name=vpc-id,Values=vpc-0665404faa4df3d1" --query "NetworkAcls[*].Entries" --output json
aws ec2 describe-instances --region eu-south-2 --filters "Name=tag:kubernetes.io/cluster/dev-aws-cluster,Values=owned,shared" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text

#### SUBNETS
aws ec2 describe-subnets --query "Subnets[*].[SubnetId,CidrBlock,AvailableIpAddressCount]" --output table
aws ec2 describe-subnets \
  --region eu-south-2 \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXXXXXXXXXXX" \
  --query "Subnets[*].[SubnetId, CidrBlock, AvailabilityZone, AvailableIpAddressCount, MapPublicIpOnLaunch]" \
  --output table


#### ASG
# AWS Auto Scaling Groups (ASGs) Not scaling check
aws autoscaling describe-scaling-activities --region eu-south-2 --max-items 5 --query "Activities[*].[StartTime,StatusCode,StatusMessage]" --output table

#### EKS
aws eks update-addon --cluster-name dev-aws-cluster --addon-name vpc-cni --resolve-conflicts OVERWRITE --region eu-south-2
aws eks list-associated-access-policies --cluster-name dev-aws-cluster --principal-arn arn:aws:iam::555968473487:role/dev-argocd-deployer-role

#### IAM
aws iam list-attached-role-policies --role-name dev-eks-nodes-role --region eu-south-2

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
helm repo add <nombre-repo> <URL-repo>                 # Agregar un repositorio remoto
helm repo update                                        # Actualizar el catálogo local de charts
helm repo list                                          # Listar repositorios configurados
helm search repo <palabra-clave>                        # Buscar un chart en repositorios locales
helm repo remove <nombre-repo>                          # Eliminar un repositorio


# 2. INSPECCIÓN Y RENDERIZADO (DEBUG / GITOPS)
# ------------------------------------------------------------------------------
helm get values <nombre-release> -n <namespace>         # Ver el values.yaml aplicado en un release
helm get manifest <nombre-release> -n <namespace>       # Ver los manifiestos YAML de una release activa
helm get notes <nombre-release> -n <namespace>          # Ver notas e instrucciones posinstalación
helm install <release> <repo>/<chart> -f values.yaml --dry-run --debug -n <namespace> # Simular instalación sin aplicar


# 3. INSTALACIÓN Y DESPLIEGUE
# ------------------------------------------------------------------------------
helm install <release> <repo>/<chart> -n <namespace> --create-namespace                 # Instalar creando namespace
helm install <release> <repo>/<chart> -f values.yaml -n <namespace>                    # Instalar con archivo de valores
helm install <release> <repo>/<chart> --set key=value,key2=value2 -n <namespace>       # Sobrescribir variables por CLI


# 4. ACTUALIZACIÓN Y MANTENIMIENTO (UPGRADES)
# ------------------------------------------------------------------------------
helm upgrade <release> <repo>/<chart> -f values.yaml -n <namespace>                    # Actualizar release existente
helm upgrade --install <release> <repo>/<chart> -f values.yaml -n <namespace> --create-namespace # Upsert (instala o actualiza)
helm upgrade <release> <repo>/<chart> -f values.yaml -n <namespace> --atomic           # Rollback automático si falla
helm upgrade <RELEASE_NAME> <CHART_NAME> -n monitoring --set replicaCount=0 --set autoscaling.enabled=false

# 5. CONSULTAS E HISTORIAL
# ------------------------------------------------------------------------------
helm list -n <namespace>                               # Listar releases en un namespace especifico
helm list -A                                           # Listar releases en TODOS los namespaces
helm history <nombre-release> -n <namespace>           # Ver el historial de revisiones de una release


# 6. ROLLBACK Y RECUPERACIÓN ANTE FALLOS
# ------------------------------------------------------------------------------
helm rollback <nombre-release> <numero-revision> -n <namespace> # Volver a una versión previa (ej: revisión 2)


# 7. DESINSTALACIÓN Y LIMPIEZA
# ------------------------------------------------------------------------------
helm uninstall <nombre-release> -n <namespace>          # Eliminar release y sus recursos en Kubernetes
helm uninstall <nombre-release> --keep-history -n <namespace> # Eliminar manteniendo historial para auditoría



### INFRA SLEEP
kubectl delete nodepool low-cost-pool
terraform destroy --target module.software.kubectl_manifest.karpenter_node_pool --auto-approve
terraform destroy --target module.platform.aws_eks_node_group.private_nodes --auto-approve
