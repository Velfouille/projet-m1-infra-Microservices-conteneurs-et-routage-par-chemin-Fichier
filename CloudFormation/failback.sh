#!/bin/bash
set -e

REGION_ACTIVE="us-east-1"
REGION_PASSIVE="us-west-2"
MASTER_STACK_NAME="StreamFlex-Master"
ECS_CLUSTER="streamflex-cluster"
SERVICES=("streamflex-catalog-svc" "streamflex-user-svc")

echo -n "Entrez vos initiales ou celles de votre equipe (ex: mbn, nox, team1) : "
read TEAM_PREFIX
TEAM_PREFIX=$(echo "$TEAM_PREFIX" | tr '[:upper:]' '[:lower:]')

TEMPLATE_BUCKET="s3-streamflex-templates-${TEAM_PREFIX}-${REGION_ACTIVE}"
FRONTEND_BUCKET_BASE="s3-projet-m1-infra-cloud-${TEAM_PREFIX}"

echo "1/4 - Passage des services ECS west à desiredCount=0..."
for svc in "${SERVICES[@]}"; do
  echo "  Scaling $svc dans $REGION_PASSIVE..."
  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$svc" \
    --desired-count 0 \
    --region "$REGION_PASSIVE" \
    --output text --query 'service.desiredCount'
done

echo "2/4 - Attente d'arret des services west..."
for svc in "${SERVICES[@]}"; do
  echo -n "  $svc : "
  for attempt in $(seq 1 24); do
    COUNT=$(aws ecs describe-services \
      --cluster "$ECS_CLUSTER" \
      --services "$svc" \
      --region "$REGION_PASSIVE" \
      --query "services[0].runningCount" \
      --output text 2>/dev/null || echo "1")
    if [ "$COUNT" = "0" ]; then
      echo "OK (runningCount=0)"
      break
    fi
    echo -n "."
    sleep 5
  done
done

echo "3/4 - Recuperation des URLs ALB..."
ALB_URL_ACTIVE=$(aws cloudformation describe-stacks \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_ACTIVE \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

ALB_URL_PASSIVE=$(aws cloudformation describe-stacks \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

echo "4/4 - Publication du frontend en mode normal..."
sed \
  -e "s|{{ALB_URL}}|$ALB_URL_ACTIVE|g" \
  -e "s|{{ALB_URL_PASSIVE}}|$ALB_URL_PASSIVE|g" \
  -e "s/{{REGION_NAME}}/$REGION_ACTIVE (ACTIVE)/g" \
  ../index.html > index_active.html

sed \
  -e "s|{{ALB_URL}}|$ALB_URL_ACTIVE|g" \
  -e "s|{{ALB_URL_PASSIVE}}|$ALB_URL_PASSIVE|g" \
  -e "s/{{REGION_NAME}}/$REGION_PASSIVE (SECOURS)/g" \
  ../index.html > index_passive.html

aws s3 cp index_active.html s3://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0"
aws s3 cp index_passive.html s3://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0"
rm index_active.html index_passive.html

echo "------------------------------------------------------"
echo "Retour nominal termine."
echo "  ECS west : desiredCount 2 -> 0"
echo "  Frontend : pointe vers $REGION_ACTIVE (est) / $REGION_PASSIVE (ouest)"
echo "  Route 53 : DNS failover automatique actif"
echo "Frontend : http://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}.s3-website-${REGION_ACTIVE}.amazonaws.com"
echo "------------------------------------------------------"
