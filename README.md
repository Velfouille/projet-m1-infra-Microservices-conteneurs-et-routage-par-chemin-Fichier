# StreamFlex — Architecture Cloud Microservices & Multi-Région

Ce dépôt contient le code d'Infrastructure as Code (IaC) permettant de déployer la plateforme de streaming "StreamFlex". L'architecture est conçue pour héberger deux microservices conteneurisés de manière hautement disponible, sécurisée, et résiliente.

L'infrastructure est pensée pour être **éphémère** : elle peut être déployée en quelques minutes pour des démonstrations ou des tests de reprise sur sinistre (Disaster Recovery) entre les régions `us-east-1` et `us-west-2`, puis détruite intégralement pour optimiser les coûts.

---

## 🏗️ Stack Technologique & Justification des Choix Architecturaux

Le tableau suivant détaille les technologies retenues pour répondre aux exigences de la plateforme, ainsi que l'argumentaire face aux alternatives écartées.

### 1. Infrastructure as Code (IaC) : AWS CloudFormation
* **Le choix :** CloudFormation (via des templates YAML).
* **Les alternatives écartées :** * *Terraform :* Nécessite la gestion d'un fichier d'état (`terraform.tfstate`) qui complexifie le déploiement éphémère si l'état n'est pas stocké proprement dans un bucket S3 distant.
  * *AWS CDK :* Bien que plus concis, le CDK génère des rôles IAM par défaut ("sous le capot") qui peuvent entrer en conflit avec les restrictions strictes (Permission Boundaries) des comptes AWS de type "Learner Lab".
* **L'argumentaire :** CloudFormation offre une approche purement déclarative et transparente. Il permet de s'assurer qu'aucune ressource cachée ou rôle IAM non autorisé n'est créé à l'insu du développeur, ce qui est crucial dans un environnement aux droits restreints.

### 2. Orchestration des Conteneurs : Amazon ECS Fargate
* **Le choix :** Amazon Elastic Container Service (ECS) avec le type de lancement AWS Fargate.
* **Les alternatives écartées :** * *Amazon EKS (Kubernetes) :* Trop lourd et complexe pour deux microservices simples. Le plan de contrôle (Control Plane) d'EKS est facturé en permanence, ce qui est inadapté à un budget restreint.
  * *ECS sur instances EC2 :* Oblige à gérer le provisionnement, la mise à jour (patching) et le scaling des machines virtuelles sous-jacentes.
* **L'argumentaire :** Fargate est une solution 100 % Serverless. Il permet de définir les ressources au strict minimum requis (0.25 vCPU et 512 Mo de RAM par tâche), garantissant une empreinte budgétaire minime tout en déléguant la gestion de la flotte de serveurs à AWS.

### 3. Réseau & Routage : Application Load Balancer (ALB)
* **Le choix :** Un ALB public unique couplé à des règles de routage basées sur le chemin (Path-based routing).
* **Les alternatives écartées :**
  * *Amazon API Gateway :* Excellent pour les microservices purs, mais ajoute une couche de complexité réseau supplémentaire (nécessite des VPC Links pour atteindre des ressources privées) et un coût à la requête qui peut grimper en cas d'attaque DDoS.
  * *Network Load Balancer (NLB) :* Opère au niveau 4 (TCP), ne permettant pas de lire les chemins d'URL (`/catalog` ou `/user`).
* **L'argumentaire :** L'ALB opère au niveau 7 (HTTP/HTTPS) et permet de rediriger intelligemment le trafic vers des *Target Groups* distincts selon l'URL appelée (port 8080 pour le catalogue, port 5000 pour les utilisateurs). Il offre également une intégration native et parfaite avec les Security Groups pour appliquer le principe de moindre privilège.

### 4. Couche Données : DynamoDB & Amazon RDS
* **Le choix :** Amazon DynamoDB (NoSQL) pour le microservice `/catalog` et Amazon RDS PostgreSQL/MySQL (db.t3.micro) pour le microservice `/user`.
* **Les alternatives écartées :**
  * *Amazon Aurora Serverless :* Très performant, mais le coût de démarrage et les restrictions de réplication multi-région sur les comptes à budget limité rendent son utilisation risquée pour des tests.
* **L'argumentaire :** Le catalogue de vidéos est un cas d'usage parfait pour le NoSQL (requêtes rapides et prévisibles). DynamoDB offre un mode de facturation "à la demande" (On-Demand) totalement gratuit lorsque l'API n'est pas sollicitée. RDS permet de conserver l'intégrité relationnelle pour les profils utilisateurs, tout en respectant les consignes de sécurité (Enhanced Monitoring désactivé).

### 5. Registre d'Images : Amazon ECR Public (ou Docker Hub)
* **Le choix :** Hébergement des images Docker sur un registre public.
* **L'alternative écartée :** * *Amazon ECR Privé (avec réplication cross-region) :* La réplication d'un registre privé d'une région à une autre demande des permissions IAM inter-régions souvent bloquées sur les environnements de laboratoire.
* **L'argumentaire :** Utiliser un registre public garantit que lors du test de basculement d'urgence (Crash-test Région) , le cluster ECS démarré en `us-west-2` pourra puller les images de conteneurs instantanément sans rencontrer d'erreurs "Access Denied" liées aux rôles d'exécution Fargate.

---

## 🚀 Déploiement (Procédure de soutenance)

Le déploiement se fait de manière modulaire via la CLI AWS. 

**1. Déploiement de la couche réseau (us-east-1) :**
```bash
aws cloudformation deploy --template-file streamflex-infra.yaml --stack-name StreamFlex-Network --region us-east-1
<<<<<<< HEAD
=======
```

**Pourquoi pas une table global pour dynamodb ?**

problèmes de droits sur le LabRole

**Pourquoi le basculement n'est pas auto-bidirectionnel ?**

Pour vraiment auto-re-basculer, il faudrait :

Route53 Health Check → ❌ LabRole ne l'autorise pas

DNS failover → ❌ Impossible en lab

Polling continu → ⚠️ Possible mais cher en requêtes

**Pourquoi pas RDS ?**

problèmes de droits sur le LabRole
>>>>>>> dev
