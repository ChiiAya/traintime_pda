// Copyright 2026 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// Helpers for getting a dialog's text field focused reliably.

import 'package:flutter/material.dart';

/// Requests the soft keyboard for [focusNode] once the enclosing dialog is fully on screen.
///
/// `TextField(autofocus: true)` inside a dialog races the route's push transition. When it loses
/// that race the field ends up holding focus with no keyboard attached — and because the field
/// already has focus, tapping it does not fire another focus change, so the keyboard can stay away
/// until the dialog is reopened. That is what makes the failure look intermittent.
///
/// Waiting for the transition to report `completed` before requesting focus removes the race, which
/// is why dialogs should pass `autofocus: false` and call this from `initState` instead.
///
/// Safe to call outside a dialog: it then simply requests focus after the first frame.
void focusWhenDialogSettled(BuildContext context, FocusNode focusNode) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;

    // For a dialog this resolves to the dialog's own route, so `animation` is its push transition.
    final Animation<double>? animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      focusNode.requestFocus();
      return;
    }

    void onStatusChanged(AnimationStatus status) {
      if (status != AnimationStatus.completed) return;
      animation.removeStatusListener(onStatusChanged);
      if (context.mounted) focusNode.requestFocus();
    }

    animation.addStatusListener(onStatusChanged);
  });
}
