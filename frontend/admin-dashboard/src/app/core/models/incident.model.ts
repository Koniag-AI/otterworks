export type IncidentSource = 'manual' | 'servicenow' | 'grafana';

export interface Incident {
  id: string;
  title: string;
  description: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  status: 'open' | 'investigating' | 'resolved' | 'closed';
  affectedService: string | null;
  devinSessionId: string | null;
  devinSessionUrl: string | null;
  devinSessionStatus: string | null;
  reporterId: string | null;
  resolvedAt: string | null;
  closedAt: string | null;
  active: boolean;
  source: IncidentSource;
  servicenowSysId: string | null;
  servicenowNumber: string | null;
  createdAt: string;
  updatedAt: string;
}

export const INCIDENT_SOURCES: { value: IncidentSource; label: string; icon: string }[] = [
  { value: 'manual', label: 'Manual', icon: 'person' },
  { value: 'servicenow', label: 'ServiceNow', icon: 'cloud' },
  { value: 'grafana', label: 'Grafana', icon: 'monitoring' },
];

export const AFFECTED_SERVICES = [
  { value: 'api-gateway', label: 'API Gateway (Go)' },
  { value: 'auth-service', label: 'Auth Service (Java)' },
  { value: 'file-service', label: 'File Service (Rust)' },
  { value: 'document-service', label: 'Document Service (Python)' },
  { value: 'collab-service', label: 'Collaboration Service (Node.js)' },
  { value: 'notification-service', label: 'Notification Service (Kotlin)' },
  { value: 'search-service', label: 'Search Service (Python)' },
  { value: 'analytics-service', label: 'Analytics Service (Scala)' },
  { value: 'admin-service', label: 'Admin Service (Ruby)' },
  { value: 'audit-service', label: 'Audit Service (C#)' },
  { value: 'report-service', label: 'Report Service (Java)' },
];
