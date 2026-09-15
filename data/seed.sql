-- Seed script for Airbyte validation: sample enterprise dataset for RAG demo
-- Target database: sample_data (created via POSTGRESQL_DATABASE env var)

BEGIN;

-- =============================================================================
-- Documents table: enterprise content for RAG ingestion
-- =============================================================================

CREATE TABLE IF NOT EXISTS documents (
    id         SERIAL PRIMARY KEY,
    title      VARCHAR(255) NOT NULL,
    content    TEXT NOT NULL,
    source     VARCHAR(100) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- Metadata table: key-value pairs linked to documents
-- =============================================================================

CREATE TABLE IF NOT EXISTS metadata (
    id          SERIAL PRIMARY KEY,
    document_id INT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    key         VARCHAR(100) NOT NULL,
    value       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_metadata_document_id ON metadata(document_id);
CREATE INDEX IF NOT EXISTS idx_documents_source ON documents(source);

-- =============================================================================
-- Customers table
-- =============================================================================

CREATE TABLE IF NOT EXISTS customers (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(150) NOT NULL,
    email      VARCHAR(255) NOT NULL UNIQUE,
    company    VARCHAR(200) NOT NULL,
    tier       VARCHAR(20) NOT NULL CHECK (tier IN ('free', 'pro', 'enterprise')),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- Seed documents
-- =============================================================================

INSERT INTO documents (title, content, source, created_at) VALUES

-- Product documentation
('Platform API Authentication Guide',
 'All API requests must include a Bearer token in the Authorization header. Tokens are issued via the /oauth/token endpoint using client_credentials grant type. Tokens expire after 3600 seconds. Refresh tokens are supported for interactive flows. Rate limits apply: 1000 requests per minute for enterprise tier, 200 for pro, and 50 for free tier accounts.',
 'product-docs', '2026-06-15 09:00:00'),

('Data Pipeline Configuration Reference',
 'Pipelines are defined in YAML and support three execution modes: batch, micro-batch, and streaming. Batch pipelines run on a configurable cron schedule. Micro-batch pipelines poll sources every 30-300 seconds. Streaming pipelines use CDC (Change Data Capture) for near-real-time replication. Each pipeline must specify a source, destination, and optional transformation layer.',
 'product-docs', '2026-06-20 14:30:00'),

('Connector SDK Developer Guide',
 'Custom connectors implement the Source or Destination interface. Sources must implement discover() to return the catalog schema, check() for connection validation, and read() to emit AirbyteRecordMessages. Destinations implement write() to consume records. All connectors are packaged as container images and registered in the connector registry.',
 'product-docs', '2026-07-01 10:15:00'),

('Data Transformation with dbt Integration',
 'The platform natively integrates with dbt for post-load transformations. After raw data lands in the destination warehouse, dbt models execute automatically. Supported warehouses for dbt integration include Snowflake, BigQuery, Redshift, and PostgreSQL. Custom dbt projects are mounted via Git repository references in the connection configuration.',
 'product-docs', '2026-07-05 11:00:00'),

-- Knowledge base articles
('Troubleshooting: Connection Timeout Errors',
 'Connection timeouts typically occur when the source database firewall does not allow inbound connections from the platform IP range (10.200.0.0/16). Verify security group rules, check that the source is reachable on the specified port, and ensure SSL certificates are valid if TLS is required. For SSH tunnel configurations, confirm the bastion host is running and the tunnel user has appropriate permissions.',
 'knowledge-base', '2026-07-10 08:45:00'),

('Troubleshooting: Schema Drift Detection',
 'When a source schema changes (new columns, type changes, dropped columns), the platform detects drift during the next sync. Default behavior is to propagate additive changes and flag breaking changes for review. Configure schema_change_policy in the connection settings: propagate_all, propagate_additive, or manual_review. Breaking changes pause the connection until acknowledged.',
 'knowledge-base', '2026-07-12 16:20:00'),

('Best Practices: Incremental Sync Configuration',
 'Incremental syncs reduce load times and resource usage by only transferring new or modified records. Configure a cursor field (e.g., updated_at timestamp or auto-incrementing ID) on each stream. The platform tracks the last cursor value between syncs. For tables without a reliable cursor, consider full-refresh with deduplication using a primary key.',
 'knowledge-base', '2026-07-18 13:00:00'),

('Security: Data Encryption at Rest and in Transit',
 'All data in transit is encrypted with TLS 1.3. Data at rest in the staging area uses AES-256-GCM encryption. Customer-managed encryption keys (CMEK) are supported for enterprise tier accounts via AWS KMS, GCP Cloud KMS, or Azure Key Vault integration. Encryption keys are rotated automatically every 90 days unless a custom rotation policy is configured.',
 'knowledge-base', '2026-07-22 09:30:00'),

-- Meeting notes
('Engineering Sync: Q3 Roadmap Planning',
 'Attendees: Platform team, Data Infra, SRE. Key decisions: 1) Prioritize OpenShift deployment support for enterprise customers with on-prem requirements. 2) Target GA for the new connector marketplace by end of Q3. 3) Investigate vector database destinations (Pinecone, Weaviate, pgvector) for RAG use cases. 4) Allocate 20% of sprint capacity to tech debt reduction. Action items assigned to respective team leads.',
 'meeting-notes', '2026-08-01 15:00:00'),

('Customer Advisory Board: August Session',
 'Top customer requests: 1) Support for Azure Event Hubs as a source connector. 2) Improved observability with OpenTelemetry trace export. 3) Role-based access control (RBAC) at the connection level, not just workspace. 4) SLA guarantees for data freshness on streaming connections. 5) Terraform provider for infrastructure-as-code deployments. NPS score for the quarter: 72 (up from 68).',
 'meeting-notes', '2026-08-05 10:00:00'),

('Incident Retro: Staging Pipeline Outage Aug 12',
 'Root cause: A misconfigured resource limit on the normalization pod caused OOMKill during a large initial sync (450GB dataset). The pod restart loop triggered cascading failures in the job scheduler. Resolution: Increased memory limits for normalization workers from 2Gi to 4Gi, added vertical pod autoscaler recommendations, and implemented circuit breaker logic for scheduler queue overflow. Time to resolution: 2h 15m.',
 'meeting-notes', '2026-08-13 14:00:00'),

-- Architecture docs
('Architecture Decision Record: Adopting Temporal for Orchestration',
 'Context: The existing cron-based scheduler lacks retry semantics, visibility into workflow state, and support for long-running operations. Decision: Adopt Temporal as the workflow orchestration engine. Consequences: Improved reliability through automatic retries with exponential backoff, workflow versioning for safe deploys, and built-in observability via Temporal Web UI. Migration path: dual-run existing scheduler and Temporal for 2 sprints, then cut over.',
 'architecture', '2026-05-20 11:00:00'),

('Architecture Decision Record: Multi-Tenancy Isolation Model',
 'Context: Enterprise customers require strict data isolation guarantees. Decision: Implement namespace-per-tenant isolation in Kubernetes with network policies restricting cross-namespace traffic. Each tenant gets dedicated database schemas and separate encryption keys. Shared infrastructure (control plane, UI) uses JWT-scoped access. Trade-off: higher resource overhead vs. stronger isolation guarantees.',
 'architecture', '2026-06-10 09:00:00'),

-- Runbooks
('Runbook: Deploying to OpenShift with Restricted SCC',
 'Prerequisites: oc CLI authenticated, target namespace created with restricted-v2 SCC. Steps: 1) Apply PVCs for config and data volumes. 2) Deploy PostgreSQL with POSTGRESQL_USER and POSTGRESQL_DATABASE env vars set. 3) Apply platform Helm chart with securityContext.runAsNonRoot=true and no privileged capabilities. 4) Verify pods run under arbitrary UID assigned by OpenShift. 5) Validate network policies allow inter-pod communication on required ports.',
 'runbook', '2026-08-10 08:00:00'),

('Runbook: Disaster Recovery Procedure',
 'RPO target: 1 hour. RTO target: 4 hours. Steps: 1) Identify failure scope (single service vs. cluster-wide). 2) For database recovery, restore from latest automated snapshot in the secondary region. 3) For application recovery, trigger ArgoCD sync against the last known-good Git commit. 4) Validate data integrity by running the consistency checker against source-of-truth databases. 5) Notify affected customers via status page and direct email.',
 'runbook', '2026-08-15 10:00:00'),

-- Policy document
('Data Retention and Compliance Policy',
 'Raw data in staging areas is retained for 72 hours after successful sync, then purged. Audit logs are retained for 365 days. Customer connection credentials are stored in HashiCorp Vault with automatic lease renewal. GDPR data subject access requests must be fulfilled within 30 days. SOC 2 Type II audit is conducted annually. Data residency requirements are enforced at the workspace level with region-locked deployments.',
 'policy', '2026-07-25 09:00:00'),

-- Internal FAQ
('FAQ: How Does the Connector Marketplace Work?',
 'The connector marketplace hosts both official and community-contributed connectors. Official connectors are maintained by the platform team with SLA-backed support. Community connectors are peer-reviewed and must pass the connector acceptance test suite (CAT) before listing. Connectors are versioned independently and support automatic minor-version upgrades. Enterprise customers can pin connector versions and run private connector registries.',
 'internal-faq', '2026-08-20 12:00:00');


-- =============================================================================
-- Seed metadata
-- =============================================================================

INSERT INTO metadata (document_id, key, value) VALUES
-- API Auth Guide
(1, 'category', 'authentication'),
(1, 'audience', 'developers'),
(1, 'status', 'published'),

-- Pipeline Config Reference
(2, 'category', 'configuration'),
(2, 'audience', 'data-engineers'),
(2, 'status', 'published'),

-- Connector SDK Guide
(3, 'category', 'development'),
(3, 'audience', 'developers'),
(3, 'version', '2.4'),

-- dbt Integration
(4, 'category', 'integrations'),
(4, 'audience', 'data-engineers'),
(4, 'status', 'published'),

-- Timeout Troubleshooting
(5, 'category', 'troubleshooting'),
(5, 'priority', 'high'),
(5, 'related_ticket', 'SUP-4921'),

-- Schema Drift
(6, 'category', 'troubleshooting'),
(6, 'priority', 'medium'),

-- Incremental Sync
(7, 'category', 'best-practices'),
(7, 'audience', 'data-engineers'),

-- Encryption
(8, 'category', 'security'),
(8, 'compliance', 'soc2,gdpr,hipaa'),
(8, 'audience', 'security-team'),

-- Q3 Roadmap
(9, 'meeting_type', 'planning'),
(9, 'quarter', 'Q3-2026'),
(9, 'attendees', 'platform-team,data-infra,sre'),

-- CAB Session
(10, 'meeting_type', 'customer-advisory'),
(10, 'nps_score', '72'),

-- Incident Retro
(11, 'meeting_type', 'incident-retro'),
(11, 'severity', 'SEV-2'),
(11, 'ttr_minutes', '135'),

-- Temporal ADR
(12, 'decision_status', 'accepted'),
(12, 'category', 'orchestration'),

-- Multi-Tenancy ADR
(13, 'decision_status', 'accepted'),
(13, 'category', 'isolation'),

-- OpenShift Runbook
(14, 'environment', 'openshift'),
(14, 'category', 'deployment'),
(14, 'last_verified', '2026-08-10'),

-- DR Runbook
(15, 'category', 'disaster-recovery'),
(15, 'rpo_hours', '1'),
(15, 'rto_hours', '4'),

-- Retention Policy
(16, 'category', 'compliance'),
(16, 'review_cycle', 'annual'),
(16, 'owner', 'legal-team'),

-- Marketplace FAQ
(17, 'category', 'marketplace'),
(17, 'audience', 'all');


-- =============================================================================
-- Seed customers
-- =============================================================================

INSERT INTO customers (name, email, company, tier, created_at) VALUES
('Sarah Chen',        'sarah.chen@acmecorp.com',        'Acme Corporation',        'enterprise', '2025-11-01 09:00:00'),
('Marcus Johnson',    'mjohnson@globexinc.com',          'Globex Inc.',             'enterprise', '2025-12-15 14:30:00'),
('Priya Patel',       'priya.patel@initech.io',          'Initech Systems',         'pro',        '2026-01-20 10:00:00'),
('James O''Brien',    'jobrien@wayneenterprises.com',    'Wayne Enterprises',       'enterprise', '2026-02-05 08:45:00'),
('Anika Sorensen',    'anika.s@northwind.dev',           'Northwind Analytics',     'pro',        '2026-03-10 11:15:00'),
('David Kim',         'dkim@contoso.cloud',              'Contoso Cloud Services',  'pro',        '2026-04-01 13:00:00'),
('Elena Vasquez',     'evasquez@fabrikam.co',            'Fabrikam Data Labs',      'free',       '2026-05-18 16:30:00'),
('Raj Krishnamurthy', 'raj.k@tailspintoys.com',          'Tailspin Technologies',   'free',       '2026-06-02 09:30:00'),
('Maria Gonzalez',    'mgonzalez@adventureworks.io',     'AdventureWorks Platform', 'enterprise', '2026-06-28 10:00:00'),
('Thomas Mueller',    'tmueller@datavault.eu',           'DataVault GmbH',          'pro',        '2026-07-15 12:00:00');

COMMIT;
