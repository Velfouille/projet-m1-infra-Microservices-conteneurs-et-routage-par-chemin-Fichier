# Doc — StreamFlex

## 1. Fonctionnement du projet

### Architecture globale

```
                         ┌──────────────────────────────────────────────┐
                         │           us-east-1 (ACTIVE)                 │
                         │                                              │
                         │  ┌─────┐   ┌──────────────────┐             │
                         │  │ S3  │   │      ALB         │             │
                         │  │portal│   │ /catalog → :8080 │             │
                         │  │      │   │   /user  → :5000 │             │
                         │  └──────┘   └────────┬─────────┘             │
                         │                      │                       │
                         │             ┌────────┴────────┐              │
                         │             │ ECS Fargate      │              │
                         │         ┌───┤ (2 conteneurs)   ├───┐          │
                         │         │   └────────┬─────────┘   │          │
                         │         │            │             │          │
                         │   ┌─────┴─────┐ ┌────┴──────┐     │          │
                         │   │ :8080     │ │ :5000     │     │          │
                         │   │ catalog   │ │ user      │     │          │
                         │   │ Node.js   │ │ Node.js   │     │          │
                         │   └─────┬─────┘ └────┬──────┘     │          │
                         │         │            │             │          │
                         │   ┌─────┴────────────┴──────┐      │          │
                         │   │    DynamoDB × 2         │      │          │
                         │   │  catalog-db / user-db   │      │          │
                         │   └──────────┬──────────────┘      │          │
                         │              │ DynamoDB Streams    │          │
                         │              ▼                     │          │
                         │   ┌──────────────────┐             │          │
                         │   │  Lambda sync     │             │          │
                         │   └──────────────────┘             │          │
                         └──────────────────────────────────────────────┘
                                              │
                                    Réplication DynamoDB
                                              │
                         ┌──────────────────────────────────────────────┐
                         │           us-west-2 (PILOT LIGHT)            │
                         │   NbConteneurs=0 (désactivé par défaut)     │
                         │   DynamoDB répliqué depuis us-east-1         │
                         └──────────────────────────────────────────────┘
```

### Stacks CloudFormation

Le déploiement est modulaire, avec 4 templates YAML :

```
streamflex-master.yaml  ← Stack maître (orchestre les 3 sous-stacks)
├── streamflex-infra.yaml  ← Couche réseau (VPC, subnets, IGW, NAT, DynamoDB, Lambda)
├── streamflex-alb.yaml    ← Couche ALB (load balancer, target groups, security groups)
└── streamflex-ecs.yaml    ← Couche ECS (cluster Fargate, services, frontend S3)
```

### Microservices

| Service | Port | Endpoint | Technologie | Base de données |
|---|---|---|---|---|
| Catalog API | 8080 | `/catalog` | Node.js / Express | DynamoDB `streamflex-catalog-db` |
| User API | 5000 | `/user` | Node.js / Express | DynamoDB `streamflex-user-db` |

### Synchronisation multi-région

Un Stream DynamoDB est activé sur `streamflex-catalog-db` en us-east-1. Une fonction Lambda écoute les événements (INSERT, MODIFY, REMOVE) et réplique les données vers us-west-2 via l'API DynamoDB.

### Frontend

Le portail StreamFlex est un site statique hébergé sur S3. Il contient un script JavaScript qui :
- Teste la santé de l'API active au chargement
- Bascule automatiquement les URLs des boutons vers la région de secours si nécessaire
- Période la région active toutes les 30 secondes pour détecter le retour à la normale

---

## 2. Prérequis

- Compte AWS avec accès à us-east-1 et us-west-2
- AWS CLI installée et configurée
- Rôle IAM avec permissions suffisantes (EC2, ECS, DynamoDB, S3, Lambda, CloudFormation)
- Git
- Docker (optionnel, pour builder les images)

---

## 3. Déploiement

### Étape 1 : Cloner le dépôt

```bash
git clone <url-du-depot> /TP-PROJET
cd /TP-PROJET/CloudFormation
```

### Étape 2 : Lancer le déploiement

```bash
chmod +x deploy.sh
./deploy.sh
```

Le script vous demande vos initiales (ex: `mbn`, `team1`, etc.) puis :

1. Crée un bucket S3 pour stocker les templates (s3-streamflex-templates-{prefix}-us-east-1)
2. Uploade les 4 templates YAML vers ce bucket
3. Déploie la stack maître en **us-east-1** avec NbConteneurs=2 (mode actif)
4. Déploie la stack maître en **us-west-2** avec NbConteneurs=0 (mode pilot light)
5. Récupère les URLs des deux ALB
6. Génère les fichiers `index.html` dynamiques (substitution des variables)
7. Uploade le frontend vers les buckets S3 des deux régions
8. Affiche les URLs finales :

```
🌍 PORTAIL FRONT-END :
   - Principal : http://s3-projet-m1-infra-cloud-{prefix}-us-east-1.s3-website-us-east-1.amazonaws.com
   - Secours   : http://s3-projet-m1-infra-cloud-{prefix}-us-west-2.s3-website-us-west-2.amazonaws.com
⚙️  ALB (APIs) :
   - Active  : http://{alb-dns-us-east-1}
   - Passive : http://{alb-dns-us-west-2}
```

### Étape 3 : Builder et pusher les images Docker (si modification des APIs)

```bash
cd streamflex-apis/catalog-api
docker build -t <dockerhub_username>/streamflex-api:catalog .
docker push <dockerhub_username>/streamflex-api:catalog

cd ../user-api
docker build -t <dockerhub_username>/streamflex-api:user .
docker push <dockerhub_username>/streamflex-api:user
```

Puis mettre à jour l'image dans `streamflex-ecs.yaml` (ligne `Image:` sous `CatalogTaskDefinition` et `UserTaskDefinition`) et relancer `deploy.sh`.

### Étape 4 : Tester

Ouvrir le portail front-end, cliquer sur "Catalogue" ou "Utilisateurs". Utiliser l'API directement :

```bash
# Catalogue
curl http://<alb-url>/catalog
curl -X POST http://<alb-url>/catalog \
  -H "Content-Type: application/json" \
  -d '{"id":"v1","title":"Mon film","category":"Action"}'

# Utilisateurs
curl http://<alb-url>/user
curl -X POST http://<alb-url>/user \
  -H "Content-Type: application/json" \
  -d '{"userId":"u1","username":"alice","plan":"premium"}'
```

---

## 4. Destruction de l'infrastructure

```bash
cd /TP-PROJET/CloudFormation
chmod +x destroy.sh
./destroy.sh
```

Ce script :

1. Vide les buckets S3 (nécessaire avant suppression CloudFormation)
2. Supprime les services et tâches ECS dans les deux régions
3. Supprime les stacks CloudFormation (master → ECS → ALB → infra) dans les deux régions
4. Supprime le bucket de templates S3

**Temps estimé :** 10 à 15 minutes (surtout à cause de la suppression RDS si décommenté).

**En cas d'échec :** La stack passe en `DELETE_FAILED`. Le script affiche les événements d'erreur. Vérifier :
- Un bucket S3 n'a pas été vidé correctement
- Une ressource a été supprimée manuellement (drift)
- Des permissions IAM manquent

---

## 5. Procédure de basculement (Failover)

### Bascule vers la région de secours

```bash
cd /TP-PROJET/CloudFormation
./failover.sh
```

Ce script :
1. Met à jour la stack us-west-2 avec NbConteneurs=2 (démarre les services)
2. Récupère l'URL de l'ALB de secours
3. Republie le frontend sur les deux buckets S3 avec l'ALB de secours comme endpoint principal

### Retour vers la région nominale

```bash
cd /TP-PROJET/CloudFormation
./failback.sh
```

Ce script :
1. Remet la région active (us-east-1) avec NbConteneurs=2
2. Remet la région passive (us-west-2) avec NbConteneurs=0 (pilot light)
3. Republie le frontend sur les deux buckets S3 avec l'ALB active comme endpoint principal

---

## 6. Que faire en cas de panne

### Panne : Le déploiement échoue

1. Vérifier les logs CloudFormation :
   ```bash
   aws cloudformation describe-stack-events \
     --stack-name StreamFlex-Master \
     --region us-east-1 \
     --query "StackEvents[?contains(ResourceStatus, 'FAILED')]"
   ```
2. Causes fréquentes :
   - **Bucket S3 déjà existant** : choisir un autre préfixe d'équipe
   - **LabRole insuffisant** : certaines actions peuvent être bloquées (RDS, certaines permissions IAM)
   - **Limites de compte AWS** : trop de VPCs, trop d'Elastic IPs (max 5 par défaut)
3. Solution : corriger le problème, puis `./destroy.sh` et `./deploy.sh`

### Panne : Les APIs ne répondent pas

1. Vérifier la santé des services ECS :
   ```bash
   aws ecs describe-services \
     --cluster streamflex-cluster \
     --services streamflex-catalog-svc streamflex-user-svc \
     --region us-east-1
   ```
2. Vérifier que l'ALB est accessible :
   ```bash
   curl http://<alb-url>/health
   ```
3. Vérifier les logs CloudWatch :
   ```bash
   aws logs describe-log-groups --region us-east-1
   aws logs tail /ecs/streamflex-catalog-task --region us-east-1
   ```
4. Si la région active est injoignable, lancer `./failover.sh`

### Panne : Le frontend S3 ne s'affiche pas

1. Vérifier que le bucket est bien configuré en Static Website Hosting :
   ```bash
   aws s3api get-bucket-website \
     --bucket s3-projet-m1-infra-cloud-{prefix}-{region}
   ```
2. Vérifier la politique du bucket (lecture publique)
3. Accéder directement à l'URL du bucket :
   ```
   http://s3-projet-m1-infra-cloud-{prefix}-us-east-1.s3-website-us-east-1.amazonaws.com
   ```

### Panne : Destruction bloquée (DELETE_FAILED)

1. Identifier la ressource qui bloque via les événements CloudFormation (le script les affiche automatiquement)
2. Causes possibles :
   - **Bucket S3 non vide** : le script vide automatiquement les buckets, mais une réécriture concurrente peut interférer
   - **Dépendance non résolue** : un ALB supprimé manuellement met la stack en drift
3. Solution manuelle : supprimer la stack via la console AWS après avoir nettoyé les ressources bloquantes

### Panne : Problème de synchronisation DynamoDB cross-région

1. Vérifier que le Stream DynamoDB est bien activé sur `streamflex-catalog-db`
2. Vérifier les logs de la fonction Lambda `streamflex-dynamodb-sync-stream` dans CloudWatch
3. Forcer une synchronisation manuelle si nécessaire via un script ad-hoc

---

## 7. Architecture de sécurité (IAM)

Voir le fichier `etude-iam.md` pour l'étude complète. Résumé des rôles proposés :

| Rôle IAM | Usage |
|---|---|
| StreamFlexAdminRole | Administration complète |
| StreamFlexDevOpsRole | Déploiement et maintenance |
| StreamFlexFargateCatalogRole | Accès DynamoDB Catalog |
| StreamFlexFargateUserRole | Accès RDS et Secrets Manager |
| StreamFlexFailoverRole | Gestion de la reprise d'activité |
| CloudFront Access Role | Lecture sécurisée du frontend S3 |

*Note : En environnement Learner Lab, le seul rôle disponible est `LabRole`. Les déploiements utilisent donc `LabRole` pour l'exécution Fargate.*
