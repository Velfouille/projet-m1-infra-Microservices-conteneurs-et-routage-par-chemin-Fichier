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

echo "1/4 - Recuperation de l'ALB de secours (${REGION_PASSIVE})..."
ALB_URL_PASSIVE=$(aws cloudformation describe-stacks \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

echo "2/4 - Recuperation de l'ALB actif (${REGION_ACTIVE})..."
ALB_URL_ACTIVE=$(aws cloudformation describe-stacks \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_ACTIVE \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

echo "3/4 - Publication du frontend pointant vers la region de secours..."
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
echo "Le trafic API est bascule vers $REGION_PASSIVE."
echo "Route 53 assure le DNS failover automatique."
echo "Frontend : http://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}.s3-website-${REGION_ACTIVE}.amazonaws.com"
echo "------------------------------------------------------"
