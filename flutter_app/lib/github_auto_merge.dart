part of 'github_sync.dart';

extension AutoTaskIntegration on GitHubPublisher {
  Future<void> integrateTask(
    GitHubConfig config,
    String url, {
    required String projectId,
    required String founderId,
    String? expectedHead,
  }) async {
    final reviewed = await review(config, url);
    final pr = reviewed['request'] as Map;
    if (pr['draft'] == true) throw const GitHubFailure('초안 PR은 자동 통합하지 않습니다.');
    final head = reviewed['sha'] as String;
    if (expectedHead != null && head != expectedHead) {
      throw const GitHubFailure('검토 이후 PR이 변경되었습니다. 다시 확인하세요.');
    }
    final root = '/repos/${config.slug}';
    final snapshot = (await pull(config, ''))!;
    final revision = snapshot['revision'] as String;
    final manifest = await project(config, ref: revision);
    if (manifest.id != projectId || manifest.founderId != founderId) {
      throw const GitHubFailure('연결된 프로젝트와 원격 프로젝트가 다릅니다.');
    }
    final executor = await projectActor(config, manifest);
    if (!executor.canMutate) {
      throw const GitHubFailure('자동 통합 권한이 없습니다.');
    }
    final authorId = 'gh-${pr['user']?['id']}';
    final authors = manifest.people.where((p) => p.id == authorId);
    if (authors.isEmpty || !authors.single.canMutate) {
      throw const GitHubFailure('PR 작성자의 참여 승인을 받거나 현재 역할을 확인하세요.');
    }
    final author = authors.single;
    if (manifest.workflowSheet == null &&
        executor.id != manifest.ownerId &&
        executor.id != author.id) {
      throw const GitHubFailure('내 작업 PR만 자동 통합할 수 있습니다.');
    }
    final diff = await api.call('GET', '$root/compare/$revision...$head');
    final files = diff['files'] as List;
    if (files.length != 1 ||
        !['added', 'modified'].contains(files.single['status'])) {
      throw const GitHubFailure('작업 JSON 한 개의 변경만 자동 통합할 수 있습니다.');
    }
    final path = files.single['filename'] as String;
    final label = RegExp(r'^\.ieum/changes/([A-Za-z0-9_-]+)/').firstMatch(path);
    final login = label?.group(1);
    // GitHub login names can change while the PR author ID stays the same.
    if (login == null || !{pr['user']['login'], author.login}.contains(login)) {
      throw const GitHubFailure('작성자의 작업 JSON 경로가 아닙니다.');
    }
    final prefix = '.ieum/changes/$login/';
    if (!path.startsWith(prefix) || !path.endsWith('.json')) {
      throw const GitHubFailure('작성자의 작업 JSON 경로가 아닙니다.');
    }
    final taskId = path.substring(prefix.length, path.length - 5);
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(taskId) ||
        pr['head']['ref'] != 'ieum/tasks/$login/$taskId') {
      throw const GitHubFailure('이음 작업별 브랜치의 PR이 아닙니다.');
    }
    final file = await api.call(
      'GET',
      '$root/contents/$path',
      query: {'ref': head},
    );
    final proposal = _decodeTaskProposal(file, path: path);
    if (proposal['schemaVersion'] != 1 ||
        proposal['projectId'] != projectId ||
        proposal['authorId'] != author.id ||
        proposal['githubLogin'] != login ||
        proposal['changes'] is! List ||
        (proposal['changes'] as List).length != 1) {
      throw const GitHubFailure('작업 변경안의 프로젝트·작성자·형식을 확인하세요.');
    }
    final change = proposal['changes'].single as Map;
    final task = WorkTask.fromJson(Map<String, dynamic>.from(change['task']));
    if (change['taskId'] != taskId || task.id != taskId) {
      throw const GitHubFailure('작업 ID가 변경안과 일치하지 않습니다.');
    }
    final remote = _RemoteTasks(snapshot, projectId);
    if (remote.uncertain || remote.blocked.contains(taskId)) {
      throw const GitHubFailure(
        '이 작업의 통합 데이터가 손상되었거나 서로 다릅니다. 해당 파일을 복구한 뒤 다시 통합하세요.',
      );
    }
    final current = remote.tasks[taskId];
    final base = change['base'] == null
        ? null
        : WorkTask.fromJson(Map<String, dynamic>.from(change['base']));
    if (current == null
        ? base != null
        : base == null ||
              base.id != current.id ||
              base.version != current.version ||
              !base.same(current)) {
      throw const GitHubFailure('같은 작업의 통합본이 변경되었습니다. 최신 내용을 가져와 변경을 확인하세요.');
    }
    if (current != null && task.version <= current.version) {
      throw const GitHubFailure('작업 버전이 통합본보다 새롭지 않습니다.');
    }
    try {
      validateTaskMutation(
        actor: author,
        next: task,
        current: current,
        allowCollapsedTransitions: true,
        customStages: manifest.workflowStages.map((stage) => stage.id).toList(),
        workflowConnections: manifest.activeWorkflowConnections,
        manualWorkflow: manifest.usesManualWorkflow,
        projectParts: manifest.unifiedView.parts,
        workflowProject: manifest,
        revisions: parseWorkflowRevisions(change['steps']),
      );
    } on StateError catch (e) {
      throw GitHubFailure(e.message.toString());
    }
    for (final id in _changedTaskRecipientIds(task, current, manifest)) {
      if (!manifest.people.any((p) => p.id == id && p.active)) {
        throw const GitHubFailure('작업 담당자의 현재 참여 권한을 확인하세요.');
      }
    }
    final branch = await api.call(
      'GET',
      '$root/branches/${Uri.encodeComponent(config.base)}',
    );
    if (branch['protected'] != false) {
      throw const GitHubFailure(
        '보호 브랜치는 GitHub의 승인 조건을 먼저 충족해야 합니다. 직접 검토하세요.',
      );
    }

    // Stage a real Git merge against the validated base. Publishing with a
    // non-forced ref update makes a concurrent, divergent main update fail.
    // Thus two clients cannot both publish proposals validated against stale main.
    final temporary = 'ieum/integrations/${const Uuid().v4()}';
    var created = false;
    try {
      await api.call(
        'POST',
        '$root/git/refs',
        body: {'ref': 'refs/heads/$temporary', 'sha': revision},
      );
      created = true;
      final merged = await api.call(
        'POST',
        '$root/merges',
        body: {
          'base': temporary,
          'head': head,
          'commit_message': 'Auto-integrate IEUM task PR #${pr['number']}',
        },
      );
      if (merged?['sha'] is! String) {
        throw const GitHubFailure('통합 커밋을 확인하지 못했습니다. 다음 동기화 때 재시도합니다.');
      }
      final stagedFile = await api.call(
        'GET',
        '$root/contents/$path',
        query: {'ref': merged['sha'] as String},
      );
      _decodeTaskProposal(stagedFile, path: path);
      if (file['sha'] is! String || stagedFile['sha'] != file['sha']) {
        throw const GitHubFailure(
          'Git 통합 과정에서 검증한 작업 내용이 변경되었습니다. 최신 내용을 가져와 다시 제출하세요.',
        );
      }
      final latest = await api.call('GET', '$root/pulls/${pr['number']}');
      final main = await api.call('GET', '$root/git/ref/heads/${config.base}');
      if (latest['state'] != 'open' ||
          latest['head']['sha'] != head ||
          main['object']['sha'] != revision) {
        throw const GitHubFailure(
          '통합 중 PR 또는 main이 변경되었습니다. 다음 동기화 때 다시 검사합니다.',
        );
      }
      final committingExecutor = await projectActor(config, manifest);
      if (committingExecutor.id != executor.id ||
          !committingExecutor.canMutate ||
          manifest.workflowSheet == null &&
              committingExecutor.id != manifest.ownerId &&
              committingExecutor.id != author.id) {
        throw const GitHubFailure('통합 중 로그인 계정이 변경되었습니다. 다시 확인하세요.');
      }
      await api.call(
        'PATCH',
        '$root/git/refs/heads/${config.base}',
        body: {'sha': merged['sha'], 'force': false},
      );
    } finally {
      if (created) {
        try {
          await api.call('DELETE', '$root/git/refs/heads/$temporary');
        } catch (_) {
          // A failed cleanup must not report an already-published merge as failed.
        }
      }
    }
  }
}
