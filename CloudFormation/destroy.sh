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
### FIN MODIFICATION ( ÉQUIPE ) ###

echo "🧹 Début de la destruction de l'infrastructure globale Multi-Région pour $TEAM_PREFIX..."

echo "🗑️  0/2 : Vidage des buckets S3 pour autoriser la suppression..."
# Vidage des deux buckets Front (Actif et Passif)
aws s3 rm s3://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE} --recursive || true
aws s3 rm s3://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE} --recursive || true
aws s3 rm s3://$TEMPLATE_BUCKET --recursive || true

echo "🔥 1/2 : Suppression des Master Stacks (ECS, ALB, RDS, Réseau) en parallèle..."
# Le petit '&' à la fin permet de lancer la suppression des deux régions en même temps
aws cloudformation delete-stack --stack-name $MASTER_STACK_NAME --region $REGION_PASSIVE &
aws cloudformation delete-stack --stack-name $MASTER_STACK_NAME --region $REGION_ACTIVE &

echo "⏳ Attente de la destruction (cela peut prendre 10 à 15 minutes, surtout à cause de la base RDS)..."
aws cloudformation wait stack-delete-complete --stack-name $MASTER_STACK_NAME --region $REGION_PASSIVE
aws cloudformation wait stack-delete-complete --stack-name $MASTER_STACK_NAME --region $REGION_ACTIVE

echo "📦 2/2 : Suppression du bucket technique S3..."
aws s3 rb s3://$TEMPLATE_BUCKET --force || true

echo "------------------------------------------------------"
echo "✅ Destruction multi-région terminée avec succès !"
echo "Plus aucune ressource n'est active, ta facturation est à zéro."
echo "------------------------------------------------------"