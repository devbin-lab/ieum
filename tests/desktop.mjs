import {_electron as electron} from 'playwright';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rm,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
await mkdir(join(root,'.local'),{recursive:true});
const testDir=await mkdtemp(join(tmpdir(),'ieum-desktop-'));
const dueDate=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(Date.now()+7*86400000));
const env={...process.env,IEUM_DATA_DIR:testDir};delete env.ELECTRON_RUN_AS_NODE;
let app;let page;const errors=[];
async function launch(){app=await electron.launch({executablePath:require('electron'),args:[root],cwd:root,env});page=await app.firstWindow();page.on('pageerror',e=>errors.push(e.message));await page.getByRole('heading',{name:'칸반보드',exact:true}).waitFor();await page.locator('.task-card').first().waitFor();}
async function card(){return page.locator('.task-card').filter({hasText:'데스크톱 검증 작업'});}
async function detail(){await (await card()).click();await page.locator('.drawer').waitFor();}
async function closeDetail(){await page.getByRole('button',{name:'작업 상세 닫기'}).click();await page.locator('.drawer').waitFor({state:'hidden'});}
async function expectStatus(status){await page.locator(`.column.${status} .task-card`).filter({hasText:'데스크톱 검증 작업'}).waitFor();}
try{
  await launch();
  await page.getByLabel('테스트 사용자').selectOption('pm');
  await page.getByRole('button',{name:'작업 등록',exact:true}).click();
  const form=page.getByRole('dialog',{name:'작업 입력'});
  await form.getByLabel('작업내용').fill('데스크톱 검증 작업');
  await form.getByLabel('담당 파트').selectOption('프로그래밍');
  assert.equal(await form.getByLabel('담당자',{exact:true}).inputValue(),'dev');
  assert.equal(await form.getByLabel('검토자',{exact:true}).inputValue(),'pm');
  await form.getByLabel('우선순위').selectOption('high');
  await form.getByLabel('마감일').fill(dueDate);
  await form.getByLabel('설명',{exact:true}).fill('실제 Electron IPC와 SQLite 저장을 검증합니다.');
  await form.getByRole('button',{name:'작업 저장'}).click();await expectStatus('todo');
  await (await card()).dragTo(page.locator('.column.doing'));await expectStatus('doing');
  await detail();await page.getByRole('button',{name:'검토 요청',exact:true}).click();await expectStatus('review');
  assert.match(await page.locator('.detail-grid').innerText(),/현재 처리자\s+PD \/ PM/);
  await page.getByLabel('재작업 사유').fill('검증 항목을 보완하세요');
  await page.getByRole('button',{name:'재작업 요청',exact:true}).click();await expectStatus('rework');
  assert.match(await page.locator('.detail-grid').innerText(),/현재 처리자\s+개발 담당자/);
  await page.getByRole('button',{name:'작업 시작',exact:true}).click();await expectStatus('doing');
  await page.getByRole('button',{name:'검토 요청',exact:true}).click();await expectStatus('review');
  await page.getByRole('button',{name:'완료 승인',exact:true}).click();await expectStatus('done');await closeDetail();
  await page.getByRole('button',{name:'일정 · 작업',exact:true}).click();
  const row=page.getByRole('row').filter({hasText:'데스크톱 검증 작업'});await row.waitFor();
  assert.match(await row.innerText(),/완료/);assert.ok((await row.innerText()).includes(dueDate));assert.equal(await row.locator('td').count(),8);
  await page.getByRole('button',{name:'내 변경내역'}).click();await page.locator('.change-card').waitFor();
  const exported=join(testDir,'changes.json');await app.evaluate(({dialog},destination)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:destination});},exported);
  await page.getByRole('button',{name:'변경안 내보내기'}).click();await page.getByRole('status').filter({hasText:'내보냈습니다'}).waitFor();
  const changes=JSON.parse(await readFile(exported,'utf8'));assert.equal(changes.changes.length,1);assert.equal(changes.changes[0].task.status,'done');
  const snapshot=JSON.parse(await readFile(join(root,'examples/demo-snapshot.json'),'utf8'));snapshot.revision='desktop-smoke';snapshot.tasks[0].title='통합본 변경 제목';
  const imported=join(testDir,'snapshot.json');await writeFile(imported,JSON.stringify(snapshot));
  await app.evaluate(({dialog},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});},imported);
  await page.getByRole('button',{name:'통합본 가져오기'}).click();await page.getByRole('status').filter({hasText:'통합본을 반영했습니다'}).waitFor();
  await page.getByRole('button',{name:'연결 설정',exact:true}).click();await page.getByRole('heading',{name:'Discord',exact:true}).waitFor();
  await page.getByRole('button',{name:'알림 대기 목록 보기'}).click();assert.equal(await page.locator('.notification').count(),7);
  await page.getByRole('button',{name:'알림 닫기'}).click();
  await app.close();await launch();await expectStatus('done');assert.equal(await page.getByLabel('테스트 사용자').inputValue(),'pm');
  await page.locator('.task-card').filter({hasText:'통합본 변경 제목'}).waitFor();assert.deepEqual(errors,[]);
  console.log('PASS: Electron 작업 등록, 자동 배정, 드래그, 검토·재작업·승인, 일정표, JSON 내보내기/통합, 이벤트 7건, 재실행 저장 유지');
}catch(error){if(page&&!page.isClosed())await page.screenshot({path:join(root,'.local','desktop-failure.png')});throw error;}
finally{await app?.close().catch(()=>{});const target=resolve(testDir);if(dirname(target)!==resolve(tmpdir())||!target.split(/[\\/]/).at(-1).startsWith('ieum-desktop-'))throw Error('Unexpected test data path');await rm(target,{recursive:true,force:true});}
