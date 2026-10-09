import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'app_localizations.dart';
import 'github_sync.dart';
import 'markdown_content.dart';
import 'models.dart';
import 'popup_ui.dart';
import 'store.dart';
import 'task_resource_storage.dart';
import 'workspace_ui.dart';

class TaskResourcesPanel extends StatefulWidget {
  const TaskResourcesPanel({
    super.key,
    required this.store,
    required this.taskId,
    this.sync,
    this.storage,
    this.selectFile,
  });
  final TaskStore store;
  final String taskId;
  final GitHubSync? sync;
  final TaskResourceStorage? storage;
  final Future<XFile?> Function()? selectFile;
  @override
  State<TaskResourcesPanel> createState() => _TaskResourcesPanelState();
}

class _TaskResourcesPanelState extends State<TaskResourcesPanel> {
  bool busy = false;
  String? previewId;
  String preview = '', error = '';
  TaskResourceStorage get storage =>
      widget.storage ??
      widget.sync?.resourceStorage ??
      TaskResourceStorage.forDatabase(widget.store.filename);
  WorkTask get task => widget.store.find(widget.taskId);

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        error = e is StateError
            ? tr(e.message)
            : e is GitHubFailure
            ? tr(e.message)
            : tr('자료를 처리하지 못했습니다. 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addFile() => run(() async {
    final before = task;
    if (!widget.store.canEditContent(before)) return;
    final picked = await (widget.selectFile?.call() ?? openFile());
    if (picked == null || !mounted) return;
    final resource = await storage.stage(
      picked,
      authorId: widget.store.profileId,
      limitMb:
          widget.store.project?.attachmentLimitMb ?? defaultAttachmentLimitMb,
    );
    try {
      if (!mounted) return;
      widget.store.setTaskResources(before.id, [
        ...before.resources,
        resource,
      ], expectedVersion: before.version);
    } finally {
      try {
        if (!widget.store.referencesResource(resource.sha256)) {
          storage.discardPending(resource);
        }
      } catch (_) {
        // A closed project cannot prove that a pending file is unused.
      }
    }
  });

  Future<void> addLink() async {
    final before = task;
    final name = TextEditingController(), url = TextEditingController();
    String? error;
    final resource = await showDialog<TaskResource>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => IeumDialog(
          title: Text(tr('링크 추가')),
          icon: Icons.link_rounded,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('resource-link-name'),
                controller: name,
                maxLength: 240,
                decoration: InputDecoration(labelText: tr('자료 이름')),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('resource-link-url'),
                controller: url,
                maxLength: 4000,
                decoration: InputDecoration(
                  labelText: tr('링크 주소'),
                  hintText: 'https://',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('취소')),
            ),
            FilledButton(
              key: const Key('resource-link-save'),
              onPressed: () {
                try {
                  final result = TaskResource.fromJson(
                    TaskResource(
                      id: 'resource-${const Uuid().v4()}',
                      name: name.text.trim(),
                      url: url.text.trim(),
                      authorId: widget.store.profileId,
                      createdAt: DateTime.now().toUtc().toIso8601String(),
                    ).json,
                  );
                  Navigator.pop(context, result);
                } on StateError catch (e) {
                  update(() => error = tr(e.message));
                }
              },
              child: Text(tr('추가')),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    name.dispose();
    url.dispose();
    if (resource == null || !mounted) return;
    await run(
      () async => widget.store.setTaskResources(before.id, [
        ...before.resources,
        resource,
      ], expectedVersion: before.version),
    );
  }

  Future<Uint8List> bytes(TaskResource resource) async {
    final local = await storage.local(resource);
    if (local != null) return local;
    final sync = widget.sync;
    if (sync == null || sync.config.slug.isEmpty) {
      throw StateError('첨부 파일을 받으려면 프로젝트 저장소에 연결하세요.');
    }
    return sync.publisher.downloadResource(sync.config, resource, storage);
  }

  Future<void> view(TaskResource resource) => run(() async {
    if (previewId == resource.id) {
      previewId = null;
      preview = '';
      return;
    }
    if (resource.size > 256 * 1024) {
      throw StateError('큰 Markdown 문서는 다운로드해서 확인하세요. 미리보기는 256KB까지 지원합니다.');
    }
    final source = utf8.decode(await bytes(resource));
    if (mounted) {
      previewId = resource.id;
      preview = source;
    }
  });

  Future<void> download(TaskResource resource) => run(() async {
    final location = await getSaveLocation(suggestedName: resource.name);
    if (location == null) return;
    final source = await bytes(resource);
    await XFile.fromData(source, name: resource.name).saveTo(location.path);
  });

  Future<void> remove(TaskResource resource) => run(() async {
    final current = task;
    widget.store.setTaskResources(
      current.id,
      current.resources.where((item) => item.id != resource.id).toList(),
      expectedVersion: current.version,
    );
    if (previewId == resource.id) {
      previewId = null;
      preview = '';
    }
  });

  String details(TaskResource resource) {
    final name = widget.store.member(resource.authorId).name;
    final date = resource.createdAt.substring(0, 10).replaceAll('-', '.');
    final type = resource.isLink
        ? Uri.parse(resource.url).host
        : resource.size < attachmentMegabyte
        ? '${(resource.size / 1024).ceil()} KB'
        : '${(resource.size / attachmentMegabyte).toStringAsFixed(1)} MB';
    return '$type · $name · $date';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final current = task;
      final editable = widget.store.canEditContent(current) && !busy;
      final colors = Theme.of(context).colorScheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(tr('자료'), style: WorkspaceUi.sectionStyleOf(context)),
              Wrap(
                spacing: 4,
                children: [
                  if (editable) ...[
                    TextButton.icon(
                      key: const Key('task-resource-add-file'),
                      onPressed: addFile,
                      icon: const Icon(Icons.attach_file_rounded, size: 16),
                      label: Text(tr('파일 추가')),
                    ),
                    TextButton.icon(
                      key: const Key('task-resource-add-link'),
                      onPressed: addLink,
                      icon: const Icon(Icons.link_rounded, size: 16),
                      label: Text(tr('링크 추가')),
                    ),
                  ],
                ],
              ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (current.resources.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                tr('첨부한 자료가 없습니다.'),
                style: WorkspaceUi.captionStyleOf(context),
              ),
            ),
          for (final resource in current.resources)
            Container(
              key: Key('task-resource-${resource.id}'),
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        resource.isLink
                            ? Icons.link_rounded
                            : resource.isMarkdown
                            ? Icons.article_outlined
                            : Icons.insert_drive_file_outlined,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              resource.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              details(resource),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: WorkspaceUi.captionStyleOf(context),
                            ),
                          ],
                        ),
                      ),
                      if (editable)
                        IconButton(
                          key: Key('resource-remove-${resource.id}'),
                          tooltip: tr('목록에서 제거'),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: () => remove(resource),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (resource.isLink)
                        TextButton.icon(
                          onPressed: busy
                              ? null
                              : () => MarkdownContent.openLink(
                                  context,
                                  resource.url,
                                ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 14),
                          label: Text(tr('링크 열기')),
                        )
                      else ...[
                        if (resource.isMarkdown)
                          TextButton.icon(
                            key: Key('resource-preview-${resource.id}'),
                            onPressed: busy ? null : () => view(resource),
                            icon: const Icon(
                              Icons.description_outlined,
                              size: 14,
                            ),
                            label: Text(
                              previewId == resource.id ? tr('접기') : tr('미리보기'),
                            ),
                          ),
                        TextButton.icon(
                          key: Key('resource-download-${resource.id}'),
                          onPressed: busy ? null : () => download(resource),
                          icon: const Icon(Icons.download_rounded, size: 14),
                          label: Text(tr('다운로드')),
                        ),
                      ],
                    ],
                  ),
                  if (previewId == resource.id) ...[
                    const Divider(height: 24),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 520),
                      child: SingleChildScrollView(
                        child: MarkdownContent(data: preview),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (editable)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                tr(
                  '파일당 최대 {value0}MB · Markdown 미리보기 지원',
                  args: {
                    'value0':
                        widget.store.project?.attachmentLimitMb ??
                        defaultAttachmentLimitMb,
                  },
                ),
                style: WorkspaceUi.captionStyleOf(context),
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SelectableText(
                error,
                style: TextStyle(fontSize: 11, color: colors.error),
              ),
            ),
        ],
      );
    },
  );
}
