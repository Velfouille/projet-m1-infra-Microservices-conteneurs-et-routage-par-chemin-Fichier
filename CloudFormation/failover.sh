#!/bin/bash
set -e

REGION_ACTIVE="us-east-1"
REGION_PASSIVE="us-west-2"
MASTER_STACK_NAME="StreamFlex-Master"

echo -n "Entrez vos initiales ou celles de votre equipe (ex: mbn, nox, team1) : "
read TEAM_PREFIX
TEAM_PREFIX=$(echo "$TEAM_PREFIX" | tr '[:upper:]' '[:lower:]')

TEMPLATE_BUCKET="s3-streamflex-templates-${TEAM_PREFIX}-${REGION_ACTIVE}"
FRONTEND_BUCKET_BASE="s3-projet-m1-infra-cloud-${TEAM_PREFIX}"

echo "1/4 - Arret des conteneurs en region active (${REGION_ACTIVE})..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_ACTIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=0 TeamPrefix=$TEAM_PREFIX \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

echo "2/4 - Activation des conteneurs en region de secours (${REGION_PASSIVE})..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=2 TeamPrefix=$TEAM_PREFIX \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

echo "3/4 - Recuperation de l'ALB de secours..."
ALB_URL_PASSIVE=$(aws cloudformation describe-stacks \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

echo "4/4 - Publication du frontend en mode secours..."
sed \
  -e "s|{{ALB_URL}}|$ALB_URL_PASSIVE|g" \
  -e "s|{{ALB_URL_PASSIVE}}|$ALB_URL_PASSIVE|g" \
  -e "s/{{REGION_NAME}}/$REGION_PASSIVE (SECOURS ACTIF)/g" \
  ../index.html > index_failover.html

aws s3 cp index_failover.html s3://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0"
aws s3 cp index_failover.html s3://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0" || true
rm index_failover.html

echo "------------------------------------------------------"
echo "Basculement termine."
echo "PORTAIL FRONT-END :"
echo " - Principal bascule : http://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}.s3-website-${REGION_ACTIVE}.amazonaws.com"
echo " - Secours actif     : http://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}.s3-website-${REGION_PASSIVE}.amazonaws.com"
echo "ALB API :"
echo " - Active arretee    : 0 conteneur"
echo " - Secours actif     : http://$ALB_URL_PASSIVE (4 conteneurs au total)"
echo "------------------------------------------------------"
