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

## 4. Couche données — DynamoDB + Lambda

**Stack :** DynamoDB (mode Pay-Per-Request) pour les deux microservices

**Pourquoi pas RDS MySQL ?** Le choix initial prévoyait DynamoDB pour le catalogue (données produit au format clé-valeur, adaptées au NoSQL) et RDS MySQL pour les utilisateurs (données relationnelles structurées). Cependant, le LabRole de l'environnement Learner Lab ne dispose pas des permissions nécessaires pour créer des instances RDS.

**Choix retenu :** DynamoDB pour les deux services, en mode On-Demand = gratuit au repos. Cette uniformité présente un avantage : la synchronisation cross-région est cohérente et simple via DynamoDB Streams + Lambda pour les deux tables. Le bloc RDS reste présent mais commenté dans `streamflex-infra.yaml` pour référence si le projet était déployé dans un environnement AWS complet.

---

## 5. Registre d'images — Docker Hub (public)

**Stack :** Images Docker hébergées sur Docker Hub (`velfouille/streamflex-api:catalog` et `:user`)

**Pourquoi pas ECR privé avec réplication cross-region ?** La réplication inter-régions d'ECR nécessite des permissions IAM souvent bloquées en environnement Learner Lab.

**Choix retenu :** Un registre public garantit que la région de secours peut puller les images sans erreur "Access Denied".

---

## 6. Architecture multi-région — Pilot Light

**Stack :** us-east-1 (active, NbConteneurs=2), us-west-2 (pilot light, NbConteneurs=0)

**Pourquoi pas une table DynamoDB globale ?** Droits insuffisants sur le LabRole. Solution alternative : DynamoDB Streams + Lambda.

**Pourquoi le failover n'est pas auto-bidirectionnel ?** Route53 Health Check et DNS failover sont bloqués par le LabRole.

**Choix retenu :** Déploiement manuel via scripts shell (`failover.sh` / `failback.sh`) qui ajustent le nombre de conteneurs et republient le frontend.

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

Voir `Schéma Infra Streamflex V2.drawio` et `Schéma Infra Streamflex V2.png`.
