enum RemoteSessionRecovery {
  ready,
  awaitingPeer,
  awaitingFrame;

  RemoteSessionRecovery onPeerInfo() =>
      this == awaitingPeer ? awaitingFrame : this;

  RemoteSessionRecovery onFrame() => this == awaitingFrame ? ready : this;
}

class RemoteSessionPermissions {
  const RemoteSessionPermissions({
    required this.active,
    required this.viewOnly,
    required this.keyboard,
    required this.clipboard,
    required this.files,
  });

  final bool active;
  final bool viewOnly;
  final bool keyboard;
  final bool clipboard;
  final bool files;

  bool get canSendKeys => active && keyboard && !viewOnly;
  bool get canUseClipboard => canSendKeys && clipboard;
  bool get canTransferFiles => active && files && !viewOnly;
}
