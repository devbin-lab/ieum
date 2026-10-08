import 'package:ieum_flutter/models.dart';

const planningPart = ProjectRole('role-plan', '기획', {});
const pdPart = ProjectRole('role-pd', 'PD', {});
const routeOwner = Person('gh-1', '개설자', '개', 'owner', 0, login: 'owner');
const routeWorker = Person(
  'gh-2',
  '기획자',
  '기',
  'unassigned',
  0,
  login: 'worker',
  parts: ['기획'],
);
const routeReviewer = Person(
  'gh-3',
  '검토자',
  '검',
  'unassigned',
  0,
  login: 'reviewer',
  parts: ['PD'],
);
const personalReviewSheet = WorkflowSheet(
  nodes: [
    WorkflowSheetNode('todo', 'todo'),
    WorkflowSheetNode('doing', 'doing'),
    WorkflowSheetNode('review', 'review'),
    WorkflowSheetNode('done', 'done'),
  ],
  routes: [
    WorkflowSheetRoute(
      id: 'start',
      from: 'todo',
      to: 'doing',
      destination: 'part:role-plan',
      person: 'gh-2',
    ),
    WorkflowSheetRoute(
      id: 'submit',
      from: 'doing',
      to: 'review',
      source: 'part:role-plan',
      destination: 'part:role-pd',
      person: 'gh-3',
    ),
    WorkflowSheetRoute(
      id: 'approve',
      from: 'review',
      to: 'done',
      action: 'approve',
      source: 'part:role-pd',
    ),
    WorkflowSheetRoute(
      id: 'return',
      from: 'review',
      to: 'doing',
      action: 'reject',
      source: 'part:role-pd',
      destination: 'part:role-plan',
      person: 'gh-2',
    ),
  ],
);
const personalReviewProject = ProjectManifest(
  'project-routing-fixture',
  '파트 흐름',
  'gh-1',
  [routeOwner, routeWorker, routeReviewer],
  roles: [planningPart, pdPart],
  parts: ['기획', 'PD'],
  unifiedParts: true,
  workflowStages: [
    WorkflowStage('todo', '확인중'),
    WorkflowStage('doing', '진행중'),
    WorkflowStage('review', '검토'),
    WorkflowStage('done', '완료'),
  ],
  workflowSheet: personalReviewSheet,
);
