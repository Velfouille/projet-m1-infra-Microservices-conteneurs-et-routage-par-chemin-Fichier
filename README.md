# README — StreamFlex

## 1. Fonctionnement du projet

### Architecture globale

L'infrastructure StreamFlex est déployée sur **deux régions AWS** (us-east-1 active, us-west-2 secours) selon le modèle **Pilot Light** :

```
                            us-east-1 (ACTIVE)                         us-west-2 (PILOT LIGHT)
    ┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
    │  S3 Frontend (bucket public)              │   │  S3 Frontend (bucket public)              │
    │       ↑                                    │   │       ↑                                  │
    │  ┌── ALB ── SG : HTTP(80) 0.0.0.0/0 ──┐  │   │  ┌── ALB ── SG : HTTP(80) 0.0.0.0/0 ──┐  │
    │  │   ├── /catalog → ECS Fargate × 2    │  │   │  │   ├── /catalog → ECS Fargate × 0    │  │
    │  │   └── /user    → ECS Fargate × 2    │  │   │  │   └── /user    → ECS Fargate × 0    │  │
    │  └──── ECS SG : 8080/5000 depuis ALB ──┘  │   │  └──── ECS SG : 8080/5000 depuis ALB ──┘  │
    │         │              │                   │   │         │              │                  │
    │         ▼              ▼                   │   │         ▼              ▼                  │
    │   DynamoDB Catalog   ┌─ RDS ──────────┐   │   │   DynamoDB Catalog   ┌─ RDS ──────────┐   │
    │   (Stream → Sync ─── │ Aurora MySQL    │   │   │   (répliqué depuis  │ Aurora MySQL    │   │
    │   Lambda → west)    │ SG: 3306 subnets│   │   │   east via Stream)  │ SG: 3306 subnets│   │
    │                      │ privés          │   │   │                     │ privés          │   │
    │                      └─────────────────┘   │   │                     └─────────────────┘   │
    │                                            │   │                          ↑               │
    └──────────────────────────────────────────┘   │   └── Lambda VPC-enabled ──┘               │
                           │   Réplication User API (POST/DELETE via Lambda.invoke cross-region) │
                           │   └── east ECS → API AWS → Lambda west VPC → west RDS (privé)     │
                           └────────── Route53 Health Check (/user/health) ───────────────────┘
                                                        ↓
                                          CloudWatch Alarm → SNS → Lambda Auto-Failover
                                               (scale ECS west: 0→2 en ALARM, 2→0 en OK)
```

- **us-east-1 (ACTIVE)** : VPC complet, 2 conteneurs Fargate par service, RDS Aurora MySQL, ALB, frontend S3
- **us-west-2 (SECOURS)** : VPC complet, 0 conteneur (coût minimal), ALB présent, bases de données prêtes, frontend S3

![Architecture globale](https://github.com/Velfouille/projet-m1-infra-Microservices-conteneurs-et-routage-par-chemin-Fichier/blob/main/Sch%C3%A9ma%20Infra%20Streamflex%20V2.png)

### Stacks CloudFormation

Le déploiement est modulaire, avec **5 templates YAML** :

```
streamflex-master.yaml          ← Stack maître (orchestre les sous-stacks)
├── streamflex-infra.yaml       ← Couche réseau (VPC, subnets, IGW, NAT, DynamoDB, RDS Aurora)
├── streamflex-alb.yaml         ← Couche ALB (load balancer, target groups, security groups)
├── streamflex-ecs.yaml         ← Couche ECS (cluster Fargate, services, frontend S3)
└── streamflex-autofailover.yaml ← Auto-failover (Lambda + SNS + CloudWatch Alarm + Route53 Health Check)
```

### Microservices

| Service | Port | Endpoint | Technologie | Base de données |
|---|---|---|---|---|
| Catalog API | 8080 | `/catalog` | Node.js / Express | DynamoDB `streamflex-catalog-db` |
| User API | 5000 | `/user` | Node.js / Express | Aurora MySQL (RDS) `streamflex-user-cluster` |

> **Choix des bases de données :** Le catalogue utilise DynamoDB (données produit clé-valeur, adaptées au NoSQL) tandis que les utilisateurs bénéficient d'Aurora MySQL (données relationnelles structurées). Les deux sont déployés dans les deux régions : DynamoDB est synchronisé cross-région via Streams + Lambda ; Aurora MySQL utilise une **Lambda VPC-enabled** dans la région passive, invoquée cross-région depuis l'API User east via le SDK AWS.

### Synchronisation multi-région

#### Catalogue (DynamoDB)

Un Stream DynamoDB est activé sur `streamflex-catalog-db` en us-east-1. Une fonction Lambda écoute les événements (INSERT, MODIFY, REMOVE) et réplique les données vers us-west-2 via l'API DynamoDB.

| Table source | Lambda | Destination |
|---|---|---|
| `streamflex-catalog-db` | `streamflex-dynamodb-sync-stream` | us-west-2 |

#### Users (Aurora MySQL)

La réplication cross-région des utilisateurs utilise une **Lambda VPC-enabled** dans la région passive :

1. La région **active** (us-east-1) déploie l'API User avec **2 conteneurs** Fargate
2. Chaque requête `POST /user` et `DELETE /user/:id` :
   - Écriture locale sur le cluster Aurora MySQL east (via le VPC)
   - Invocation asynchrone de la Lambda `streamflex-user-replication` en **us-west-2** via `Lambda.invoke()` (SDK AWS)
3. La Lambda, **VPC-enabled** dans les subnets privés west, exécute la requête SQL sur le cluster Aurora MySQL west
4. Les lectures (`GET /user`) utilisent uniquement la base locale pour la cohérence

| Table source | Mécanisme | Destination |
|---|---|---|
| `streamflex-catalog-db` (DynamoDB) | Stream + Lambda (DynamoDB API) | us-west-2 |
| `streamflex-user-cluster` (Aurora MySQL) | Lambda VPC-enabled invoquée cross-région via SDK | us-west-2 |

> ✅ **Avantage** : La Lambda étant dans le VPC west (subnets privés), elle accède directement au RDS west sans exposition publique. Plus besoin de `PublicRDS=true`. La réplication fonctionne via l'API AWS (HTTPS) et non via connexion TCP directe.

### Frontend

Le portail StreamFlex est un site statique hébergé sur S3. Il contient un script JavaScript qui :
- Teste la santé de l'API active au chargement
- Bascule automatiquement les URLs des boutons vers la région de secours si nécessaire
- Interroge la région active toutes les 30 secondes pour détecter le retour à la normale

---

## 2. Prérequis

- Compte AWS avec accès à us-east-1 et us-west-2
- AWS CLI installée et configurée
- Rôle IAM avec permissions suffisantes (EC2, ECS, DynamoDB, S3, Lambda, RDS Aurora, CloudFormation)
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
2. Build et uploade la **Lambda layer pymysql** vers S3
3. Uploade les **6 templates YAML** vers ce bucket
4. Déploie la stack maître en **us-east-1** avec `NbConteneurs=2` (**région active** — conteneurs en marche)
5. Déploie la stack maître en **us-west-2** avec `NbConteneurs=0` (**région passive** — Pilot Light, coût minimal)
   - La Lambda `streamflex-user-replication` (VPC-enabled) est créée dans les deux régions
6. Récupère les URLs des deux ALB
7. Génère les fichiers `index.html` dynamiques (substitution des variables `{{ALB_URL}}`, `{{ALB_URL_PASSIVE}}`, `{{REGION_NAME}}`)
8. Uploade le frontend vers les buckets S3 des deux régions
9. Déploie la stack **StreamFlex-AutoFailover** (Lambda + SNS + CloudWatch Alarm + Route53 Health Check)
10. Affiche les URLs finales :

```
🌍 PORTAIL FRONT-END :
   - Principal : http://s3-projet-m1-infra-cloud-{prefix}-us-east-1.s3-website-us-east-1.amazonaws.com
   - Secours   : http://s3-projet-m1-infra-cloud-{prefix}-us-west-2.s3-website-us-west-2.amazonaws.com
⚙️  ALB (APIs) :
   - Primary  : http://{alb-dns-us-east-1}
   - Secondary : http://{alb-dns-us-west-2}
```

### Étape 3 : Builder et pusher les images Docker (si modification des APIs)

Les deux images sont hébergées sur **Docker Hub** (public). Aucune authentification AWS nécessaire.

**Catalog API** :

```bash
cd streamflex-apis/catalog-api
docker build -t <dockerhub_username>/streamflex-api:catalog-rds .
docker push <dockerhub_username>/streamflex-api:catalog-rds
```

Puis mettre à jour `Image:` dans `streamflex-ecs.yaml` (CatalogTaskDefinition).

**User API** :

```bash
cd streamflex-apis/user-api
docker build -t <dockerhub_username>/streamflex-api:user-rds .
docker push <dockerhub_username>/streamflex-api:user-rds
```

Puis mettre à jour `Image:` dans `streamflex-ecs.yaml` (UserTaskDefinition).

| Service | Image actuelle |
|---|---|
| Catalog API | `velfouille/streamflex-api:catalog-rds` |
| User API | `velfouille/streamflex-api:user-rds` |

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

## 4. Validation de la synchronisation DynamoDB (Catalog)

Après déploiement, vérifier que la réplication cross-région du catalogue fonctionne.

### 4.1 Insérer des données dans la région active

```bash
# Catalogue
aws dynamodb put-item \
  --table-name streamflex-catalog-db \
  --item '{"id":{"S":"v-test"},"title":{"S":"Film test"},"category":{"S":"Action"}}' \
  --region us-east-1
```

### 4.2 Vérifier la réplication en us-west-2

```bash
aws dynamodb get-item \
  --table-name streamflex-catalog-db \
  --key '{"id":{"S":"v-test"}}' \
  --region us-west-2
```

### 4.3 Vérifier les logs Lambda

```bash
aws logs tail /aws/lambda/streamflex-dynamodb-sync-stream --region us-east-1
ou
MSYS_NO_PATHCONV=1 aws logs tail /aws/lambda/streamflex-dynamodb-sync-stream --region us-east-1
```

### 4.4 Tester le User API (Aurora MySQL)

```bash
# Lister les utilisateurs
curl http://<alb-url>/user

# Créer un utilisateur
curl -X POST http://<alb-url>/user \
  -H "Content-Type: application/json" \
  -d '{"userId":"u1","username":"alice","plan":"premium"}'
```

### 4.5 Validation de la réplication RDS (User)

La réplication des utilisateurs vers us-west-2 utilise une **Lambda VPC-enabled** invoquée cross-région. Pour valider :

```bash
# 1. Créer un utilisateur via l'API east
curl -X POST http://<alb-east>/user \
  -H "Content-Type: application/json" \
  -d '{"userId":"u-replication-test","username":"test","plan":"premium"}'

# 2. Vérifier les logs de la Lambda de réplication en west
aws logs tail /aws/lambda/streamflex-user-replication --region us-west-2

# 3. Vérifier les données directement dans le west (via conteneur Docker mysql)
RDS_WEST=$(aws rds describe-db-clusters --region us-west-2 \
  --query "DBClusters[?DBClusterIdentifier=='streamflex-user-cluster'].Endpoint" --output text)
docker run --rm mysql:8.0 mysql -h "$RDS_WEST" -u admin -pStreamflexAdmin123 \
  -D streamflex -e "SELECT userId, username, plan FROM users;"

# 4. Vérifier que la réponse API mentionne la réplication
curl -s http://<alb-east>/user/health | python3 -m json.tool
# → "replication": "lambda-configured"
```

Le health check retourne `"replication": "lambda-configured"` quand la réplication est active.

### 4.6 Test CRUD complet avec réplication

```bash
# Créer
curl -X POST http://<alb-east>/user \
  -H "Content-Type: application/json" \
  -d '{"userId":"u-crud-test","username":"crud","plan":"basic"}'

# Lire (local seulement)
curl http://<alb-east>/user

# Supprimer (répliqué vers west)
curl -X DELETE http://<alb-east>/user/u-crud-test

# Vérifier les 3 invocations Lambda
aws logs tail /aws/lambda/streamflex-user-replication --region us-west-2 \
  --since 5m | grep -E "START|END|ERROR"
```

Chaque `POST` et `DELETE` génère une invocation Lambda asynchrone (`InvocationType: Event`) vers us-west-2. Les logs doivent montrer 3 `START`/`END` sans erreur.

---

## 5. Destruction de l'infrastructure

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

**Temps estimé :** 10 à 15 minutes (principalement dû à la suppression des stacks CloudFormation).

**En cas d'échec :** La stack passe en `DELETE_FAILED`. Le script affiche les événements d'erreur. Vérifier :
- Un bucket S3 n'a pas été vidé correctement
- Une ressource a été supprimée manuellement (drift)
- Des permissions IAM manquent

---

## 6. Basculement automatique (Auto-Failover)

### Architecture

Le failover est entièrement automatisé via `streamflex-autofailover.yaml` :

```
us-east-1 (ACTIVE)  ←→  Route53 Health Check (/user/health)  ←→  CloudWatch Alarm
  NbConteneurs=2                       ↓  (ALARM/OK)
                                SNS Topic
                                    ↓
                          Lambda auto-failover
                                    ↓
                      us-west-2 (PILOT LIGHT)
                        NbConteneurs=0 → 2 (failover)
                        NbConteneurs=2 → 0 (failback)
```

### Fonctionnement

1. La région primaire (**us-east-1**) tourne en permanence avec **NbConteneurs=2**
2. La région secondaire (**us-west-2**) est en pilot light avec **NbConteneurs=0** (coût minimal)
3. Route 53 vérifie la santé de l'ALB primaire via `/user/health` toutes les 30s
4. Si l'ALB est injoignable pendant 3 périodes consécutives (~90s), la **CloudWatch Alarm** se déclenche
5. L'alarme envoie une notification **SNS** → déclenche la **Lambda d'auto-failover**
6. La Lambda scale les services ECS de west à **NbConteneurs=2**
7. Route 53 bascule le DNS vers l'ALB west (automatique)

### Retour à la normale (Failback)

Quand la région primaire redevient joignable :
1. Le Route 53 Health Check redevient vert
2. La CloudWatch Alarm passe en état **OK**
3. La Lambda scale les services west à **NbConteneurs=0**
4. Route 53 rebascule le DNS vers l'ALB east (automatique)

**Aucune intervention manuelle n'est nécessaire.**

### Runbook de contingence — scripts manuels

Les scripts `failover.sh` et `failback.sh` constituent le **runbook de contingence** : une porte de sortie manuelle si l'auto-failover tombait en panne (Lambda défaillante, permissions IAM révoquées, etc.).

Chaque script est **autonome** : il scale l'ECS **et** republie le frontend :

| Script | ECS west | Frontend | Usage |
|---|---|---|---|
| `failover.sh` | `desiredCount 0 → 2` + attente `runningCount=2` | Pointe vers west | Activation manuelle de west |
| `failback.sh` | `desiredCount 2 → 0` + attente `runningCount=0` | Pointe vers east (actif) / west (secours) | Retour en Pilot Light |

```bash
cd /TP-PROJET/CloudFormation
./failover.sh   # scale west 0→2 + frontend vers west
./failback.sh   # scale west 2→0 + frontend vers east
```

> **Quand utiliser ces scripts ?** En cas de panne de l'infrastructure d'auto-failover (ex: la Lambda ne répond plus, ou le SNS ne délivre pas le message). Dans le fonctionnement normal, l'auto-failover automatique suffit — les scripts sont une **garantie supplémentaire** pour les opérateurs.
---

## 7. Test du failover et simulation de panne

### 7.1 Test automatique (simulation de panne réelle)

Mettre à 0 les services ECS en us-east-1 pour simuler l'indisponibilité de la région active :

```bash
aws ecs update-service --cluster streamflex-cluster --service streamflex-catalog-svc --desired-count 0 --region us-east-1
aws ecs update-service --cluster streamflex-cluster --service streamflex-user-svc --desired-count 0 --region us-east-1
```

**Ce qui se passe :**
1. Le Route53 Health Check (toutes les 30s) détecte que l'ALB ne répond plus sur `/user/health`
2. Après 3 échecs consécutifs (~90s), la CloudWatch Alarm `streamflex-autofailover-alarm` passe en état **ALARM**
3. L'alarme notifie le SNS Topic → déclenche la Lambda `streamflex-autofailover`
4. La Lambda scale les services ECS en **us-west-2** à `desired-count=2`

### 7.2 Surveillance en temps réel

Observer la Lambda d'auto-failover s'exécuter :

```bash
# Activer le polling des logs Lambda
aws logs tail /aws/lambda/streamflex-autofailover --follow --region us-east-1
```

Vérifier que les services passent de 0 à 2 conteneurs en us-west-2 :

```bash
aws ecs describe-services \
  --cluster streamflex-cluster \
  --services streamflex-catalog-svc streamflex-user-svc \
  --region us-west-2 \
  --query "services[].{Service:serviceName, Desired:desiredCount, Running:runningCount}"
```

Vérifier l'état de l'alarme CloudWatch :

```bash
aws cloudwatch describe-alarms \
  --alarm-names streamflex-autofailover-alarm \
  --region us-east-1 \
  --query "MetricAlarms[].{Name:AlarmName, State:StateValue, Reason:StateReason}"
```

### 7.3 Vérification du basculement

Tester que l'API répond toujours via la région passive :

```bash
# Récupérer l'URL ALB passive
ALB_PASSIVE=$(aws cloudformation describe-stacks \
  --stack-name StreamFlex-Master \
  --region us-west-2 \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

# Tester les endpoints
curl -s $ALB_PASSIVE/user/health
curl -s $ALB_PASSIVE/catalog
curl -s $ALB_PASSIVE/user
```

### 7.4 Restauration (failback)

Remettre les services actifs en marche pour simuler le retour à la normale :

```bash
aws ecs update-service --cluster streamflex-cluster --service streamflex-catalog-svc --desired-count 2 --region us-east-1
aws ecs update-service --cluster streamflex-cluster --service streamflex-user-svc --desired-count 2 --region us-east-1
```

**Ce qui se passe :**
1. Le Route53 Health Check détecte le retour de l'ALB actif
2. La CloudWatch Alarm passe en état **OK**
3. La Lambda scale les services west à `desired-count=0` (retour en Pilot Light)
4. Route53 rebascule le DNS vers l'ALB east

### 7.5 Test manuel (contingence)

Les scripts `failover.sh` / `failback.sh` permettent de tester le runbook de contingence :

```bash
cd /TP-PROJET/CloudFormation
echo "mathias" | ./failover.sh   # scale west 0→2 + frontend vers west
echo "mathias" | ./failback.sh   # scale west 2→0 + frontend vers east
```

Chaque script effectue dans l'ordre :
1. **Scaling ECS** — `update-service --desired-count` (2 pour failover, 0 pour failback)
2. **Attente de stabilité** — polling `runningCount` jusqu'à 120s max
3. **Publication frontend** — génération et upload du `index.html` vers les buckets S3

### 7.6 Test de la bascule client-side (JS)

Le frontend embarque un mécanisme de détection automatique :

1. Ouvrir le portail frontend et la console navigateur (F12 → Console/Network)
2. Le JS interroge `/health` sur l'ALB actif toutes les 30s
3. Bloquer temporairement l'URL ALB active dans le navigateur (ex: via un bloqueur de requêtes ou en coupant la résolution DNS localement)
4. Observer dans la console le message : *"Basculement actif : Vous êtes sur la région de secours"*
5. Débloquer la requête → le JS détecte le retour et rebascule automatiquement

---

## 8. Que faire en cas de panne

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
4. Si la région active est injoignable, le failover automatique via Route53 + CloudWatch + Lambda prend le relais (~90s). En cas de panne de l'auto-failover, lancer `./failover.sh` (scale west 0→2 + publication frontend)

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

### Panne : Problème de synchronisation DynamoDB cross-région (Catalog)

1. Vérifier que le Stream DynamoDB est bien activé sur la table :
   ```bash
   aws dynamodb describe-table --table-name streamflex-catalog-db --region us-east-1 --query "Table.StreamSpecification"
   ```
2. Vérifier les logs de la Lambda de synchronisation dans CloudWatch :
   ```bash
   aws logs tail /aws/lambda/streamflex-dynamodb-sync-stream --region us-east-1
   ```
3. Forcer une synchronisation manuelle : insérer une entrée dans la table us-east-1 et vérifier sa présence dans us-west-2 (voir section 4)

### Panne : Connexion RDS Aurora MySQL (User API)

1. Vérifier que le cluster Aurora est bien créé dans la région :
   ```bash
   aws rds describe-db-clusters --region us-east-1 --query "DBClusters[?DBClusterIdentifier=='streamflex-user-cluster']"
   ```
2. Vérifier les logs du conteneur User :
   ```bash
   aws logs tail /ecs/streamflex-user-task --region us-east-1
   ```
3. La table `users` est créée automatiquement au démarrage de l'API. Vérifier avec :
   ```bash
   curl http://<alb-url>/health
   ```

---

## 9. Architecture de sécurité

### 9.1 Schéma des flux réseau et Security Groups

```
                           INTERNET
                              │
                              ▼
                     ╔══════════════════╗
                     ║  ALB Security    ║  ← HTTP (80) depuis 0.0.0.0/0
                     ║  Group           ║
                     ╚════╤═════════════╝
                          │
               ┌──────────┼──────────┐
               │  TCP:8080 │ TCP:5000 │
               ▼          │          ▼
        ┌──────────────────┼──────────────────┐
        │     ECS Security Group              │
        │  (trafic UNIQUEMENT depuis ALB SG)  │
        └──────┬──────────────────────┬───────┘
               │                      │
               ▼                      ▼
      ┌─────────────────┐   ┌─────────────────┐
      │  Catalog API     │   │  User API        │
      │  (ECS Fargate)   │   │  (ECS Fargate)   │
      │  Port 8080       │   │  Port 5000       │
      └────────┬─────────┘   └────────┬─────────┘
               │                      │
               │              ┌───────┴────────┐
               │              │ RDS Security   │
               │              │ Group          │
               │              │ MySQL (3306)   │
               │              │ depuis Subnets │
               │              │ privés (10.0.2 │
               │              │ .0/24, 10.0.3  │
               │              │ .0/24)         │
               │              └───────┬────────┘
               │                      │
               ▼                      ▼
      ┌─────────────────┐   ┌─────────────────┐
      │  DynamoDB        │   │  Aurora MySQL   │
      │  Catalog         │   │  User (RDS)     │
      │  (AWS géré)      │   │  (subnets privés│
      └─────────────────┘   └─────────────────┘
```

**Légende des flux :**
- Ligne pleine → trafic autorisé par Security Group
- ~~Ligne barrée~~ → accès bloqué (ex: Internet → ECS direct)

---

### 9.2 Security Groups détaillés

| Security Group | Ressource protégée | Règles entrantes | Justification |
|---|---|---|---|
| **ALBSecurityGroup** | ALB (Load Balancer) | HTTP (80) depuis 0.0.0.0/0 | L'ALB doit être accessible depuis Internet pour exposer les APIs |
| **ECSSecurityGroup** | Conteneurs ECS Fargate | TCP 8080 depuis ALBSG, TCP 5000 depuis ALBSG | Seul l'ALB peut joindre les conteneurs ; pas d'accès direct depuis Internet |
| **RDSSecurityGroup** | Cluster Aurora MySQL | MySQL (3306) depuis 10.0.2.0/24 et 10.0.3.0/24 | Seuls les subnets privés (contenant les ECS) peuvent accéder à la base |
| **PublicRDSAccess** (west only) | Cluster Aurora MySQL west | MySQL (3306) depuis 0.0.0.0/0 | Nécessaire pour la réplication cross-région (l'East ECS → NAT → Internet → West RDS) |

**Aucune règle sortante restrictive n'est définie** (default `Allow All` outbound) car les conteneurs ECS doivent pouvoir :
- Télécharger les images Docker depuis Docker Hub (443)
- Écrire les logs dans CloudWatch Logs (443)
- Interroger DynamoDB (443)
- Joindre le peer RDS west via Internet (pour la réplication cross-région)

---

### 9.3 Isolation réseau (VPC)

| Couche | Subnets | Accès Internet | Accès direct depuis Internet |
|---|---|---|---|
| **ALB** | Publics (10.0.0.0/24, 10.0.1.0/24) | Oui (via IGW) | Oui (port 80) |
| **ECS Fargate** | Privés (10.0.2.0/24, 10.0.3.0/24) | Sortant via NAT Gateway | Non 🔒 |
| **Aurora MySQL** | Privés (via DBSubnetGroup) | Non | Non 🔒 |
| **DynamoDB** | AWS géré (hors VPC) | N/A | Non (accès via API signée) |

Les conteneurs ECS sont déployés dans des **subnets privés** sans IP publique (`AssignPublicIp: DISABLED`). Ils accèdent à Internet via les NAT Gateways pour les mises à jour et appels sortants.

---

### 9.4 Chiffrement

| Ressource | Chiffrement au repos | Chiffrement en transit |
|---|---|---|
| Aurora MySQL | Activé par défaut (AES-256) | TLS entre ECS et RDS (MySQL native) |
| DynamoDB Catalog | Activé par défaut (AWS owned key) | TLS (API AWS signée) |
| Buckets S3 (frontend) | SSE-S3 (AES-256) | TLS (HTTPS pour upload) |
| Bucket S3 (templates) | SSE-S3 (AES-256) | TLS (HTTPS) |

Note : Le frontend est servi en HTTP (S3 Static Website), ce qui est volontaire pour simuler un site web public sans HTTPS (projet pédagogique).

---

### 9.5 Gestion des identités et accès (IAM)

En environnement **AWS Learner Lab**, le seul rôle disponible est `LabRole`. Tous les composants (ECS Fargate, Lambda, CloudFormation) utilisent ce rôle.

Dans un environnement de production, les rôles suivants seraient créés (principe du moindre privilège) :

| Rôle IAM proposé | Services accessibles | Justification |
|---|---|---|
| `StreamFlexFargateCatalogRole` | DynamoDB (GetItem, PutItem, Query, Scan) | Le service Catalog ne fait que lire/écrire dans DynamoDB |
| `StreamFlexFargateUserRole` | Aucun service AWS (connexion directe à RDS via TCP) | Le service User se connecte directement à MySQL via le driver |
| `StreamFlexFailoverRole` | ECS (UpdateService, DescribeServices) | La Lambda de failover ne fait que scaler les services ECS |
| `StreamFlexAdminRole` | Administrateur CloudFormation + tous les services | Déploiement initial et maintenance |

Règles appliquées actuellement avec `LabRole` :
- Les tâches Fargate utilisent `ExecutionRoleArn: LabRole` pour puller les images Docker et écrire dans CloudWatch Logs
- La Lambda de synchronisation DynamoDB utilise `LabRole` avec des permissions étendues
- La Lambda d'auto-failover utilise `LabRole` pour scaler les services ECS

---

### 9.6 Sécurisation des buckets S3

| Bucket | Politique d'accès | Justification |
|---|---|---|
| `s3-streamflex-templates-{prefix}-us-east-1` | Privé (bloqué par défaut) | Contient les templates CloudFormation (infrastructure critique) |
| `s3-projet-m1-infra-cloud-{prefix}-{region}` | Public (GetObject pour tout le monde) | Simule un site web public accessible sans authentification |

Le bucket frontend est volontairement public (pédagogique). En production, on utiliserait **CloudFront** avec **Origin Access Control (OAC)** pour servir le frontend de manière sécurisée.

---

### 9.7 Auto-failover et sécurité

- Le **Route53 Health Check** vérifie l'ALB east toutes les 30s (HTTP GET /user/health)
- La **Lambda d'auto-failover** ne peut que modifier le `desiredCount` des services ECS (permissions limitées)
- Le topic **SNS** est interne au projet (pas de souscription externe)
- En cas d'ALARM, la Lambda scale west de 0 à 2 conteneurs ; en cas d'OK, elle scale west de 2 à 0

**Aucune exposition publique** de la Lambda ou du topic SNS.

---

### 9.8 Bonnes pratiques et limitations connues

**Ce qui est sécurisé :**
- ✅ ECS en subnets privés (pas d'IP publique)
- ✅ RDS accessible uniquement depuis les subnets privés (ou Internet pour west en cross-region)
- ✅ L'ALB est le seul point d'entrée public vers les APIs
- ✅ Chiffrement au repos sur toutes les bases de données
- ✅ Aucune clé ou secret en clair dans les templates (NoEcho sur les mots de passe)
- ✅ Le bucket de templates est privé

**Ce qui pourrait être amélioré (hors scope du projet pédagogique) :**
- ⬜ HTTPS (certificat ACM + TLS sur l'ALB)
- ⬜ CloudFront + WAF devant l'ALB
- ⬜ Rôles IAM dédiés (moindre privilège) au lieu de LabRole
- ⬜ VPC Endpoints (Gateway pour S3, Interface pour DynamoDB/CloudWatch) pour éviter le trafic via Internet
- ⬜ AWS Shield Advanced (protection DDoS)
- ⬜ AWS Config pour la conformité continue
- ⬜ GuardDuty pour la détection d'intrusion
- ⬜ Règles d'egress restrictives sur les Security Groups

---

### 9.9 Référence : étude IAM complète

Voir le fichier `etude-iam.md` pour l'étude détaillée des rôles IAM, politiques associées et matrice des accès.
