// PhotoPI: "Remove from server" — deletes the server copy of photos that are also on this phone, keeps the
// phone copy, and makes sure the photo is never uploaded again.
//
// Server side (PhotoPI `POST /api/photopi/forget`): the file is deleted, the asset stays as a hidden row so
// its checksum is still known; the backup therefore treats the local file as already backed up. The
// timeline query (merged_asset.drift) shows the local copy again since its only remote twin is hidden.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

typedef _State = ({List<String> remoteIds});

final _stateProvider = Provider.family.autoDispose<_State?, ActionSource>((ref, source) {
  if (ref.watch(inLockedViewProvider)) {
    return null;
  }
  final userId = ref.watch(authUserProvider).id;
  final remoteIds = <String>[];
  for (final asset in ref.watch(assetsActionProvider(source))) {
    // Only photos that also exist on this phone: for a server-only photo this would be a delete without trash.
    if (asset case final RemoteAsset remote
        when remote.ownerId == userId && remote.localId != null && !remote.isTrashed && !remote.isLocked) {
      remoteIds.add(remote.id);
    }
  }
  return remoteIds.isEmpty ? null : (remoteIds: remoteIds);
}, dependencies: [assetsActionProvider]);

class RemoveFromServerAction extends AssetActionBuilder {
  const RemoveFromServerAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final state = ref.watch(_stateProvider(source));
    if (state == null) {
      return null;
    }
    return .new(
      icon: Icons.cloud_off_outlined,
      label: context.t.photopi_remove_from_server,
      onAction: () => _remove(context, ref),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final state = ref.read(_stateProvider(source));
    if (state == null) {
      return;
    }
    final remoteIds = state.remoteIds;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: context.t.photopi_remove_from_server,
        content: context.t.photopi_remove_from_server_confirm(count: remoteIds.length),
        ok: context.t.photopi_remove_from_server_ok,
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }

    final toastService = ref.read(toastServiceProvider);
    final clearSelection = ref.read(clearSelectionProvider(source));
    final syncManager = ref.read(backgroundSyncProvider);
    final basePath = ref.read(apiServiceProvider).apiClient.basePath;
    final doneMessage = context.t.photopi_remove_from_server_done(count: remoteIds.length);
    final unsupportedMessage = context.t.photopi_remove_from_server_unsupported;

    try {
      // Same authenticated native client as the sync stream (the token travels as a cookie).
      final response = await NetworkRepository.client.post(
        Uri.parse('$basePath/photopi/forget'),
        headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode({'ids': remoteIds}),
      );
      if (response.statusCode == 404 || response.statusCode == 501) {
        toastService.error(unsupportedMessage);
        return;
      }
      if (response.statusCode != 200) {
        throw Exception('photopi/forget answered ${response.statusCode}: ${response.body}');
      }
      clearSelection();
      toastService.success(doneMessage);
      // Fetch the change now (no websocket on PhotoPI), so the timeline shows the phone copy right away.
      await syncManager.syncRemote();
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to remove assets from the server");
    }
  }
}
