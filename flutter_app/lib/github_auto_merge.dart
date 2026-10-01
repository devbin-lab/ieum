part of 'github_sync.dart';

extension AutoTaskIntegration on GitHubPublisher {
  Future<void> integrateTask(
    GitHubConfig config,
    String url, {
    required String projectId,
    required String ownerId,
  }) async {
    final reviewed = await review(config, url);
    final pr = reviewed['request'] as Map;
    if (pr['draft'] == true) throw const GitHubFailure('초안 PR은 자동 통합하지 않습니다.');
    final head = reviewed['sha'] as String;
    final root = '/repos/${config.slug}';
    final snapshot = (await pull(config, ''))!;
    final revision = snapshot['revision'] as String;
    final manifest = await project(config, ref: revision);
    if (manifest.id != projectId || manifest.ownerId != ownerId) {
      throw const GitHubFailure('연결된 프로젝트와 원격 프로젝트가 다릅니다.');
    }
    final executor = await projectActor(config, manifest);
    if (!executor.active || executor.role == 'viewer') {
      throw const GitHubFailure('자동 통합 권한이 없습니다.');
    }
    final authorId = 'gh-${pr['user']?['id']}';
    final authors = manifest.people.where((p) => p.id == authorId);
    if (authors.isEmpty ||
        !authors.single.active ||
        authors.single.role == 'viewer') {
      throw const GitHubFailure('PR 작성자의 참여 승인을 받거나 현재 역할을 확인하세요.');
    }
    final author = authors.single;
    if (!executor.manages && executor.id != author.id) {
      throw const GitHubFailure('내 작업 PR만 자동 통합할 수 있습니다.');
    }
    final diff = await api.call('GET', '$root/compare/$revision...$head');
    final files = diff['files'] as List;
    if (files.length != 1 ||
        !['added', 'modified'].contains(files.single['status'])) {
      throw const GitHubFailure('작업 JSON 한 개의 변경만 자동 통합할 수 있습니다.');
    }
    final path = files.single['filename'] as String;
    final login = pr['user']['login'] as String;
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
    if (file['encoding'] != 'base64' ||
        (file['content'] as String).length > 2 * 1024 * 1024) {
      throw const GitHubFailure('작업 JSON 형식이나 크기를 확인하세요.');
    }
    final proposal = jsonDecode(
      utf8.decode(
        base64Decode((file['content'] as String).replaceAll(RegExp(r'\s'), '')),
      ),
    ) as Map;
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
    final remote = <String, WorkTask>{};
    for (final payload in snapshot['proposals'] as List) {
      if (payload['projectId'] != projectId) continue;
      if (payload['schemaVersion'] != 1 || payload['changes'] is! List) {
        throw const GitHubFailure('통합본 형식을 확인하세요.');
      }
      for (final item in payload['changes'] as List) {
        final value = WorkTask.fromJson(
          Map<String, dynamic>.from(item['task']),
        );
        final previous = remote[value.id];
        if (previous != null &&
            previous.version == value.version &&
            !previous.same(value)) {
          throw const GitHubFailure('통합본에 동일 버전의 서로 다른 작업이 있습니다.');
        }
        if (previous == null || previous.version < value.version) {
          remote[value.id] = value;
        }
      }
    }
    final current = remote[taskId];
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
    if (!author.manages) {
      if (author.role != 'worker' || current == null) {
        throw const GitHubFailure('작업 등록 권한이 없습니다.');
      }
      const assigned = [
        'part',
        'assigneeId',
        'reviewerId',
        'assignedDate',
        'dueDate',
        'priority',
      ];
      if (assigned.any((key) => current.data[key] != task.data[key])) {
        throw const GitHubFailure('배정·일정·우선순위 변경은 PD / PM에게 허용됩니다.');
      }
      final worker = current.assigneeId == author.id;
      final reviewer = current.reviewerId == author.id;
      if (task.status == current.status) {
        if (!worker ||
            task.completedDate != current.completedDate ||
            task.reworkReason != current.reworkReason) {
          throw const GitHubFailure('작업 내용을 수정할 권한이 없습니다.');
        }
      } else {
        final allowed =
            task.status == 'doing' &&
                ['todo', 'rework'].contains(current.status) &&
                worker ||
            task.status == 'review' &&
                ['todo', 'doing', 'rework'].contains(current.status) &&
                worker ||
            ['done', 'rework'].contains(task.status) &&
                current.status == 'review' &&
                reviewer;
        if (!allowed ||
            !worker &&
                [
                  'title',
                  'description',
                ].any((key) => current.data[key] != task.data[key])) {
          throw const GitHubFailure('담당 작업·검토 범위 밖의 상태 변경입니다.');
        }
      }
    }
    if (task.status == 'rework' && task.reworkReason.trim().isEmpty) {
      throw const GitHubFailure('재작업 사유를 입력하세요.');
    }
    for (final id in [task.assigneeId, task.reviewerId]) {
      if (!manifest.people.any(
        (p) => p.id == id && p.active && p.role != 'viewer',
      )) {
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
      final latest = await api.call('GET', '$root/pulls/${pr['number']}');
      final main = await api.call('GET', '$root/git/ref/heads/${config.base}');
      if (latest['state'] != 'open' ||
          latest['head']['sha'] != head ||
          main['object']['sha'] != revision) {
        throw const GitHubFailure(
          '통합 중 PR 또는 main이 변경되었습니다. 다음 동기화 때 다시 검사합니다.',
        );
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
