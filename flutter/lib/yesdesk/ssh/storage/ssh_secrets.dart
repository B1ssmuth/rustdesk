import '../../storage/windows_credentials.dart';

typedef SshSecretStore = CredentialStore;

class SystemSshSecretStore extends WindowsCredentialStore {
  const SystemSshSecretStore() : super('SSH');
}
