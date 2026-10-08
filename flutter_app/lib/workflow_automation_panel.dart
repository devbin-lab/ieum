import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'project_service.dart';
import 'store.dart';

/// Compatibility shell for the removed editor. It cannot read, edit or apply
/// automation rules. The settings workspace now reserves this area for redesign.
class WorkflowAutomationPanel extends StatelessWidget {
  const WorkflowAutomationPanel({
    super.key,
    required this.store,
    this.sync,
    this.session,
  });

  final TaskStore store;
  final GitHubSync? sync;
  final GitHubSession? session;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
