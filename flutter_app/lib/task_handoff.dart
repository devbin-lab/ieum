import 'models.dart';

/// A reviewable description of one permitted handoff at one task revision.
/// The store revalidates its snapshot inside the write transaction before use.
class TaskHandoffPlan {
  const TaskHandoffPlan({
    required this.taskId,
    required this.title,
    required this.version,
    required this.sourceId,
    required this.sourceName,
    required this.destinationId,
    required this.destinationName,
    required this.action,
    required this.recipientLabel,
    required this.editWarning,
    required this.workflowSnapshot,
    required this.actorId,
    this.routeId = '',
    this.transitionName = '',
    this.commentRequired = false,
    this.requiredFields = const [],
    this.completesTask,
    this.receiverGroup = '',
    this.receiverPerson = '',
    this.requiresRecipient = false,
    this.receiverGroupOptions = const {},
    this.receiverPersonOptions = const {},
    this.receiverPersonGroups = const {},
    this.purpose = '',
    this.canSelectPurpose = false,
    this.lockOnHandoff = false,
  });

  final String taskId,
      title,
      sourceId,
      sourceName,
      destinationId,
      destinationName;
  final int version;
  final String action, recipientLabel, editWarning, workflowSnapshot, actorId;
  final String routeId;
  final String transitionName;
  final bool commentRequired;
  final List<String> requiredFields;
  final bool? completesTask;
  final String receiverGroup, receiverPerson;
  final bool requiresRecipient;
  final Map<String, String> receiverGroupOptions, receiverPersonOptions;
  final Map<String, List<String>> receiverPersonGroups;
  final String purpose;
  final bool canSelectPurpose;
  final bool lockOnHandoff;

  bool get maintainsStatus => sourceId == destinationId;
  String get routeLabel =>
      maintainsStatus ? '$sourceName 유지' : '$sourceName → $destinationName';

  /// A part with no individual selection hands the work to that whole part.
  /// An empty part is valid only when an individual has been selected.
  bool get hasRecipientSelection =>
      !requiresRecipient ||
      (lockOnHandoff
          ? receiverPerson.isNotEmpty
          : receiverGroup.isNotEmpty || receiverPerson.isNotEmpty);

  Map<String, String> get availableReceiverPeople => {
    for (final entry in receiverPersonOptions.entries)
      if (receiverPersonGroups[entry.key]?.contains(receiverGroup) ??
          receiverPersonGroups.isEmpty)
        entry.key: entry.value,
  };

  TaskHandoffPlan withReceiver(String group, String person) {
    final groupLabel = receiverGroupOptions[group] ?? group;
    final personLabel = receiverPersonOptions[person] ?? person;
    final selectedLabel = person.isNotEmpty
        ? group.isEmpty
              ? personLabel
              : '$groupLabel · $personLabel'
        : group.isNotEmpty
        ? '$groupLabel 전체'
        : '전달 대상을 선택하세요';
    return TaskHandoffPlan(
      taskId: taskId,
      title: title,
      version: version,
      sourceId: sourceId,
      sourceName: sourceName,
      destinationId: destinationId,
      destinationName: destinationName,
      action: action,
      recipientLabel: selectedLabel,
      editWarning: editWarning,
      workflowSnapshot: workflowSnapshot,
      actorId: actorId,
      routeId: routeId,
      transitionName: transitionName,
      commentRequired: commentRequired,
      requiredFields: requiredFields,
      completesTask: completesTask,
      receiverGroup: group,
      receiverPerson: person,
      requiresRecipient: requiresRecipient,
      receiverGroupOptions: receiverGroupOptions,
      receiverPersonOptions: receiverPersonOptions,
      receiverPersonGroups: receiverPersonGroups,
      purpose: purpose,
      canSelectPurpose: canSelectPurpose,
      lockOnHandoff: lockOnHandoff,
    );
  }

  TaskHandoffPlan withLock(bool value) => _withOptions(lock: value);

  TaskHandoffPlan withPurpose(String value) => _withOptions(intent: value);

  TaskHandoffPlan _withOptions({String? intent, bool? lock}) => TaskHandoffPlan(
    taskId: taskId,
    title: title,
    version: version,
    sourceId: sourceId,
    sourceName: sourceName,
    destinationId: destinationId,
    destinationName: destinationName,
    action: action,
    recipientLabel: recipientLabel,
    editWarning: editWarning,
    workflowSnapshot: workflowSnapshot,
    actorId: actorId,
    routeId: routeId,
    transitionName: transitionName,
    commentRequired: commentRequired,
    requiredFields: requiredFields,
    completesTask: completesTask,
    receiverGroup: receiverGroup,
    receiverPerson: receiverPerson,
    requiresRecipient: requiresRecipient,
    receiverGroupOptions: receiverGroupOptions,
    receiverPersonOptions: receiverPersonOptions,
    receiverPersonGroups: receiverPersonGroups,
    purpose: intent ?? purpose,
    canSelectPurpose: canSelectPurpose,
    lockOnHandoff: lock ?? lockOnHandoff,
  );

  String get taskTitle => title;
  bool get isRejection => action == 'reject';
  bool get needsComment => commentRequired || isRejection;
  bool get isCompletion => completesTask ?? destinationId == 'done';
  String get buttonLabel => transitionName.isNotEmpty
      ? transitionName
      : switch (action) {
          'reject' => '$destinationName 단계로 반려',
          'approve' => '$destinationName 승인',
          _ => '$destinationName 단계로 전달',
        };

  bool describes(WorkTask task) =>
      task.id == taskId &&
      task.version == version &&
      task.title == title &&
      task.status == sourceId;
}
