const { DatabaseSync } = require('node:sqlite');
const { randomUUID } = require('node:crypto');

const STATUSES = ['todo', 'doing', 'review', 'rework', 'done'];
const PRIORITIES = ['high', 'normal', 'low'];
const FIELDS = ['title', 'part', 'assigneeId', 'reviewerId', 'status', 'priority', 'assignedDate', 'dueDate', 'completedDate', 'description', 'reworkReason'];
const FIELD_LABELS = { title:'작업내용', part:'담당 파트', assigneeId:'담당자', reviewerId:'검토자', status:'작업 상태', priority:'우선순위', assignedDate:'작업 지정일', dueDate:'마감일', completedDate:'완료일', description:'설명', reworkReason:'재작업 사유' };
const MEMBERS = [
  { id:'planner', name:'기획 담당자', initials:'기', role:'worker', part:'기획', color:'#8263eb' },
  { id:'dev', name:'개발 담당자', initials:'개', role:'worker', part:'프로그래밍', color:'#4486c6' },
  { id:'artist', name:'아트 담당자', initials:'아', role:'worker', part:'아트', color:'#c56b86' },
  { id:'pm', name:'PD / PM', initials:'P', role:'manager', part:'관리', color:'#557d6d' }
];
const RULES = [
  { part:'기획', assigneeId:'planner', reviewerId:'pm', nextPart:'프로그래밍' },
  { part:'프로그래밍', assigneeId:'dev', reviewerId:'pm', nextPart:'QA' },
  { part:'아트', assigneeId:'artist', reviewerId:'pm', nextPart:'프로그래밍' },
  { part:'사운드', assigneeId:'planner', reviewerId:'pm', nextPart:'QA' },
  { part:'QA', assigneeId:'dev', reviewerId:'pm', nextPart:'' }
];
function today() { return new Intl.DateTimeFormat('en-CA', {timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date()); }
function validDate(value, label, required=false) {
  if (!value && !required) return '';
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw Error(`${label}을 올바르게 입력하세요.`);
  const date = new Date(value+'T00:00:00Z');
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0,10)!==value) throw Error(`${label}을 올바르게 입력하세요.`);
  return value;
}
function member(id) { const person=MEMBERS.find(m=>m.id===id); if (!person) throw Error('등록된 테스트 사용자를 선택하세요.'); return person; }
function normalize(input) {
  if (!input || typeof input!=='object' || Array.isArray(input)) throw Error('작업 데이터 형식이 올바르지 않습니다.');
  const title=String(input.title??'').trim();
  if (!title || title.length>200) throw Error('작업내용은 1~200자로 입력하세요.');
  if (!RULES.some(r=>r.part===input.part)) throw Error('담당 파트를 선택하세요.');
  if (!STATUSES.includes(input.status)) throw Error('작업 상태가 올바르지 않습니다.');
  if (!PRIORITIES.includes(input.priority)) throw Error('우선순위가 올바르지 않습니다.');
  member(input.assigneeId); member(input.reviewerId);
  const assignedDate=validDate(input.assignedDate,'작업 지정일',true);
  const dueDate=validDate(input.dueDate,'마감일');
  const completedDate=validDate(input.completedDate,'완료일');
  if (dueDate && dueDate<assignedDate) throw Error('마감일은 작업 지정일보다 빠를 수 없습니다.');
  if (input.status==='done' && !completedDate) throw Error('완료 작업에는 완료일이 필요합니다.');
  if (input.status!=='done' && completedDate) throw Error('완료일은 최종 승인 시에만 기록됩니다.');
  const id=String(input.id??''); if (!/^[a-zA-Z0-9_-]{1,80}$/.test(id)) throw Error('작업 ID가 올바르지 않습니다.');
  const description=String(input.description??'').trim(); const reworkReason=String(input.reworkReason??'').trim();
  if (description.length>10000 || reworkReason.length>2000) throw Error('설명 또는 재작업 사유가 너무 깁니다.');
  return {id,title,part:input.part,assigneeId:input.assigneeId,reviewerId:input.reviewerId,status:input.status,priority:input.priority,assignedDate,dueDate,completedDate,description,reworkReason};
}
function same(a,b) { return FIELDS.every(f=>a?.[f]===b?.[f]); }
function demoTasks() {
  const make=(id,title,part,status,priority,due,description,reason='')=>{
    const rule=RULES.find(r=>r.part===part);
    return {id,title,part,status,priority,assigneeId:rule.assigneeId,reviewerId:rule.reviewerId,assignedDate:'2026-10-01',dueDate:due,completedDate:status==='done'?'2026-10-01':'',description,reworkReason:reason,version:1,updatedAt:'2026-10-01T00:00:00.000Z'};
  };
  return [
    make('IE-101','첫 번째 플레이 흐름 정리','기획','todo','high','2026-10-05','플레이 시작부터 첫 목표 달성까지의 흐름과 필요한 화면을 정리합니다.'),
    make('IE-102','캐릭터 실루엣 시안','아트','todo','normal','2026-10-08','캐릭터의 특징을 드러내는 실루엣 3종을 준비합니다.'),
    make('IE-103','튜토리얼 작업 범위 정의','기획','doing','high','2026-10-03','팀이 구현할 튜토리얼 범위를 정하고 완료 조건을 작성합니다.'),
    make('IE-104','기본 이동 프로토타입','프로그래밍','doing','normal','2026-10-06','이동과 시점 조작의 첫 플레이 가능한 버전을 만듭니다.'),
    make('IE-105','레벨 구성안 검토','기획','review','high','2026-10-04','핵심 동선과 구역별 목표가 플레이 의도에 맞는지 검토합니다.'),
    make('IE-106','환경 오브젝트 1차 시안','아트','review','normal','2026-10-07','색상과 크기 기준에 맞춰 환경 오브젝트 시안을 확인합니다.'),
    make('IE-107','상호작용 안내 문구 수정','기획','rework','normal','2026-10-02','플레이어가 조작 방법과 목표를 이해할 수 있도록 안내 문구를 정리합니다.','안내 문구를 두 문장 이내로 줄이고, 버튼 이름을 통일해 주세요.'),
    make('IE-108','프로젝트 목표 합의','기획','done','low','2026-10-01','이번 프로젝트의 범위와 팀 공통 목표를 정리했습니다.')
  ];
}

class Store {
  constructor(filename,{seed=true}={}) {
    this.db=new DatabaseSync(filename);
    this.db.exec(`PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY,title TEXT NOT NULL,part TEXT NOT NULL,assignee_id TEXT NOT NULL,reviewer_id TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('todo','doing','review','rework','done')),priority TEXT NOT NULL CHECK(priority IN ('high','normal','low')),assigned_date TEXT NOT NULL,due_date TEXT NOT NULL,completed_date TEXT NOT NULL,description TEXT NOT NULL,rework_reason TEXT NOT NULL,version INTEGER NOT NULL,updated_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS baseline_tasks(id TEXT PRIMARY KEY,task_json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS activity(id TEXT PRIMARY KEY,task_id TEXT NOT NULL,actor_id TEXT NOT NULL,message TEXT NOT NULL,created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS notification_outbox(id TEXT PRIMARY KEY,event_type TEXT NOT NULL,task_id TEXT NOT NULL,recipient_id TEXT NOT NULL,payload_json TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'preview',created_at TEXT NOT NULL);`);
    if (!this.getMeta('initialized')) this.transaction(()=>{
      this.setMeta('initialized','1');this.setMeta('profile','planner');this.setMeta('baseRevision','demo-initial');this.setMeta('projectId','ieum-demo');
      if (seed) for (const task of demoTasks()) {this.put(task);this.db.prepare('INSERT INTO baseline_tasks VALUES (?,?)').run(task.id,JSON.stringify(task));}
    });
  }
  transaction(work) { this.db.exec('BEGIN IMMEDIATE'); try { const result=work();this.db.exec('COMMIT');return result; } catch(error) {this.db.exec('ROLLBACK');throw error;} }
  getMeta(key) { return this.db.prepare('SELECT value FROM metadata WHERE key=?').get(key)?.value??''; }
  setMeta(key,value) {this.db.prepare('INSERT INTO metadata VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key,value);}
  put(t) {this.db.prepare(`INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,part=excluded.part,assignee_id=excluded.assignee_id,reviewer_id=excluded.reviewer_id,status=excluded.status,priority=excluded.priority,assigned_date=excluded.assigned_date,due_date=excluded.due_date,completed_date=excluded.completed_date,description=excluded.description,rework_reason=excluded.rework_reason,version=excluded.version,updated_at=excluded.updated_at`).run(t.id,...FIELDS.map(f=>t[f]),t.version,t.updatedAt);}
  list() {return this.db.prepare(`SELECT id,title,part,assignee_id AS assigneeId,reviewer_id AS reviewerId,status,priority,assigned_date AS assignedDate,due_date AS dueDate,completed_date AS completedDate,description,rework_reason AS reworkReason,version,updated_at AS updatedAt FROM tasks ORDER BY id`).all().map(t=>({...t}));}
  find(id) {return this.list().find(t=>t.id===id);}
  baseline() {return new Map(this.db.prepare('SELECT id,task_json FROM baseline_tasks').all().map(r=>[r.id,JSON.parse(r.task_json)]));}
  log(task,actor,message,eventType) {
    const at=new Date().toISOString();this.db.prepare('INSERT INTO activity VALUES (?,?,?,?,?)').run(randomUUID(),task.id,actor.id,message,at);
    if(eventType){const recipientId=task.status==='review'?task.reviewerId:task.assigneeId;this.db.prepare('INSERT INTO notification_outbox VALUES (?,?,?,?,?,?,?)').run(randomUUID(),eventType,task.id,recipientId,JSON.stringify({taskId:task.id,title:task.title,status:task.status,recipientId,actorId:actor.id,reason:task.reworkReason}), 'preview',at);}
  }
  saveTask(input,actorId,expectedVersion) {
    const actor=member(actorId);const old=input.id?this.find(input.id):null;
    if(input.id&&!old)throw Error('작업을 찾을 수 없습니다.');
    if(old&&expectedVersion!==old.version)throw Error('작업이 변경되었습니다. 다시 열어 확인하세요.');
    if(old&&actor.id!==old.assigneeId&&actor.role!=='manager')throw Error('작업자 또는 PD / PM만 작업내용을 수정할 수 있습니다.');
    const t=normalize({...input,id:old?.id??'TASK-'+randomUUID(),status:old?.status??'todo',completedDate:old?.completedDate??'',reworkReason:old?.reworkReason??''});
    if(old&&same(old,t))return this.state();
    return this.transaction(()=>{this.put({...t,version:(old?.version??0)+1,updatedAt:new Date().toISOString()});this.log(t,actor,old?'작업내용을 수정했습니다.':'새 작업을 등록했습니다.',old?null:'task.created');return this.state();});
  }
  transition(id,status,actorId,reason='',expectedVersion) {
    const t=this.find(id);if(!t)throw Error('작업을 찾을 수 없습니다.');
    if(expectedVersion!==t.version)throw Error('작업이 변경되었습니다. 다시 열어 확인하세요.');
    const actor=member(actorId);const isWorker=actor.id===t.assigneeId||actor.role==='manager';const isReviewer=actor.id===t.reviewerId||actor.role==='manager';
    const allowed=(status==='doing'&&['todo','rework'].includes(t.status)&&isWorker)||(status==='review'&&t.status==='doing'&&isWorker)||(['done','rework'].includes(status)&&t.status==='review'&&isReviewer);
    if(!allowed)throw Error('현재 상태 또는 사용자에게 허용되지 않은 변경입니다.');
    if(status==='rework'&&!String(reason).trim())throw Error('재작업 사유를 입력하세요.');
    const next=normalize({...t,status,reworkReason:status==='rework'?reason:t.reworkReason,completedDate:status==='done'?today():''});
    const labels={doing:'작업을 시작했습니다.',review:'검토를 요청했습니다.',rework:'재작업을 요청했습니다.',done:'완료를 승인했습니다.'};
    return this.transaction(()=>{this.put({...next,version:t.version+1,updatedAt:new Date().toISOString()});this.log(next,actor,labels[status],`task.${status}`);return this.state();});
  }
  changes() {
    const baseline=this.baseline();const changes=[];
    for(const task of this.list()){
      const base=baseline.get(task.id);const fields=FIELDS.filter(f=>!base||base[f]!==task[f]);if(!fields.length)continue;
      changes.push({taskId:task.id,kind:base?'update':'create',title:task.title,baseVersion:base?.version??null,fields:fields.map(key=>({key,label:FIELD_LABELS[key],before:base?.[key]??null,after:task[key]})),base:base??null,task});
    }
    return {schemaVersion:1,projectId:this.getMeta('projectId'),baseRevision:this.getMeta('baseRevision'),authorId:this.getMeta('profile'),changes};
  }
  importSnapshot(snapshot) {
    if(!snapshot||snapshot.schemaVersion!==1||snapshot.projectId!==this.getMeta('projectId')||typeof snapshot.revision!=='string'||!snapshot.revision||snapshot.revision.length>200||!Array.isArray(snapshot.tasks)||snapshot.tasks.length>10000)throw Error('이 프로젝트의 통합본 JSON 형식이 아닙니다.');
    const incoming=new Map();for(const raw of snapshot.tasks){const t=normalize(raw);if(incoming.has(t.id))throw Error('통합본에 중복 작업 ID가 있습니다.');if(!Number.isSafeInteger(raw.version)||raw.version<1)throw Error('통합본의 작업 버전이 올바르지 않습니다.');incoming.set(t.id,{...t,version:raw.version,updatedAt:typeof raw.updatedAt==='string'?raw.updatedAt:new Date().toISOString()});}
    const bases=this.baseline();const locals=new Map(this.list().map(t=>[t.id,t]));const conflicts=[];const merged=[];
    for(const id of bases.keys())if(!incoming.has(id))throw Error('기존 작업이 빠진 통합본입니다. 이 프로토타입은 삭제 병합을 지원하지 않습니다.');
    for(const [id,remote] of incoming){
      const base=bases.get(id);const local=locals.get(id);
      if(!local){merged.push(remote);continue;}
      if(!base){if(!same(local,remote))conflicts.push({taskId:id,title:local.title,field:'작업 ID',local:'개인 신규 작업',remote:'같은 ID의 통합 작업'});else merged.push({...remote,version:Math.max(local.version,remote.version)+1});continue;}
      const next={...local};for(const field of FIELDS){const localChanged=local[field]!==base[field];const remoteChanged=remote[field]!==base[field];if(localChanged&&remoteChanged&&local[field]!==remote[field])conflicts.push({taskId:id,title:local.title,field:FIELD_LABELS[field],local:local[field],remote:remote[field]});else if(remoteChanged)next[field]=remote[field];}
      try { normalize(next); } catch(error) { conflicts.push({taskId:id,title:local.title,field:'항목 간 관계',local:error.message,remote:'통합 전 확인 필요'}); }
      merged.push({...next,version:Math.max(local.version,remote.version)+1,updatedAt:new Date().toISOString()});
    }
    if(conflicts.length)return {applied:false,conflicts};
    return this.transaction(()=>{for(const t of merged)this.put(t);for(const t of incoming.values())this.db.prepare('INSERT INTO baseline_tasks VALUES (?,?) ON CONFLICT(id) DO UPDATE SET task_json=excluded.task_json').run(t.id,JSON.stringify(t));this.setMeta('baseRevision',snapshot.revision);return {applied:true,conflicts:[],state:this.state()};});
  }
  setProfile(id) {member(id);this.setMeta('profile',id);return this.state();}
  state() {return {tasks:this.list(),members:MEMBERS,rules:RULES,profileId:this.getMeta('profile'),baseRevision:this.getMeta('baseRevision'),projectId:this.getMeta('projectId'),changes:this.changes().changes,activity:this.db.prepare('SELECT id,task_id AS taskId,actor_id AS actorId,message,created_at AS createdAt FROM activity ORDER BY rowid DESC LIMIT 30').all(),notifications:this.db.prepare('SELECT id,event_type AS eventType,task_id AS taskId,recipient_id AS recipientId,payload_json AS payloadJson,state,created_at AS createdAt FROM notification_outbox ORDER BY rowid DESC LIMIT 20').all()};}
  close(){this.db.close();}
}
module.exports={Store,STATUSES,PRIORITIES,FIELDS,MEMBERS,RULES,today};
