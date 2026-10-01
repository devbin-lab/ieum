const { contextBridge, ipcRenderer } = require('electron');

async function invoke(channel, ...args) {
  const result = await ipcRenderer.invoke(channel, ...args);
  if (!result.ok) throw new Error(result.error);
  return result.value;
}

contextBridge.exposeInMainWorld('ieum', Object.freeze({
  getState: () => invoke('ieum:state'),
  saveTask: (task, actorId, expectedVersion) => invoke('ieum:save', { task, actorId, expectedVersion }),
  transition: (taskId, status, actorId, reason, expectedVersion) => invoke('ieum:transition', { taskId, status, actorId, reason, expectedVersion }),
  getChanges: () => invoke('ieum:changes'),
  exportChanges: () => invoke('ieum:export'),
  importSnapshot: () => invoke('ieum:import'),
  setProfile: (actorId) => invoke('ieum:profile', actorId),
  openRepository: () => invoke('ieum:repository')
}));
