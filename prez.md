# StreamFlex — Présentation Orale (3 parties)

> **Vue d'ensemble** : Plateforme de streaming fictive en microservices multi-région sur AWS, avec basculement automatique entre us-east-1 (active) et us-west-2 (secours) en modèle Pilot Light.

---

## Partie 1 — Architecture réseau & microservices

### VPC & sous-réseaux

Chaque région a son propre VPC `10.0.0.0/16` découpé en **4 subnets** :

| Subnet | CIDR | Rôle |
|---|---|---|
| Public AZ1 | `10.0.0.0/24` | ALB (internet-facing) |
| Public AZ2 | `10.0.1.0/24` | ALB (haute disponibilité) |
| Privé AZ1 | `10.0.2.0/24` | ECS Fargate + RDS |
| Privé AZ2 | `10.0.3.0/24` | ECS Fargate + RDS |

- Les conteneurs **n'ont pas d'IP publique** (`AssignPublicIp: DISABLED`)
- L'accès Internet sortant passe par **2 NAT Gateways** (une par AZ)
- **L'ALB est le seul point d'entrée public** → tout le trafic est filtré à un seul endroit

### Les deux microservices

L'ALB route par chemin :

```
/ → frontend S3 (statique)
/catalog* → API Catalog (port 8080)
/user*    → API User (port 5000)
```

**API Catalogue — DynamoDB** (table `streamflex-catalog-db`, clé `id`)
- Données clé-valeur (fiches produit : titre, catégorie, description)
- Pas de relations entre entités → **NoSQL** adapté
- Streams intégrés utilisés pour la réplication cross-région

**API Utilisateurs — Aurora MySQL** (cluster `streamflex-user-cluster`)
- Données relationnelles (compte lié à abonnement, historique, préférences)
- Besoin d'ACID → **Aurora MySQL** adapté
- Migré depuis DynamoDB en cours de projet (contrainte LabRole levée)

### Conteneurisation

- **Node.js 20** (Express) sur **alpine**, déployé sur **ECS Fargate**
- Images hébergées sur **Docker Hub** (public)
- 2 conteneurs par service en région active, 0 en région passive (Pilot Light)

---

## Partie 2 — Réplication cross-région & sécurité

### Réplication DynamoDB (Catalogue)

```
us-east-1                          us-west-2
DynamoDB Table                     DynamoDB Table
  ↓ Stream (NEW_AND_OLD_IMAGES)
  ↓ Lambda (Python, boto3)
  └──────────────→ DynamoDB API ──→ put_item / delete_item
```

- Stream activé sur la table source → capture chaque INSERT / MODIFY / REMOVE
- Lambda `streamflex-dynamodb-sync-stream` lit les événements et les réplique vers west
- **Event-driven**, sans surcharge applicative

### Réplication Aurora MySQL (Utilisateurs)

Mécanisme : **Lambda VPC-enabled** invoquée cross-région :

```
POST /user → east RDS (write local)
          → Lambda.invoke(west, InvocationType='Event')
          → Lambda VPC-enabled (subnets privés west)
          → west RDS (write privé)
```

- La Lambda utilise **pymysql** (via une Lambda layer buildée au déploiement)
- Elle est **VPC-enabled** dans le VPC west → accès direct au RDS west en subnet privé
- Plus besoin de rendre le RDS west public

### Sécurité — 3 cercles de confiance

| Security Group | Règles entrantes |
|---|---|
| **ALB SG** | HTTP (80) depuis `0.0.0.0/0` |
| **ECS SG** | 8080, 5000 depuis ALB SG **uniquement** |
| **RDS SG** | 3306 depuis subnets privés **uniquement** |

- Mots de passe en `NoEcho` dans CloudFormation
- Chiffrement AES-256 par défaut (Aurora, DynamoDB, S3)
- Aucune exposition directe des conteneurs ou de la base à Internet

---

## Partie 3 — Auto-failover & déploiement

### 3.1 Pilot Light — le principe économique

Le modèle **Pilot Light** (veilleuse) est une stratégie de reprise d'activité où l'on maintient une infrastructure minimale dans la région de secours, prête à être activée en quelques minutes.

**Dans notre cas :**

| Ressource | us-east-1 (ACTIVE) | us-west-2 (PILOT LIGHT) |
|---|---|---|
| VPC + subnets | ✅ Déployé | ✅ Déployé |
| ALB + Target Groups | ✅ Déployé | ✅ Déployé |
| RDS Aurora MySQL | ✅ Déployé, avec données | ✅ Déployé, répliqué |
| DynamoDB Catalog | ✅ Déployé, avec données | ✅ Déployé, répliqué |
| Bucket S3 Frontend | ✅ Déployé | ✅ Déployé |
| **ECS Fargate (conteneurs)** | ✅ **2 par service** (actif) | ❌ **0** (coût quasi nul) |

L'idée : l'infrastructure « lourde » (VPC, base de données) est déjà provisionnée en west, mais **aucun compute ne tourne**. Le seul coût de la région passive est celui du stockage (RDS idle, DynamoDB, S3) — négligeable comparé à des serveurs allumés 24/7.

> ⚡ **Gain estimé** : ~70% d'économie par rapport à un déploiement actif/actif classique.

### 3.2 Chaîne d'auto-failover — le déclencheur

Le système est **totalement automatisé**, sans intervention humaine. Voici le flux complet, pièce par pièce :

```
┌─────────────────────────────────────────────────────────────────┐
│                    us-east-1 (ACTIVE)                            │
│                                                                  │
│  Route53 Health Check ──── toutes les 30s ────► GET /user/health │
│       │                                                        │
│       │ 3 échecs consécutifs (~90s)                             │
│       ▼                                                        │
│  CloudWatch Alarm (streamflex-autofailover-alarm)                │
│       │                                                        │
│       │ ALARM STATE                                             │
│       ▼                                                        │
│  SNS Topic (streamflex-autofailover-topic)                       │
│       │                                                        │
│       │ Notification → Invoke Lambda                            │
│       ▼                                                        │
│  Lambda Auto-Failover (Python 3.9, 120s timeout)                │
│       │                                                        │
│       │ boto3 ecs.update_service(desiredCount=2)                │
│       ▼                                                        │
└─────────────────────────────────────────────────────────────────┘
                        │
                        │ Cross-region API call
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│                    us-west-2 (SECOURS)                           │
│                                                                  │
│  ECS Catalog Service : desiredCount 0 → 2                        │
│  ECS User Service    : desiredCount 0 → 2                        │
│       │                                                        │
│       │ Attente stabilité (polling toutes les 5s, max 120s)     │
│       ▼                                                        │
│  Les services sont UP → le trafic ALB west répond maintenant     │
│  Le DNS Route53 bascule automatiquement                          │
└─────────────────────────────────────────────────────────────────┘
```

#### Détail de chaque composant

**1. Route53 Health Check**
- Type : HTTP, toutes les **30 secondes**
- Chemin testé : `/user/health` (renvoie `{"status":"ok"}` + le statut de la réplication)
- Seuil d'échec : **3** (donc ~90s avant déclenchement)
- Si l'ALB east ne répond pas 3 fois de suite → statut `UNHEALTHY`

**2. CloudWatch Alarm**
- Métrique : `HealthCheckStatus` (minimum sur 60s, 3 évaluations)
- Seuil : `< 1` (un health check sain retourne 1)
- Comportement donnée manquante : `breaching` (considéré comme un échec si la métrique disparaît)
- État `ALARM` → notifie le SNS Topic
- État `OK` → notifie aussi le SNS Topic (pour le failback)

**3. SNS Topic**
- Simple canal de notification
- Un **abonnement Lambda** est configuré : le SNS invoque directement la fonction d'auto-failover
- Une **politique de permission** autorise SNS à invoquer la Lambda

**4. Lambda Auto-Failover**
- Runtime : **Python 3.9**, timeout **120 secondes**
- Code inline dans le template CloudFormation (pas de déploiement séparé)
- Elle parse le message SNS pour extraire l'état de l'alarme (`ALARM` ou `OK`)
- Utilise `boto3` pour appeler `ecs.update_service()` en us-west-2

```
ALARM → ecs.update_service(region=west, desiredCount=2)
OK    → ecs.update_service(region=west, desiredCount=0)
```

- Après le scale, elle **attend la stabilité** des services : elle interroge `ecs.describe_services()` toutes les 5s jusqu'à ce que `runningCount == desiredCount`, avec un timeout de 120s.

**5. ECS west scale up**
- Les deux services (Catalog et User) passent de 0 à 2 conteneurs chacun
- Les conteneurs se lancent sur Fargate, rejoignent leurs Target Groups respectifs
- L'ALB west commence à répondre au trafic

> **Temps total estimé** : ~3-4 minutes entre le début de la panne et le service rétabli (90s de détection + ~90s de démarrage Fargate + 30s d'health check ALB).

### 3.3 Failback — retour à la normale

Le failback est **symétrique et automatique** :

1. Quand l'ALB east redevient joignable, le Route53 Health Check repasse en `HEALTHY`
2. La CloudWatch Alarm passe en état **OK**
3. SNS notifie la Lambda avec `alarm_state = "OK"`
4. La Lambda scale les services west à `desiredCount=0`
5. Le DNS rebascule vers l'ALB east

**Aucune intervention manuelle n'est nécessaire** dans le fonctionnement normal.

### 3.4 Runbook de secours — scripts manuels

Les scripts `failover.sh` et `failback.sh` sont le **plan B** si l'auto-failover tombe en panne (Lambda défaillante, permissions IAM révoquées, SNS bloqué, etc.).

Chaque script est **autonome** : il scale l'ECS **et** republie le frontend S3.

```
failover.sh :
  1. aws ecs update-service --desired-count 2 → west (catalog + user)
  2. Attente runningCount=2 (polling 5s, timeout 120s)
  3. sed + aws s3 cp → republie index.html pointant vers west

failback.sh :
  1. aws ecs update-service --desired-count 0 → west (catalog + user)
  2. Attente runningCount=0
  3. sed + aws s3 cp → republie index.html pointant vers east
```

> **Quand les utiliser ?** En cas de panne de l'infrastructure d'auto-failover. Dans le fonctionnement normal, l'auto-failover automatique suffit — les scripts sont une **garantie supplémentaire**.

### 3.5 Frontend — détection côté client

Le frontend `index.html` embarque un **script JavaScript** qui double l'auto-failover :

```
Au chargement :
  1. Tester /health sur l'ALB actif
  2. Si OK → boutons pointent vers l'actif
  3. Si KO → boutons pointent vers le secours

Puis toutes les 30s :
  1. Re-tester /health sur l'ALB actif
  2. Si changement → rebasculer les URLs
```

Avantage : même si le DNS ne bascule pas assez vite, l'utilisateur voit immédiatement la région de secours. Le JS met à jour les URLs des boutons "Catalogue" et "Utilisateurs" dynamiquement.

### 3.6 Infrastructure as Code — CloudFormation

**6 templates YAML modulaires**, chacun responsable d'une couche :

```
streamflex-master.yaml          ← Stack maître (NESTED)
│   Paramètres : NbConteneurs, TeamPrefix, RDSMasterPassword, ...
│   Orchestre les 3 sous-stacks
│
├── streamflex-infra.yaml       ← Couche 1 (RÉSEAU + DONNÉES)
│   VPC, subnets (4), IGW, 2 NAT Gateways, Route Tables
│   DynamoDB Catalog + Stream
│   RDS Aurora MySQL (cluster + instance, db.t3.medium)
│   Lambda de réplication DynamoDB Stream
│   Lambda de réplication User (VPC-enabled west)
│
├── streamflex-alb.yaml         ← Couche 2 (LB)
│   ALB internet-facing
│   2 Target Groups (/catalog → 8080, /user → 5000)
│   Security Groups (ALB, ECS)
│
├── streamflex-ecs.yaml         ← Couche 3 (COMPUTE)
│   Cluster ECS Fargate
│   2 Task Definitions (catalog + user)
│   2 Services (DesiredCount paramétrable)
│   Bucket S3 Frontend (hébergement statique)
│
└── streamflex-autofailover.yaml ← Couche 4 (FAILOVER)
    Route53 Health Check
    CloudWatch Alarm
    SNS Topic + Subscription
    Lambda d'auto-failover
```

**Pourquoi CloudFormation plutôt que Terraform ?**

| Critère | CloudFormation | Terraform |
|---|---|---|
| Apprentissage | Natif AWS, YAML simple | HCL spécifique |
| Rollback | Automatique en cas d'échec | Manuel (state) |
| Gestion d'état | Intégrée (pas de fichier .tfstate) | Fichier distant à gérer |
| Permissions IAM | Explicites (pas de rôles créés implicitement) | Parfois implicites (problème avec Learner Lab) |
| Coût | Gratuit | Gratuit (OSS) |

> **Choix décisif** : Avec les restrictions **Learner Lab** (rôle unique `LabRole`, pas de création de rôles IAM personnalisés), Terraform aurait créé des rôles IAM implicites que le LabRole n'aurait pas pu gérer. CloudFormation utilise `LabRole` directement et fonctionne sans créer de nouveaux rôles.

### 3.7 Scripts de déploiement

`deploy.sh` orchestre le déploiement complet en 5 étapes :

```
1. Bucket S3 pour les templates
2. Build + upload Lambda layer pymysql (2 régions)
3. Upload des 6 templates YAML
4. Déploiement PARALLÈLE des deux régions
   └── east : NbConteneurs=2 (région active)
   └── west : NbConteneurs=0 (Pilot Light)
5. Publication du frontend S3
6. Déploiement de l'auto-failover
```

Particularité : les déploiements east et west tournent **en parallèle** grâce à `&` et `wait` bash — gain de ~30% sur le temps total.

`destroy.sh` suit le chemin inverse en parallélisant aussi :

```
1. Vidage des buckets S3
2. Nettoyage ECS east + west (parallèle)
3. Suppression des stacks east + west (parallèle)
4. Suppression du bucket technique
```

### 3.8 Problèmes rencontrés et solutions (DSv4)

| Problème | Cause | Solution |
|---|---|---|
| Aurora Global Database impossible | LabRole insuffisant | Réplication applicative (Lambda VPC-enabled) |
| RDS cross-région ETIMEDOUT | Subnet privé west pas de route IGW | Lambda VPC-enabled (proxy d'écriture) |
| Health check 404 | Route `/health` sans règle ALB | Ajout de `/user/health` |
| Base `streamflex` inexistante | `DatabaseName` absent du cluster | `CREATE DATABASE IF NOT EXISTS` dans server.js |
| Layer pymysql cross-région impossible | Lambda west ne peut pas lire S3 east | Bucket layer dédié en us-west-2 |

### 3.9 Synthèse des choix techniques

| Problématique | Contrainte | Solution retenue |
|---|---|---|
| Reprise d'activité | Économie + rapidité | **Pilot Light** (infra prête en west, 0 compute) |
| Basculement automatique | Aucune intervention humaine | **Route53 → CloudWatch → SNS → Lambda** (~3-4 min) |
| Réplication catalogue | Données clé-valeur, sans modification API | **DynamoDB Stream + Lambda** (event-driven) |
| Réplication utilisateurs | RDS west en subnet privé | **Lambda VPC-enabled cross-région** avec pymysql |
| Gestion IAM | Pas de création de rôles (Learner Lab) | **CloudFormation** avec `LabRole` direct |
| Hébergement API | Pas de gestion de serveurs | **ECS Fargate** (serverless containers) |
| Déploiement multi-région | Temps long (RDS ~15 min) | **Parallélisation** east + west |
| Sécurité | Moindre privilège | **3 SG** (ALB→ECS→RDS), pas d'IP publique sur les conteneurs |
