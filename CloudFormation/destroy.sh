#!/bin/bash
set -e

### DEBUT MODIFICATION ( ÉQUIPE ) ###
REGION_ACTIVE="us-east-1"
REGION_PASSIVE="us-west-2"
MASTER_STACK_NAME="StreamFlex-Master"

# 1. On demande l'identifiant pour retrouver les bons buckets
echo -n "👋 Entrez vos initiales ou celles de votre équipe (ex: mbn, nox, team1) : "
read TEAM_PREFIX

# 2. Sécurité : on force en minuscules au cas où
TEAM_PREFIX=$(echo "$TEAM_PREFIX" | tr '[:upper:]' '[:lower:]')

# 3. Noms dynamiques alignés sur le script de déploiement
TEMPLATE_BUCKET="s3-streamflex-templates-${TEAM_PREFIX}-${REGION_ACTIVE}" 
FRONTEND_BUCKET_BASE="s3-projet-m1-infra-cloud-${TEAM_PREFIX}"
ECS_CLUSTER_NAME="${PROJECT_NAME:-streamflex}-cluster"
### FIN MODIFICATION ( ÉQUIPE ) ###

echo "🧹 Début de la destruction de l'infrastructure globale Multi-Région pour $TEAM_PREFIX..."

bucket_exists() {
    aws s3api head-bucket --bucket "$1" 2>/dev/null
}

empty_bucket_if_exists() {
    local bucket_name="$1"
    if bucket_exists "$bucket_name"; then
        echo "   Vidage de s3://$bucket_name..."
        aws s3 rm s3://$bucket_name --recursive
    else
        echo "   Bucket absent, ignore : s3://$bucket_name"
    fi
}

stack_exists() {
    local region="$1"
    aws cloudformation describe-stacks \
      --stack-name "$MASTER_STACK_NAME" \
      --region "$region" >/dev/null 2>&1
}

ecs_cluster_exists() {
    local region="$1"
    aws ecs describe-clusters \
      --clusters "$ECS_CLUSTER_NAME" \
      --region "$region" \
      --query "clusters[?status!='INACTIVE']" \
      --output text 2>/dev/null | grep -q "$ECS_CLUSTER_NAME"
}

cleanup_ecs_cluster() {
    local region="$1"
    local services
    local tasks

    if ! ecs_cluster_exists "$region"; then
        echo "   Cluster ECS absent, ignore : $ECS_CLUSTER_NAME en $region"
        return 0
    fi

    echo "   Nettoyage ECS en $region ($ECS_CLUSTER_NAME)..."

    services=$(aws ecs list-services \
      --cluster "$ECS_CLUSTER_NAME" \
      --region "$region" \
      --query "serviceArns[]" \
      --output text 2>/dev/null || true)

    if [ -n "$services" ]; then
        for service in $services; do
            echo "      Service a 0 puis suppression forcee : $service"
            aws ecs update-service \
              --cluster "$ECS_CLUSTER_NAME" \
              --service "$service" \
              --desired-count 0 \
              --region "$region" >/dev/null || true

            aws ecs delete-service \
              --cluster "$ECS_CLUSTER_NAME" \
              --service "$service" \
              --force \
              --region "$region" >/dev/null || true
        done

        aws ecs wait services-inactive \
          --cluster "$ECS_CLUSTER_NAME" \
          --services $services \
          --region "$region" || true
    else
        echo "      Aucun service ECS restant."
    fi

    tasks=$(aws ecs list-tasks \
      --cluster "$ECS_CLUSTER_NAME" \
      --region "$region" \
      --query "taskArns[]" \
      --output text 2>/dev/null || true)

    if [ -n "$tasks" ]; then
        for task in $tasks; do
            echo "      Arret de la tache restante : $task"
            aws ecs stop-task \
              --cluster "$ECS_CLUSTER_NAME" \
              --task "$task" \
              --region "$region" \
              --reason "StreamFlex destroy cleanup" >/dev/null || true
        done

        aws ecs wait tasks-stopped \
          --cluster "$ECS_CLUSTER_NAME" \
          --tasks $tasks \
          --region "$region" || true
    else
        echo "      Aucune tache ECS restante."
    fi
}

delete_stack_if_exists() {
    local region="$1"
    if stack_exists "$region"; then
        echo "   Demande de suppression de $MASTER_STACK_NAME en $region..."
        aws cloudformation delete-stack --stack-name "$MASTER_STACK_NAME" --region "$region"
    else
        echo "   Stack absente, ignore : $MASTER_STACK_NAME en $region"
    fi
}

wait_stack_delete() {
    local region="$1"
    if ! stack_exists "$region"; then
        return 0
    fi

    if aws cloudformation wait stack-delete-complete --stack-name "$MASTER_STACK_NAME" --region "$region"; then
        echo "   Stack supprimee en $region."
        return 0
    fi

    echo "   Echec de suppression en $region. Statut CloudFormation actuel :"
    aws cloudformation describe-stacks \
      --stack-name "$MASTER_STACK_NAME" \
      --region "$region" \
      --query "Stacks[0].{Status:StackStatus,Reason:StackStatusReason}" \
      --output table || true

    echo "   Derniers evenements d'erreur en $region :"
    aws cloudformation describe-stack-events \
      --stack-name "$MASTER_STACK_NAME" \
      --region "$region" \
      --query "StackEvents[?contains(ResourceStatus, 'FAILED')].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]" \
      --output table || true

    return 1
}

echo "🗑️  0/2 : Vidage des buckets S3 pour autoriser la suppression..."
# Vidage des deux buckets Front (Actif et Passif)
empty_bucket_if_exists "${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}"
empty_bucket_if_exists "${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}"
empty_bucket_if_exists "$TEMPLATE_BUCKET"

echo "🧯 0.5/2 : Nettoyage des services/taches ECS restants..."
cleanup_ecs_cluster "$REGION_PASSIVE"
cleanup_ecs_cluster "$REGION_ACTIVE"

echo "🔥 1/2 : Suppression des Master Stacks (ECS, ALB, RDS, Réseau)..."
delete_stack_if_exists "$REGION_PASSIVE"
delete_stack_if_exists "$REGION_ACTIVE"

echo "⏳ Attente de la destruction (cela peut prendre 10 à 15 minutes)..."
DELETE_FAILED=0
wait_stack_delete "$REGION_PASSIVE" || DELETE_FAILED=1
wait_stack_delete "$REGION_ACTIVE" || DELETE_FAILED=1

if [ "$DELETE_FAILED" -ne 0 ]; then
    echo "------------------------------------------------------"
    echo "❌ Destruction incomplete : au moins une stack est en DELETE_FAILED."
    echo "Regarde les evenements CloudFormation affiches au-dessus pour savoir quelle ressource bloque."
    echo "Cas probable ici : une ressource supprimee manuellement, comme l'ALB east-1, a mis la stack en drift."
    echo "------------------------------------------------------"
    exit 1
fi

echo "📦 2/2 : Suppression du bucket technique S3..."
if bucket_exists "$TEMPLATE_BUCKET"; then
    aws s3 rb s3://$TEMPLATE_BUCKET --force
else
    echo "   Bucket technique deja absent : s3://$TEMPLATE_BUCKET"
fi

echo "------------------------------------------------------"
echo "✅ Destruction multi-région terminée avec succès !"
echo "Plus aucune ressource n'est active, ta facturation est à zéro."
echo "------------------------------------------------------"
