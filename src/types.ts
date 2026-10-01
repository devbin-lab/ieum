export type Status = 'todo'|'doing'|'review'|'rework'|'done';
export interface Task {id:string;title:string;part:string;assigneeId:string;reviewerId:string;status:Status;priority:'high'|'normal'|'low';assignedDate:string;dueDate:string;completedDate:string;description:string;reworkReason:string;version:number;updatedAt:string}
export interface Member {id:string;name:string;initials:string;role:string;part:string;color:string}
export interface Rule {part:string;assigneeId:string;reviewerId:string;nextPart:string}
export interface Change {taskId:string;kind:string;title:string;fields:{key:string;label:string;before:string|null;after:string}[]}
export interface Conflict {taskId:string;title:string;field:string;local:string;remote:string}
export interface State {tasks:Task[];members:Member[];rules:Rule[];profileId:string;baseRevision:string;projectId:string;changes:Change[];activity:{id:string;taskId:string;actorId:string;message:string;createdAt:string}[];notifications:{id:string;eventType:string;taskId:string;recipientId:string;payloadJson:string;state:string;createdAt:string}[]}
declare global {interface Window {ieum:{getState():Promise<State>;saveTask(task:Partial<Task>,actorId:string,version?:number):Promise<State>;transition(id:string,status:Status,actorId:string,reason:string,version:number):Promise<State>;setProfile(id:string):Promise<State>;exportChanges():Promise<{canceled:boolean;filePath?:string}>;importSnapshot():Promise<{canceled?:boolean;applied?:boolean;conflicts?:Conflict[];state?:State}>;openRepository():Promise<void>}}}
