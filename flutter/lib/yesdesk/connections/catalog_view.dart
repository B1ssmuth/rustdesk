import 'connection_profile.dart';

enum CatalogSort { name, address, type, recent }

enum CatalogFilter { all, favorites, recent }

class ConnectionCatalog {
  ConnectionCatalog(
      Iterable<ConnectionProfile> profiles, Iterable<ConnectionFolder> folders)
      : profiles = Map.unmodifiable({for (final p in profiles) p.id: p}),
        folders = Map.unmodifiable({for (final f in folders) f.id: f}) {
    for (final folder in this.folders.values) {
      ancestors(folder.id);
    }
  }

  final Map<String, ConnectionProfile> profiles;
  final Map<String, ConnectionFolder> folders;

  List<ConnectionFolder> ancestors(String? id) {
    final chain = <ConnectionFolder>[];
    final visited = <String>{};
    while (id != null) {
      final folder = folders[id];
      if (folder == null || !visited.add(id)) {
        throw const FormatException('Invalid folder hierarchy');
      }
      chain.add(folder);
      id = folder.parentId;
    }
    return chain.reversed.toList();
  }

  String folderPath(String? id) => ancestors(id).map((f) => f.name).join(' / ');

  List<ConnectionProfile> find({
    required String query,
    required CatalogFilter filter,
    required CatalogSort sort,
    required String? folderId,
    ConnectionType? type,
    String Function(ConnectionType)? typeLabel,
  }) {
    final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
    final matches = profiles.values.where((profile) {
      if (type != null && profile.type != type) return false;
      if (filter == CatalogFilter.favorites && !profile.favorite) return false;
      if (filter == CatalogFilter.recent && profile.lastConnectedAt == null) {
        return false;
      }
      if (folderId != null &&
          !ancestors(profile.folderId).any((folder) => folder.id == folderId)) {
        return false;
      }
      final target = [
        profile.name,
        profile.address,
        profile.type.name,
        typeLabel?.call(profile.type) ?? '',
        ...profile.tags,
      ].join(' ').toLowerCase();
      return terms.every(target.contains);
    }).toList();

    return matches
      ..sort((a, b) {
        final recent =
            sort == CatalogSort.recent || filter == CatalogFilter.recent;
        if (!recent && a.pinned != b.pinned) return a.pinned ? -1 : 1;
        final value = recent
            ? (b.lastConnectedAt?.millisecondsSinceEpoch ?? -1)
                .compareTo(a.lastConnectedAt?.millisecondsSinceEpoch ?? -1)
            : switch (sort) {
                CatalogSort.address =>
                  a.address.toLowerCase().compareTo(b.address.toLowerCase()),
                CatalogSort.type => a.type.index.compareTo(b.type.index),
                _ => 0,
              };
        if (value != 0) return value;
        final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return name == 0 ? a.id.compareTo(b.id) : name;
      });
  }
}
