// Copyright 2023-2025 BenderBlog Rodriguez and contributors
// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// SchoolNet password dialog.

import 'package:flutter/material.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:watermeter/page/public_widget/toast.dart';
import 'package:watermeter/page/setting/dialogs/dialog_text_focus.dart';
import 'package:watermeter/repository/preference.dart' as preference;

class SchoolNetPasswordDialog extends StatefulWidget {
  const SchoolNetPasswordDialog({super.key});

  @override
  State<SchoolNetPasswordDialog> createState() =>
      _SchoolNetPasswordDialogState();
}

class _SchoolNetPasswordDialogState extends State<SchoolNetPasswordDialog> {
  late final TextEditingController _schoolNetPasswordController;

  /// Focused only once the dialog is fully on screen; see [focusWhenDialogSettled].
  final FocusNode _passwordFocusNode = FocusNode();

  bool _couldView = true;

  @override
  void initState() {
    super.initState();
    focusWhenDialogSettled(context, _passwordFocusNode);
    final pwd = preference.getString(
      preference.Preference.schoolNetQueryPassword,
    );
    _schoolNetPasswordController = TextEditingController.fromValue(
      TextEditingValue(
        text: pwd,
        selection: TextSelection.collapsed(offset: pwd.length),
      ),
    );
  }

  @override
  void dispose() {
    _schoolNetPasswordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        FlutterI18n.translate(
          context,
          "setting.change_schoolnet_password_title",
        ),
      ),
      titleTextStyle: TextStyle(
        fontSize: 20,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      content: TextField(
        // Deliberately not `autofocus`: it races the dialog's push transition and can leave the
        // field focused with no keyboard attached, intermittently. See focusWhenDialogSettled.
        focusNode: _passwordFocusNode,
        controller: _schoolNetPasswordController,
        obscureText: _couldView,
        decoration: InputDecoration(
          hintText: FlutterI18n.translate(
            context,
            "setting.change_password_dialog.input_hint",
          ),
          suffixIcon: IconButton(
            icon: Icon(_couldView ? Icons.visibility : Icons.visibility_off),
            onPressed: () {
              setState(() {
                _couldView = !_couldView;
              });
            },
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: Text(FlutterI18n.translate(context, "cancel")),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        TextButton(
          child: Text(FlutterI18n.translate(context, "confirm")),
          onPressed: () async {
            if (_schoolNetPasswordController.text.isNotEmpty) {
              preference.setString(
                preference.Preference.schoolNetQueryPassword,
                _schoolNetPasswordController.text,
              );
              Navigator.of(context).pop();
            } else {
              showToast(
                context: context,
                msg: FlutterI18n.translate(
                  context,
                  "setting.change_password_dialog.blank_input",
                ),
              );
            }
          },
        ),
      ],
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 7, 16, 16),
    );
  }
}
