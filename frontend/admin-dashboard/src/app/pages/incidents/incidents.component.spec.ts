import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { NoopAnimationsModule } from '@angular/platform-browser/animations';
import { IncidentsComponent } from './incidents.component';
import { Incident } from '../../core/models/incident.model';

describe('IncidentsComponent', () => {
  let component: IncidentsComponent;
  let fixture: ComponentFixture<IncidentsComponent>;
  let httpMock: HttpTestingController;

  const mockIncidents: Incident[] = [
    {
      id: '1',
      title: 'File upload 500',
      description: 'File upload returns 500',
      severity: 'critical',
      status: 'investigating',
      affectedService: 'file-service',
      devinSessionId: 'devin-1',
      devinSessionUrl: 'https://app.devin.ai/sessions/devin-1',
      devinSessionStatus: 'running',
      reporterId: null,
      resolvedAt: null,
      active: true,
      source: 'servicenow',
      servicenowSysId: 'abc123',
      servicenowNumber: 'INC0010042',
      createdAt: '2026-05-18T22:00:00Z',
      updatedAt: '2026-05-18T22:00:00Z',
    },
    {
      id: '2',
      title: 'Search latency',
      description: 'Search service latency spike',
      severity: 'high',
      status: 'open',
      affectedService: 'search-service',
      devinSessionId: null,
      devinSessionUrl: null,
      devinSessionStatus: null,
      reporterId: null,
      resolvedAt: null,
      active: true,
      source: 'grafana',
      servicenowSysId: null,
      servicenowNumber: null,
      createdAt: '2026-05-18T21:00:00Z',
      updatedAt: '2026-05-18T21:00:00Z',
    },
    {
      id: '3',
      title: 'Manual incident',
      description: 'Manually reported incident',
      severity: 'medium',
      status: 'resolved',
      affectedService: 'api-gateway',
      devinSessionId: null,
      devinSessionUrl: null,
      devinSessionStatus: null,
      reporterId: 'user-1',
      resolvedAt: '2026-05-18T23:00:00Z',
      active: false,
      source: 'manual',
      servicenowSysId: null,
      servicenowNumber: null,
      createdAt: '2026-05-18T20:00:00Z',
      updatedAt: '2026-05-18T23:00:00Z',
    },
  ];

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [IncidentsComponent, NoopAnimationsModule],
      providers: [provideHttpClient(), provideHttpClientTesting()],
    }).compileComponents();

    fixture = TestBed.createComponent(IncidentsComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  function flushInitialRequests(): void {
    const autoReq = httpMock.expectOne('/api/v1/admin/settings/auto_investigate');
    autoReq.flush({ enabled: true });

    const incReq = httpMock.expectOne('/api/v1/admin/incidents');
    incReq.flush({ incidents: mockIncidents.map(i => ({
      id: i.id,
      title: i.title,
      description: i.description,
      severity: i.severity,
      status: i.status,
      affected_service: i.affectedService,
      devin_session_id: i.devinSessionId,
      devin_session_url: i.devinSessionUrl,
      devin_session_status: i.devinSessionStatus,
      reporter_id: i.reporterId,
      resolved_at: i.resolvedAt,
      active: i.active,
      source: i.source,
      servicenow_sys_id: i.servicenowSysId,
      servicenow_number: i.servicenowNumber,
      created_at: i.createdAt,
      updated_at: i.updatedAt,
    }))});
  }

  it('should create', () => {
    fixture.detectChanges();
    flushInitialRequests();
    expect(component).toBeTruthy();
  });

  it('should load incidents with source fields', () => {
    fixture.detectChanges();
    flushInitialRequests();
    fixture.detectChanges();

    expect(component.incidents.length).toBe(3);
    expect(component.incidents[0].source).toBe('servicenow');
    expect(component.incidents[0].servicenowNumber).toBe('INC0010042');
    expect(component.incidents[1].source).toBe('grafana');
    expect(component.incidents[2].source).toBe('manual');
  });

  describe('source badge rendering', () => {
    beforeEach(() => {
      fixture.detectChanges();
      flushInitialRequests();
      fixture.detectChanges();
    });

    it('should render source chips for each incident', () => {
      const compiled = fixture.nativeElement as HTMLElement;
      const sourceChips = compiled.querySelectorAll('.source-chip');
      expect(sourceChips.length).toBe(3);
    });

    it('should apply correct CSS class for servicenow source', () => {
      const compiled = fixture.nativeElement as HTMLElement;
      const snChip = compiled.querySelector('.source-servicenow');
      expect(snChip).toBeTruthy();
      expect(snChip?.textContent).toContain('servicenow');
    });

    it('should apply correct CSS class for grafana source', () => {
      const compiled = fixture.nativeElement as HTMLElement;
      const grafanaChip = compiled.querySelector('.source-grafana');
      expect(grafanaChip).toBeTruthy();
    });
  });

  describe('ServiceNow info display', () => {
    beforeEach(() => {
      fixture.detectChanges();
      flushInitialRequests();
      fixture.detectChanges();
    });

    it('should show ServiceNow ticket number for servicenow incidents', () => {
      const compiled = fixture.nativeElement as HTMLElement;
      const snInfo = compiled.querySelector('.servicenow-info');
      expect(snInfo).toBeTruthy();
      expect(snInfo?.textContent).toContain('INC0010042');
    });

    it('should not show ServiceNow info for non-servicenow incidents', () => {
      const compiled = fixture.nativeElement as HTMLElement;
      const snInfoElements = compiled.querySelectorAll('.servicenow-info');
      expect(snInfoElements.length).toBe(1);
    });
  });

  describe('source filtering', () => {
    beforeEach(() => {
      fixture.detectChanges();
      flushInitialRequests();
      fixture.detectChanges();
    });

    it('should show all incidents when no filter is set', () => {
      expect(component.filteredIncidents.length).toBe(3);
    });

    it('should filter by servicenow source', () => {
      component.filterSource = 'servicenow';
      expect(component.filteredIncidents.length).toBe(1);
      expect(component.filteredIncidents[0].source).toBe('servicenow');
    });

    it('should filter by grafana source', () => {
      component.filterSource = 'grafana';
      expect(component.filteredIncidents.length).toBe(1);
      expect(component.filteredIncidents[0].source).toBe('grafana');
    });

    it('should filter by manual source', () => {
      component.filterSource = 'manual';
      expect(component.filteredIncidents.length).toBe(1);
      expect(component.filteredIncidents[0].source).toBe('manual');
    });

    it('should combine source and status filters', () => {
      component.filterSource = 'servicenow';
      component.filterStatus = 'investigating';
      expect(component.filteredIncidents.length).toBe(1);

      component.filterStatus = 'resolved';
      expect(component.filteredIncidents.length).toBe(0);
    });
  });

  describe('getSourceIcon', () => {
    it('should return cloud for servicenow', () => {
      expect(component.getSourceIcon('servicenow')).toBe('cloud');
    });

    it('should return monitoring for grafana', () => {
      expect(component.getSourceIcon('grafana')).toBe('monitoring');
    });

    it('should return person for manual', () => {
      expect(component.getSourceIcon('manual')).toBe('person');
    });

    it('should return help_outline for unknown source', () => {
      expect(component.getSourceIcon('unknown')).toBe('help_outline');
    });
  });
});
