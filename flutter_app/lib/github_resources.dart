part of 'github_sync.dart';

const _resourceBranch = 'ieum/attachments';

extension ResourcePublisher on GitHubPublisher {
  Future<bool> resourceExists(
    GitHubConfig config,
    TaskResource resource,
  ) async {
    try {
      final file = await api.call(
        'GET',
        '/repos/${config.slug}/contents/${resource.repositoryPath}',
        query: {'ref': _resourceBranch},
      );
      if (file is! Map ||
          file['sha'] != resource.blobSha ||
          file['size'] != resource.size) {
        throw const GitHubFailure('첨부 파일의 원본 정보를 확인하지 못했습니다.');
      }
      return true;
    } on GitHubFailure catch (error) {
      if (error.status == 404) return false;
      rethrow;
    }
  }

  Future<void> validateResourceFiles(
    GitHubConfig config,
    WorkTask task,
    WorkTask? base,
  ) async {
    final existing = {
      for (final item in base?.resources ?? <TaskResource>[]) item.id,
    };
    for (final resource in task.resources.where(
      (item) => !item.isLink && !existing.contains(item.id),
    )) {
      if (!await resourceExists(config, resource)) {
        throw const GitHubFailure('첨부 파일 전송이 완료되지 않았습니다. 다시 동기화하세요.');
      }
    }
  }

  Future<void> uploadResource(
    GitHubConfig config,
    TaskResource resource,
    TaskResourceStorage storage,
  ) async {
    if (config.base == _resourceBranch) {
      throw const GitHubFailure('파일 브랜치는 작업 통합 브랜치로 사용할 수 없습니다.');
    }
    if (await resourceExists(config, resource)) {
      await storage.uploaded(resource);
      return;
    }
    final bytes = await storage.local(resource);
    if (bytes == null) {
      throw const GitHubFailure('전송할 첨부 파일이 이 컴퓨터에 없습니다. 원래 컴퓨터에서 다시 동기화하세요.');
    }
    final root = '/repos/${config.slug}';
    final blob = await api.call(
      'POST',
      '$root/git/blobs',
      body: {'content': base64Encode(bytes), 'encoding': 'base64'},
    );
    if (blob['sha'] != resource.blobSha) {
      throw const GitHubFailure('파일 전송 결과가 원본과 다릅니다.');
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      String parent;
      try {
        parent = (await api.call(
          'GET',
          '$root/git/ref/heads/$_resourceBranch',
        ))['object']['sha'];
      } on GitHubFailure catch (error) {
        if (error.status != 404) rethrow;
        parent = await head(config);
        try {
          await api.call(
            'POST',
            '$root/git/refs',
            body: {'ref': 'refs/heads/$_resourceBranch', 'sha': parent},
          );
        } on GitHubFailure catch (error) {
          if (error.status != 422) rethrow;
          continue;
        }
      }
      final commit = await api.call('GET', '$root/git/commits/$parent');
      final tree = await api.call(
        'POST',
        '$root/git/trees',
        body: {
          'base_tree': commit['tree']['sha'],
          'tree': [
            {
              'path': resource.repositoryPath,
              'mode': '100644',
              'type': 'blob',
              'sha': resource.blobSha,
            },
          ],
        },
      );
      final next = await api.call(
        'POST',
        '$root/git/commits',
        body: {
          'message': 'Add IEUM task resource',
          'tree': tree['sha'],
          'parents': [parent],
        },
      );
      try {
        await api.call(
          'PATCH',
          '$root/git/refs/heads/$_resourceBranch',
          body: {'sha': next['sha'], 'force': false},
        );
        await storage.uploaded(resource);
        return;
      } on GitHubFailure catch (error) {
        if (!const [409, 422].contains(error.status) || attempt == 2) rethrow;
        if (await resourceExists(config, resource)) {
          await storage.uploaded(resource);
          return;
        }
      }
    }
    throw const GitHubFailure('다른 파일 전송이 진행 중입니다. 다음 동기화 때 재시도합니다.');
  }

  Future<Uint8List> downloadResource(
    GitHubConfig config,
    TaskResource resource,
    TaskResourceStorage storage,
  ) async {
    final cached = await storage.local(resource);
    if (cached != null) return cached;
    Uint8List bytes;
    if (api is HttpGitHubApi) {
      bytes = await (api as HttpGitHubApi).resourceBlob(config.slug, resource);
    } else {
      final blob = await api.call(
        'GET',
        '/repos/${config.slug}/git/blobs/${resource.blobSha}',
      );
      if (blob['encoding'] != 'base64' || blob['content'] is! String) {
        throw const GitHubFailure('첨부 파일 응답이 올바르지 않습니다.');
      }
      bytes = base64Decode(
        (blob['content'] as String).replaceAll(RegExp(r'\s'), ''),
      );
    }
    await storage.cache(resource, bytes);
    return bytes;
  }
}

extension ResourceSync on GitHubSync {
  Future<void> uploadJobResources(
    GitHubConfig config,
    Map<String, dynamic> job,
  ) async {
    final change = (job['proposal']['changes'] as List).single as Map;
    final resources = <String, TaskResource>{};
    for (final raw in [change['task'], ...?change['steps'] as List?]) {
      final task = WorkTask.fromJson(Map<String, dynamic>.from(raw));
      for (final resource in task.resources.where((item) => !item.isLink)) {
        resources[resource.sha256] = resource;
      }
    }
    if (resources.isEmpty) return;
    final manifest = await publisher.project(config);
    final actor = await publisher.projectActor(config, manifest);
    if (manifest.id != job['proposal']['projectId'] ||
        actor.id != job['proposal']['authorId']) {
      throw const GitHubFailure('첨부 파일의 프로젝트 또는 등록 계정이 다릅니다.');
    }
    final proposed = WorkTask.fromJson(
      Map<String, dynamic>.from(change['task']),
    );
    final base = change['base'] == null
        ? null
        : WorkTask.fromJson(Map<String, dynamic>.from(change['base']));
    validateTaskMutation(
      actor: actor,
      next: proposed,
      current: base,
      workflowProject: manifest,
      allowCollapsedTransitions: true,
      customStages: manifest.workflowStages.map((stage) => stage.id).toList(),
      projectParts: manifest.unifiedView.parts,
      manualWorkflow: manifest.usesManualWorkflow,
      revisions: parseWorkflowRevisions(change['steps']),
    );
    for (final resource in resources.values) {
      if (_disposed || _paused || !this.config.enabled) {
        throw const _SyncInterrupted();
      }
      await publisher.uploadResource(config, resource, resourceStorage);
    }
  }
}
