const {app,BrowserWindow,ipcMain,dialog,shell}=require('electron');
const path=require('node:path');
const fs=require('node:fs/promises');
const {Store}=require('./store.cjs');

app.setName('이음');
app.setPath('userData',process.env.IEUM_DATA_DIR||path.join(app.getPath('appData'),'Ieum-Prototype'));
let store;let mainWindow;
const lock=app.requestSingleInstanceLock();
if(!lock)app.quit();
else {
  app.on('second-instance',()=>{if(mainWindow){if(mainWindow.isMinimized())mainWindow.restore();mainWindow.focus();}});
  app.whenReady().then(async()=>{
    await fs.mkdir(app.getPath('userData'),{recursive:true});
    store=new Store(path.join(app.getPath('userData'),'ieum.sqlite'));
    const handle=(channel,fn)=>ipcMain.handle(channel,async(event,...args)=>{
      if(event.sender!==mainWindow?.webContents)return {ok:false,error:'허용되지 않은 창입니다.'};
      try{return {ok:true,value:await fn(...args)};}catch(error){console.error(channel,error.message);return {ok:false,error:error.message};}
    });
    handle('ieum:state',()=>store.state());
    handle('ieum:save',({task,actorId,expectedVersion})=>store.saveTask(task,actorId,expectedVersion));
    handle('ieum:transition',({taskId,status,actorId,reason,expectedVersion})=>store.transition(taskId,status,actorId,reason,expectedVersion));
    handle('ieum:profile',id=>store.setProfile(id));
    handle('ieum:changes',()=>store.changes());
    handle('ieum:repository',()=>shell.openExternal('https://github.com/devbin-lab/ieum'));
    handle('ieum:export',async()=>{
      const result=await dialog.showSaveDialog(mainWindow,{title:'개인 변경안 내보내기',defaultPath:'ieum-changes.json',filters:[{name:'JSON 변경안',extensions:['json']}]});
      if(result.canceled)return {canceled:true};
      const destination=result.filePath;const temporary=destination+'.tmp';await fs.writeFile(temporary,JSON.stringify(store.changes(),null,2)+'\n','utf8');await fs.rename(temporary,destination);
      return {canceled:false,filePath:destination};
    });
    handle('ieum:import',async()=>{
      const result=await dialog.showOpenDialog(mainWindow,{title:'승인된 통합본 JSON 가져오기',properties:['openFile'],filters:[{name:'통합본 JSON',extensions:['json']}]});
      if(result.canceled)return {canceled:true};
      const stat=await fs.stat(result.filePaths[0]);if(stat.size>10*1024*1024)throw Error('통합본 파일은 10MB 이하만 지원합니다.');
      let snapshot;try{snapshot=JSON.parse(await fs.readFile(result.filePaths[0],'utf8'));}catch{throw Error('올바른 JSON 파일을 선택하세요.');}
      return {canceled:false,...store.importSnapshot(snapshot)};
    });
    mainWindow=new BrowserWindow({width:1480,height:980,minWidth:1160,minHeight:740,title:'이음 · 로컬 프로토타입',backgroundColor:'#f8f9fc',autoHideMenuBar:true,webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
    mainWindow.webContents.setWindowOpenHandler(()=>({action:'deny'}));
    mainWindow.webContents.on('will-navigate',event=>event.preventDefault());
    await mainWindow.loadFile(path.join(__dirname,'../dist/index.html'));
    mainWindow.on('closed',()=>{mainWindow=null;});
  }).catch(error=>{console.error(error);dialog.showErrorBox('이음 실행 오류',error.message);app.quit();});
  app.on('window-all-closed',()=>app.quit());
  app.on('before-quit',()=>{store?.close();store=null;});
}
