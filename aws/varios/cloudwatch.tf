resource "aws_sns_topic" "notificaciones_ops" {
    name = "alertas-operaciones-produccion"
}

# 1. Topic for Critical Alarms (Forces Phone calls + Email)
resource "aws_sns_topic" "critical_alerts" {
    name = "${var.environment}-sns-critical-oncall"
}

# Channel A: Email Subscription attached to Critical Topic
resource "aws_sns_topic_subscription" "critical_email" {
    topic_arn = aws_sns_topic.critical_alerts.arn
    protocol  = "email"
    endpoint  = "contactd@rj-engineering.com" # Change to your team email
}

# Channel B: On-Call Webhook (e.g., PagerDuty/Opsgenie) attached to Critical Topic
resource "aws_sns_topic_subscription" "oncall_webhook" {
    topic_arn              = aws_sns_topic.critical_alerts.arn
    protocol               = "https"
    endpoint               = "https://pagerduty.com"
    endpoint_auto_confirms = true
}


# 2. Topic for Warnings & ChatOps (Teams + Standard Logs)
resource "aws_sns_topic" "warning_alerts" {
    name = "${var.environment}-sns-warning-chatops"
}

# Channel C: Microsoft Teams via Endpoint (or HTTPS Lambda webhook transformer)
resource "aws_sns_topic_subscription" "teams_subscription" {
    topic_arn = aws_sns_topic.warning_alerts.arn
    protocol  = "https"
    endpoint  = "https://your-teams-webhook-bridge-url.com"
}


# Lista de funciones Lambda que quieres monitorizar
variable "funciones_produccion" {
    type    = list(string)
    default = ["prod-login", "prod-pagos", "prod-usuarios"]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errores" {
    for_each            = toset(var.funciones_produccion)
    alarm_name          = "lambda-error-${each.key}"
    comparison_operator = "GreaterThanThreshold"
    evaluation_periods  = 1
    metric_name         = "Errors"
    namespace           = "AWS/Lambda"
    period              = 60
    statistic           = "Sum"
    threshold           = 0

  # Asigna dinámicamente la dimensión a cada recurso
    dimensions = { FunctionName = each.key }
}

resource "aws_cloudwatch_metric_alarm" "rds_espacio_bajo" {
    alarm_name          = "rds-espacio-disco-bajo"
    comparison_operator = "LessThanOrEqualToThreshold"
    evaluation_periods  = 1
    metric_name         = "FreeStorageSpace"
    namespace           = "AWS/RDS"
    period              = 300
    statistic           = "Average"
    threshold           = 21474836480 # 20 GB en Bytes
    alarm_description   = "El espacio en disco de la base de datos RDS es inferior a 20 GB."
    alarm_actions       = [aws_sns_topic.notificaciones_ops.arn]

    dimensions = {
        DBInstanceIdentifier = "db-produccion-master"
    }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errores" {
    alarm_name          = "lambda-errores-produccion"
    comparison_operator = "GreaterThanThreshold"
    evaluation_periods  = 1
    metric_name         = "Errors"
    namespace           = "AWS/Lambda"
    period              = 60
    statistic           = "Sum"
    threshold           = 0 # Salta con un solo error
    alarm_description   = "Fallo detectado en la ejecución de la función Lambda de producción."
    alarm_actions       = [aws_sns_topic.notificaciones_ops.arn]

    # SI NO PONER DIMENSIONS, aplica a todo el servicio Lambda de la región
    dimensions = {
        FunctionName = "mi-funcion-procesamiento"
    }
}

resource "aws_cloudwatch_metric_alarm" "alarma_wildcard_search" {
    alarm_name          = "alarma-dinamica-lambdas-prod"
    comparison_operator = "GreaterThanThreshold"
    evaluation_periods  = 1
    threshold           = 10

    # Esta consulta busca dinámicamente cualquier Lambda que empiece por "prod-"
    metric_query {
        id          = "query_dinamica"
        expression  = "SEARCH('{AWS/Lambda,FunctionName} FunctionName=prod-', 'Sum', 60)"
        label       = "Errores en Lambdas de Producción"
        return_data = true
    }
}





/*


1. EKS Control Plane Metrics (Managed by AWS)

Amazon EKS automatically exposes core control plane health indicators directly to the AWS/EKS CloudWatch namespace. Since you do not manage the control plane servers, Prometheus cannot scrape these directly. You should set CloudWatch alarms on:
• etcd_db_total_size_in_bytes: Alerts you if the etcd database size is approaching the 8 GB hard limit, which would put your cluster in a read-only state.
• apiserver_request_total (Filtered by 4XX/5XX / Throttling): Monitors the health of your Kubernetes API server. A sudden spike in 429 (Too Many Requests) means cluster clients or internal controllers are being throttled.

2. Auto Scaling Groups (ASG) & EC2 Data Planes

While Prometheus tracks inside-the-node resources, CloudWatch tracks the AWS components keeping those nodes alive:
• StatusCheckFailed (EC2): Instantly alerts if an underlying EC2 host hosting your Kubernetes nodes suffers a physical hardware failure.
• GroupInServiceCapacity (Auto Scaling): Triggers an alarm if your EKS cluster nodes crash or fail to scale up to match the minimum required capacity needed for the workload.

3. Integrated AWS Resources Used by EKS Pods

If your apps inside EKS communicate with other AWS services, Prometheus cannot easily visibility-check those boundaries. You should set CloudWatch alarms on:
• Application Load Balancers (ALB Ingress): Monitor HTTPCode_Target_5XX_Count. If your pods crash or return errors, the ingress balance controller will report it first here.
• EBS Persistent Volumes: Monitor VolumeStalledIOCheck to catch if your stateful pods (databases, caches) have stalled I/O due to storage hardware issues.
• AWS KMS / Secrets Manager: Monitor API throttling if your pods fetch decryption keys rapidly during massive autoscaling events.

4. Control Plane Audit Logs

Production EKS setups require turning on EKS Control Plane Logs. CloudWatch Logs allows you to set Metric Filters to alert on security or misconfiguration flags, such as detecting repeated unauthorized cluster access attempts or critical ClusterAutoscaler failures.
 */