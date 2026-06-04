#!/bin/bash
set -e

### DEBUT MODIFICATION ( ÉQUIPE ) ###
REGION_ACTIVE="us-east-1"
REGION_PASSIVE="us-west-2"
MASTER_STACK_NAME="StreamFlex-Master"

# 1. On demande à l'utilisateur de s'identifier
echo -n "👋 Entrez vos initiales ou celles de votre équipe (ex: mbn, nox, team1) : "
read TEAM_PREFIX

# 2. Sécurité : On force la mise en minuscules (S3 interdit strictement les majuscules)
TEAM_PREFIX=$(echo "$TEAM_PREFIX" | tr '[:upper:]' '[:lower:]')

# 3. On génère les noms de buckets dynamiquement avec cet identifiant
TEMPLATE_BUCKET="s3-streamflex-templates-${TEAM_PREFIX}-${REGION_ACTIVE}" 
FRONTEND_BUCKET_BASE="s3-projet-m1-infra-cloud-${TEAM_PREFIX}"
### FIN MODIFICATION ( ÉQUIPE ) ###

echo "🚀 Démarrage du déploiement Multi-Région StreamFlex pour $TEAM_PREFIX..."

echo "🪣  0/4 : Création du bucket de templates global..."
# On vérifie si le bucket existe, sinon on le crée
if aws s3api head-bucket --bucket "$TEMPLATE_BUCKET" 2>/dev/null; then
    echo "✅ Le bucket $TEMPLATE_BUCKET existe déjà."
else
    echo "🔨 Création du bucket $TEMPLATE_BUCKET..."
    aws s3 mb s3://$TEMPLATE_BUCKET --region $REGION_ACTIVE
fi

echo "📁 1/4 : Upload des templates YAML vers S3..."
aws s3 cp streamflex-infra.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-alb.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-ecs.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-master.yaml s3://$TEMPLATE_BUCKET/

### DEBUT MODIFICATION ( NOÉ) ###
echo "🏗️  2/4 : Déploiement de la région ACTIVE ($REGION_ACTIVE)..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_ACTIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=2 TeamPrefix=$TEAM_PREFIX \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

echo "🏗️  3/4 : Déploiement de la région PASSIVE ($REGION_PASSIVE - Pilot Light)..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=0 TeamPrefix=$TEAM_PREFIX \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

# Récupération des URLs pour les DEUX régions (on le fait AVANT l'étape 4 maintenant)
echo "🔍 Récupération des URLs ALB..."
ALB_URL_ACTIVE=$(aws cloudformation describe-stacks --stack-name $MASTER_STACK_NAME --region $REGION_ACTIVE --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" --output text)
ALB_URL_PASSIVE=$(aws cloudformation describe-stacks --stack-name $MASTER_STACK_NAME --region $REGION_PASSIVE --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" --output text)

echo "🌐 4/4 : Préparation et envoi des fichiers index.html dynamiques..."

# Pour la région ACTIVE : on remplace les balises avec les 2 URLs (active + passive)
sed -e "s|{{ALB_URL}}|$ALB_URL_ACTIVE|g" -e "s|{{ALB_URL_PASSIVE}}|$ALB_URL_PASSIVE|g" -e "s/{{REGION_NAME}}/$REGION_ACTIVE (ACTIVE)/g" ../index.html > index_active.html
aws s3 cp index_active.html s3://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0"

# Pour la région PASSIVE : on remplace les balises (même contenu, c'est le frontend qui décide)
sed -e "s|{{ALB_URL}}|$ALB_URL_ACTIVE|g" -e "s|{{ALB_URL_PASSIVE}}|$ALB_URL_PASSIVE|g" -e "s/{{REGION_NAME}}/$REGION_PASSIVE (SECOURS)/g" ../index.html > index_passive.html
aws s3 cp index_passive.html s3://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0"

# Nettoyage des fichiers temporaires
rm index_active.html index_passive.html

echo "------------------------------------------------------"
echo "🎉 PROJET MULTI-RÉGION TERMINÉ ! Voici tes liens :"
echo "🌍 PORTAIL FRONT-END :"
echo " - Principal : http://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}.s3-website-${REGION_ACTIVE}.amazonaws.com"
echo " - Secours   : http://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}.s3-website-${REGION_PASSIVE}.amazonaws.com"
echo "⚙️  ALB (APIs) :"
echo " - Active  : http://$ALB_URL_ACTIVE"
echo " - Passive : http://$ALB_URL_PASSIVE (Attention, 0 conteneur démarré !)"
echo "------------------------------------------------------"
### FIN MODIFICATION ( NOÉ) ###
