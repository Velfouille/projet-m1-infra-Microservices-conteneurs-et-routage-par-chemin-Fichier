# Doc Techno — StreamFlex

## Présentation du projet

StreamFlex est une plateforme de streaming déployée sur AWS selon une architecture multi-région (us-east-1 active, us-west-2 secours). L'infrastructure est conçue pour être éphémère, reproductible et résiliente.

---

## 1. Infrastructure as Code — AWS CloudFormation

**Stack :** CloudFormation en YAML via des templates modulaires (master → infra → ALB → ECS)

**Pourquoi pas Terraform ?**
Terraform nécessite la gestion d'un état (`terraform.tfstate`) qui complexifie le déploiement éphémère.

**Pourquoi pas AWS CDK ?**
Le CDK génère des rôles IAM implicites qui entrent en conflit avec les Permission Boundaries des environnements de type Learner Lab.

**Choix retenu :** CloudFormation est 100 % déclaratif, transparent, et garantit qu'aucune ressource cachée n'est créée.

---

## 2. Orchestration des conteneurs — Amazon ECS Fargate

**Stack :** ECS Fargate (serverless)

**Pourquoi pas EKS (Kubernetes) ?** Trop lourd pour deux microservices, plan de contrôle facturé en permanence.

**Pourquoi pas ECS sur EC2 ?** Obligation de gérer le provisionnement et le patching des VM.

**Choix retenu :** Fargate est serverless (0.25 vCPU / 512 Mo RAM par tâche), coût minime, délégation totale de la gestion des serveurs à AWS.

---

## 3. Réseau & routage — Application Load Balancer

**Stack :** ALB public avec path-based routing (`/catalog` → port 8080, `/user` → port 5000)

**Pourquoi pas API Gateway ?** Coût à la requête, complexité des VPC Links pour les ressources privées.

**Pourquoi pas NLB ?** Opère au niveau 4 (TCP), ne permet pas le routage par chemin URL.

**Choix retenu :** ALB niveau 7, routage intelligent par chemin, intégration native avec les Security Groups.

---

## 4. Couche données — DynamoDB (Catalog) + Aurora MySQL (User)

**Stack :** DynamoDB (mode Pay-Per-Request) pour le catalogue, Aurora MySQL provisionné (db.t3.medium) pour les utilisateurs, déployés par région.

**Pourquoi ce choix hybride ?** Le catalogue stocke des données produit au format clé-valeur (titre, catégorie, description) — parfait pour DynamoDB (NoSQL, sans schéma fixe). Les utilisateurs ont des données relationnelles structurées (userId, username, plan) qui bénéficient des contraintes et requêtes SQL d'Aurora MySQL.

**Synchronisation cross-région :** Le catalogue est répliqué via DynamoDB Streams + Lambda vers us-west-2. Les données utilisateurs utilisent une réplication **application-level** (dual-write) : chaque `POST /user` et `DELETE /user/:id` en us-east-1 est répliqué asynchrone vers le cluster Aurora west via le paramètre `PEER_DB_HOST`. En situation de failover, la région de secours possède les données répliquées.

**Pourquoi pas DynamoDB pour les deux ?** Uniformiser sur DynamoDB aurait simplifié la réplication mais aurait privé le User API des bénéfices du relationnel (jointures, contraintes d'intégrité, transactions ACID).

---

## 5. Registre d'images — Docker Hub (les deux APIs)

**Stack :** Les deux images sont hébergées sur **Docker Hub** (public).

| Service | Image |
|---|---|
| Catalog API | `velfouille/streamflex-api:catalog-rds` |
| User API | `velfouille/streamflex-api:user-rds` |

**Pourquoi Docker Hub pour les deux ?** 
- Un registre unique et public pour toute l'équipe, sans dépendre d'un compte AWS spécifique
- Pull sans authentification depuis n'importe quel compte AWS ou environnement local
- Pas de réplication cross-region à gérer (Docker Hub est mondialement accessible)

---

## 6. Architecture multi-région — Pilot Light + Auto-Failover

**Stack :** us-east-1 (primaire, NbConteneurs=2), us-west-2 (pilot light, NbConteneurs=0)

**Pourquoi pas une table DynamoDB globale ?** Droits insuffisants sur le LabRole. Solution alternative : DynamoDB Streams + Lambda.

**Comment le failover est automatique ?** Un Route 53 Health Check surveille l'ALB primaire. En cas d'indisponibilité prolongée, une **CloudWatch Alarm** déclenche une **Lambda** qui scale les services ECS de la région secondaire à NbConteneurs=2. Route 53 bascule le DNS automatiquement vers l'ALB west. Quand la région primaire revient, l'alarme repasse en OK, la Lambda scale west à 0, et Route 53 rebascule.

**Choix retenu :** Pilot light côté west (0 conteneur, coût minimal) + Lambda d'auto-failover + Route 53 DNS failover. Le basculement est automatique en ~3-4 minutes. Les scripts `failover.sh` / `failback.sh` sont conservés pour republier le frontend manuellement.

---

## 7. Frontend — Site statique S3

**Stack :** Bucket S3 avec Static Website Hosting, politique publique en lecture

**Choix retenu :** Solution simple, gratuite, et sans serveur pour héberger le portail StreamFlex. Le JavaScript côté client détecte la disponibilité des régions et bascule automatiquement.

---

## 8. Langages et frameworks

| Composant | Technologie |
|---|---|
| Microservices | Node.js + Express |
| Client AWS | `@aws-sdk/client-dynamodb` |
| Lambda sync | Python 3.9 + boto3 |
| Frontend | HTML / CSS / JavaScript vanilla |
| Infrastructure | YAML (CloudFormation) |
| Scripts | Bash |

---

## 9. Schéma d'architecture

```
us-east-1 (ACTIVE)                         us-west-2 (PILOT LIGHT)
  ┌─────────────────────┐                   ┌─────────────────────┐
  │ S3 Frontend (public)│                   │ S3 Frontend (public)│
  └─────────┬───────────┘                   └─────────┬───────────┘
            │ HTTP 80                                 │ HTTP 80
  ┌─────────▼───────────┐                   ┌─────────▼───────────┐
  │ ALB (internet-facing)│                   │ ALB (internet-facing)│
  │  /catalog → ECS:8080 │                   │  /catalog → ECS:8080 │
  │  /user    → ECS:5000 │                   │  /user    → ECS:5000 │
  └─────────┬───────────┘                   └─────────┬───────────┘
            │ SG: 8080/5000 depuis ALB SG              │ (Pilot Light)
  ┌─────────▼───────────┐                   ┌─────────▼───────────┐
  │ ECS Fargate ×2/svc  │                   │ ECS Fargate ×0/svc  │
  │ (subnets privés)    │                   │ (subnets privés)    │
  └──┬──────────────┬───┘                   └──┬──────────────┬───┘
     │              │                          │              │
     ▼              ▼                          ▼              ▼
┌─────────┐  ┌──────────┐              ┌─────────┐  ┌──────────┐
│DynamoDB │  │Aurora    │              │DynamoDB │  │Aurora    │
│Catalog  │  │MySQL User│              │Catalog  │  │MySQL User│
│(Stream→ │  │(SG: 3306 │              │(répliqué│  │(SG: 3306 │
│ Lambda) │  │privés)   │              │depuis   │  │privés +  │
└─────────┘  └──────────┘              │east)    │  │0.0.0.0/0)│
                                        └─────────┘  └──────────┘

Route53 HC (/user/health) ←→ CloudWatch Alarm → SNS → Lambda Auto-Failover
```

Voir aussi `Schéma Infra Streamflex V2.drawio` et `Schéma Infra Streamflex V2.png`.
