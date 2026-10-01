const test=require('node:test');
const assert=require('node:assert/strict');
const {mkdtempSync,rmSync}=require('node:fs');
const {tmpdir}=require('node:os');
const {join}=require('node:path');
const {Store}=require('../electron/store.cjs');
const clone=value=>JSON.parse(JSON.stringify(value));
function setup(t){const dir=mkdtempSync(join(tmpdir(),'ieum-test-'));const file=join(dir,'test.sqlite');const store=new Store(file);t.after(()=>{store.close();rmSync(dir,{recursive:true,force:true});});return {store,file};}
function snapshot(store){return {schemaVersion:1,projectId:'ieum-demo',revision:'test-main-2',tasks:clone([...store.baseline().values()])};}
test('task edits persist to SQLite and export only changed fields',t=>{
  const {store,file}=setup(t);const task=store.find('IE-101');store.saveTask({...task,title:'저장 검증'},'planner',task.version);
  const second=new Store(file);try{assert.equal(second.find(task.id).title,'저장 검증');assert.equal(second.changes().changes.length,1);assert.deepEqual(second.changes().changes[0].fields.map(f=>f.key),['title']);}finally{second.close();}
});
test('review, rework, approval hand off to the correct recipient',t=>{
  const {store}=setup(t);const act=(status,actor,reason='')=>store.transition('IE-101',status,actor,reason,store.find('IE-101').version);
  assert.throws(()=>act('done','pm'),/허용되지/);
  act('doing','planner');act('review','planner');assert.equal(store.state().notifications[0].recipientId,'pm');
  assert.throws(()=>act('done','artist'),/허용되지/);assert.throws(()=>act('rework','pm'),/사유/);
  act('rework','pm','완료 조건을 보완하세요');assert.equal(store.state().notifications[0].recipientId,'planner');
  act('doing','planner');act('review','planner');act('done','pm');assert.match(store.find('IE-101').completedDate,/^\d{4}-\d{2}-\d{2}$/);assert.equal(store.find('IE-101').status,'done');
});
test('stale updates, invalid dates and status bypass are rejected or neutralized',t=>{
  const {store}=setup(t);const task=store.find('IE-101');
  assert.throws(()=>store.saveTask({...task,dueDate:'2026-02-30'},'planner',task.version),/올바르게/);
  assert.throws(()=>store.saveTask({...task,dueDate:'2026-09-01'},'planner',task.version),/빠를/);
  assert.throws(()=>store.saveTask({...task,title:'권한 위반'},'artist',task.version),/수정할/);
  store.saveTask({...task,status:'done',completedDate:'2026-10-01',title:'수정'},'planner',task.version);
  assert.equal(store.find(task.id).status,'todo');assert.equal(store.find(task.id).completedDate,'');
  assert.throws(()=>store.saveTask({...task,title:'이전 버전'},'planner',task.version),/변경되었습니다/);
});
test('three-way import preserves local changes and accepts independent remote changes',t=>{
  const {store}=setup(t);const remote=snapshot(store);const task=store.find('IE-101');
  store.saveTask({...task,title:'개인 제목'},'planner',task.version);remote.tasks.find(t=>t.id===task.id).dueDate='2026-10-10';
  const result=store.importSnapshot(remote);assert.equal(result.applied,true);assert.equal(store.find(task.id).title,'개인 제목');assert.equal(store.find(task.id).dueDate,'2026-10-10');
  assert.deepEqual(store.changes().changes[0].fields.map(f=>f.key),['title']);assert.equal(store.getMeta('baseRevision'),'test-main-2');
});
test('conflicting import is atomic and cannot overwrite personal changes',t=>{
  const {store}=setup(t);const remote=snapshot(store);const task=store.find('IE-101');store.saveTask({...task,title:'개인 제목'},'planner',task.version);
  remote.tasks.find(t=>t.id===task.id).title='통합 제목';remote.tasks.find(t=>t.id==='IE-102').title='다른 변경';
  const before=clone(store.state());const result=store.importSnapshot(remote);assert.equal(result.applied,false);assert.equal(result.conflicts[0].field,'작업내용');assert.deepEqual(clone(store.state()),before);
});
test('cross-field conflicts and missing tasks do not partially import',t=>{
  const {store}=setup(t);const remote=snapshot(store);const task=store.find('IE-101');store.saveTask({...task,assignedDate:'2026-10-04'},'planner',task.version);remote.tasks.find(t=>t.id===task.id).dueDate='2026-10-02';
  assert.equal(store.importSnapshot(remote).applied,false);assert.equal(store.getMeta('baseRevision'),'demo-initial');
  remote.tasks.pop();assert.throws(()=>store.importSnapshot(remote),/빠진/);
});
test('new tasks get unique IDs and local notification previews',t=>{
  const {store}=setup(t);const input={...store.find('IE-101'),id:undefined};store.saveTask(input,'pm');store.saveTask(input,'pm');const creates=store.changes().changes.filter(c=>c.kind==='create');
  assert.equal(creates.length,2);assert.notEqual(creates[0].taskId,creates[1].taskId);assert.equal(store.state().notifications[0].state,'preview');
});
