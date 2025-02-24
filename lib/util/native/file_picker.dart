import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/apk_picker_page.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/theme.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/sleep.dart';
import 'package:localsend_app/util/ui/asset_picker_translated_text_delegate.dart';
import 'package:localsend_app/widget/dialogs/loading_dialog.dart';
import 'package:localsend_app/widget/dialogs/message_input_dialog.dart';
import 'package:localsend_app/widget/dialogs/no_permission_dialog.dart';
import 'package:logging/logging.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:riverpie_flutter/riverpie_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

final _logger = Logger('FilePickerHelper');

enum FilePickerOption {
  file(Icons.description),
  folder(Icons.folder),
  media(Icons.image),
  text(Icons.subject),
  app(Icons.apps),
  clipboard(Icons.paste);

  const FilePickerOption(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case FilePickerOption.file:
        return t.sendTab.picker.file;
      case FilePickerOption.folder:
        return t.sendTab.picker.folder;
      case FilePickerOption.media:
        return t.sendTab.picker.media;
      case FilePickerOption.text:
        return t.sendTab.picker.text;
      case FilePickerOption.app:
        return t.sendTab.picker.app;
      case FilePickerOption.clipboard:
        return t.sendTab.picker.clipboard;
    }
  }

  /// Returns the options for the current platform.
  static List<FilePickerOption> getOptionsForPlatform() {
    if (checkPlatform([TargetPlatform.iOS])) {
      // On iOS, picking from media is most common.
      // The file app is very limited.
      return [
        FilePickerOption.media,
        FilePickerOption.text,
        FilePickerOption.file,
        FilePickerOption.folder,
      ];
    } else if (checkPlatform([TargetPlatform.android])) {
      // On android, the file app is most powerful.
      return [
        FilePickerOption.file,
        FilePickerOption.media,
        FilePickerOption.text,
        FilePickerOption.folder,
        FilePickerOption.app,
      ];
    } else {
      // Desktop
      return [
        FilePickerOption.file,
        FilePickerOption.folder,
        FilePickerOption.text,
        FilePickerOption.clipboard,
      ];
    }
  }

  Future<void> select({
    required BuildContext context,
    required Ref ref,
  }) async {
    switch (this) {
      case FilePickerOption.file:
        if (checkPlatform([TargetPlatform.android])) {
          // On android, the files are copied to the cache which takes some time.
          // ignore: unawaited_futures
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const LoadingDialog(),
          );
        }
        try {
          if (checkPlatform([TargetPlatform.android])) {
            // We also need to use the file_picker package because file_selector does not expose the raw path.
            final result = await FilePicker.platform.pickFiles(allowMultiple: true);
            if (result != null) {
              await ref.notifier(selectedSendingFilesProvider).addFiles(
                    files: result.files,
                    converter: CrossFileConverters.convertPlatformFile,
                  );
            }
          } else {
            final result = await file_selector.openFiles();
            if (result.isNotEmpty) {
              await ref.notifier(selectedSendingFilesProvider).addFiles<file_selector.XFile>(
                    files: result,
                    converter: CrossFileConverters.convertXFile,
                  );
            }
          }
        } catch (e) {
          // ignore: use_build_context_synchronously
          await showDialog(context: context, builder: (_) => const NoPermissionDialog());
          _logger.warning('Failed to pick files', e);
        } finally {
          // ignore: use_build_context_synchronously
          Routerino.context.popUntilRoot(); // remove loading dialog
        }
        break;
      case FilePickerOption.folder:
        if (checkPlatform([TargetPlatform.android])) {
          try {
            await Permission.manageExternalStorage.request();
          } catch (e) {
            _logger.warning('Failed to request manageExternalStorage permission', e);
          }
        }

        // ignore: use_build_context_synchronously
        if (!context.mounted) {
          return;
        }

        // ignore: unawaited_futures
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const LoadingDialog(),
        );
        await sleepAsync(200); // Wait for the dialog to be shown
        try {
          final directoryPath = await pickDirectoryPath();
          if (directoryPath != null) {
            await ref.notifier(selectedSendingFilesProvider).addDirectory(directoryPath);
          }
        } catch (e) {
          _logger.warning('Failed to pick directory', e);
          // ignore: use_build_context_synchronously
          await showDialog(context: context, builder: (_) => const NoPermissionDialog());
        } finally {
          // ignore: use_build_context_synchronously
          Routerino.context.popUntilRoot(); // remove loading dialog
        }
        break;
      case FilePickerOption.media:
        // ignore: use_build_context_synchronously
        final oldBrightness = Theme.of(context).brightness;
        // ignore: use_build_context_synchronously
        final List<AssetEntity>? result = await AssetPicker.pickAssets(
          context,
          pickerConfig: const AssetPickerConfig(maxAssets: 999, textDelegate: TranslatedAssetPickerTextDelegate()),
        );

        WidgetsBinding.instance.addPostFrameCallback((_) async {
          // restore brightness for Android
          await sleepAsync(500);
          if (context.mounted) {
            await updateSystemOverlayStyleWithBrightness(oldBrightness);
          }
        });

        if (result != null) {
          await ref.notifier(selectedSendingFilesProvider).addFiles(
                files: result,
                converter: CrossFileConverters.convertAssetEntity,
              );
        }
        break;
      case FilePickerOption.text:
        // ignore: use_build_context_synchronously
        final result = await showDialog<String>(context: context, builder: (_) => const MessageInputDialog());
        if (result != null) {
          ref.notifier(selectedSendingFilesProvider).addMessage(result);
        }
        break;
      case FilePickerOption.clipboard:
        // ignore: use_build_context_synchronously
        late List<String> files = [];
        await Pasteboard.files().then((value) => {for (final file in value) files.add(file)});
        if (files.isNotEmpty) {
          await ref.notifier(selectedSendingFilesProvider).addFiles<file_selector.XFile>(
                files: files.map((e) => XFile(e)).toList(),
                converter: CrossFileConverters.convertXFile,
              );
        } else {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(t.general.noItemInClipboard),
          ));
        }
        break;
      case FilePickerOption.app:
        // Currently, only Android APK
        // ignore: use_build_context_synchronously
        await context.push(() => const ApkPickerPage());
        break;
    }
  }
}
