import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../common.dart' show isWindows;
import '../../desktop/pages/remote_page.dart';
import '../../desktop/widgets/remote_toolbar.dart';
import '../../models/model.dart' show ConnType;
import '../../models/platform_model.dart';
import '../ssh/widgets/ssh_strings.dart';
import 'corporate_session.dart';

typedef WorkspaceApi = Future<dynamic> Function(String path,
    {Map<String, String>? query, String method, Map<String, dynamic>? body});

class ManagedWorkspace extends StatefulWidget {
  const ManagedWorkspace(
      {super.key,
      required this.language,
      required this.query,
      required this.tiles,
      required this.favorites,
      this.api});

  final String language;
  final String query;
  final bool tiles;
  final bool favorites;
  final WorkspaceApi? api;

  @override
  State<ManagedWorkspace> createState() => _ManagedWorkspaceState();
}

class _ManagedWorkspaceState extends State<ManagedWorkspace> {
  Timer? _search;
  int _offset = 0;
  String? _hotel;
  String _statusFilter = 'all';
  String _sort = 'hostname';
  final _columns = {'user', 'status', 'id'};
  Map<String, dynamic>? _selected;
  Future<dynamic>? _history;
  Future<dynamic>? _connectionOptions;
  late Future<dynamic> _data;
  String? _notice;
  bool _treeVisible = true;
  bool _launching = false;
  WorkspaceApi get request => widget.api ?? corporateSession.api;
  String t(String en, String ru) => SshStrings(widget.language).text(en, ru);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ManagedWorkspace old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.favorites != widget.favorites) {
      _search?.cancel();
      _search = Timer(const Duration(milliseconds: 250), () {
        if (mounted)
          setState(() {
            _offset = 0;
            _load();
          });
      });
    }
  }

  @override
  void dispose() {
    _search?.cancel();
    super.dispose();
  }

  void _load() {
    _data = request('/v2/workspace', query: {
      'q': widget.query.trim(),
      if (_hotel case final String hotel) 'hotel': hotel,
      'status': _statusFilter,
      'favorites': '${widget.favorites}',
      'sort': _sort,
      'offset': '$_offset',
    });
  }

  String _value(Object? value) => value?.toString() ?? '—';

  String _status(Map<String, dynamic> row) {
    if (row['agent_registered'] != true) return t('No agent', 'Без агента');
    return row['online'] == true
        ? t('Online', 'В сети')
        : t('Offline', 'Не в сети');
  }

  void _select(Map<String, dynamic> row) => setState(() {
        _selected = row;
        final id = row['device_id'];
        _history = id == null ? null : request('/v2/devices/$id/history');
        _connectionOptions = id == null || row['agent_registered'] != true
            ? null
            : request('/v2/devices/$id/connection-options');
        _notice = null;
      });

  Future<void> _preferences(Map<String, dynamic> row,
      {bool? favorite, String? group}) async {
    final id = row['device_id'];
    if (id == null || row['agent_registered'] != true) return;
    try {
      await request('/v2/devices/$id/preferences', method: 'PUT', body: {
        'favorite': favorite ?? row['favorite'],
        'group_name': group ?? row['group_name'],
      });
      if (mounted)
        setState(() {
          row['favorite'] = favorite ?? row['favorite'];
          row['group_name'] = group ?? row['group_name'];
          _load();
        });
    } catch (_) {
      if (mounted)
        setState(() => _notice = t('Could not update device preferences.',
            'Не удалось сохранить настройки устройства.'));
    }
  }

  Future<void> _assignHotel(Map<String, dynamic> row) async {
    final source = row['device_id'] == null ||
            row['manual_hotel_source'] == 'ad'
        ? 'ad'
        : 'device';
    final id = source == 'ad' ? row['ad_id'] : row['device_id'];
    if (id == null || !corporateSession.isAdmin) return;
    var value = (row['manual_hotel'] ?? row['hotel'] ?? '') as String;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(t('Assign hotel', 'Привязка к отелю')),
        content: TextFormField(
          initialValue: value,
          autofocus: true,
          maxLength: 128,
          decoration: InputDecoration(labelText: t('Hotel', 'Отель')),
          onChanged: (input) => value = input,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(t('Cancel', 'Отмена')),
          ),
          if (row['manual_hotel'] != null)
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(t('Clear assignment', 'Снять привязку')),
            ),
          FilledButton(
            onPressed: () {
              if (value.trim().isNotEmpty) Navigator.pop(dialog, true);
            },
            child: Text(t('Save', 'Сохранить')),
          ),
        ],
      ),
    );
    if (save == null || !mounted || !corporateSession.isAdmin) return;
    try {
      await request('/v2/catalog/$source/$id/hotel', method: 'PUT', body: {
        'hotel': save ? value.trim() : null,
      });
      if (mounted) {
        setState(() {
          _selected = null;
          _load();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _notice =
            t('Hotel assignment failed.', 'Не удалось изменить привязку.'));
      }
    }
  }

  bool _matchesSelection(Map<String, dynamic> row) =>
      _selected != null &&
      _selected?['device_id'] == row['device_id'] &&
      _selected?['ad_id'] == row['ad_id'];

  Widget _record(Map<String, dynamic> row) {
    return ListTile(
      selected: _matchesSelection(row),
      title: Text(_value(row['hostname']),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          [
            if (_columns.contains('user')) _value(row['windows_user']),
            if (_columns.contains('status')) _status(row),
            if (_columns.contains('id')) _value(row['yesdesk_id']),
          ].join(' · '),
          maxLines: widget.tiles ? 2 : 1,
          overflow: TextOverflow.ellipsis),
      trailing: row['agent_registered'] == true
          ? IconButton(
              tooltip: t('Favorite', 'Избранное'),
              icon: Icon(
                  row['favorite'] == true ? Icons.star : Icons.star_outline),
              onPressed: () =>
                  _preferences(row, favorite: row['favorite'] != true))
          : null,
      onTap: () => _select(row),
    );
  }

  Widget _details(Map<String, dynamic> row) {
    final hardware = row['metadata'] as Map<String, dynamic>;
    final users = row['windows_users'] as List?;
    final displayUsers =
        users?.isNotEmpty == true ? users!.join(', ') : _value(row['windows_user']);
    return DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(_value(row['hostname'])),
              trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: t('Close', 'Закрыть'),
                  onPressed: () => setState(() => _selected = null)),
            ),
            TabBar(tabs: [
              Tab(text: t('Overview', 'Обзор')),
              Tab(text: t('Sessions', 'Сеансы')),
            ]),
            Expanded(
                child: TabBarView(children: [
              ListView(padding: const EdgeInsets.all(12), children: [
                Text(_value(row['dns_name'])),
                if ((row['ou_path'] as List).isNotEmpty)
                  Text((row['ou_path'] as List).join(' / ')),
                Text(_hotelName(row['hotel'] as String? ?? '')),
                if (corporateSession.isAdmin)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => _assignHotel(row),
                      child: Text(t('Assign hotel', 'Привязать к отелю')),
                    ),
                  ),
                Text(_status(row)),
                Text(
                    '${t('Windows user', 'Пользователь Windows')} · $displayUsers'),
                Text('YES Desk ID · ${_value(row['yesdesk_id'])}'),
                Text(
                    '${t('Agent', 'Агент')} · ${_value(hardware['agent_version'])}'),
                Text(
                    '${t('Heartbeat', 'Последняя связь')} · ${_value(row['last_heartbeat'])}'),
                for (final field in ['domain', 'os', 'model', 'cpu'])
                  if (hardware[field] != null) Text(_value(hardware[field])),
                if (hardware['ram_bytes'] case final int ram)
                  Text('RAM ${(ram / (1 << 30)).toStringAsFixed(1)} GiB'),
                if (hardware['addresses'] case final List addresses)
                  Text(addresses.join(', ')),
                if (hardware['disks'] case final List disks)
                  for (final disk in disks)
                    Text(
                        '${disk['name']} · ${(disk['bytes'] / (1 << 30)).toStringAsFixed(1)} GiB'),
                if (row['agent_registered'] == true)
                  TextFormField(
                      key: ValueKey(row['device_id']),
                      initialValue: row['group_name'] as String,
                      maxLength: 80,
                      onFieldSubmitted: (value) =>
                          _preferences(row, group: value),
                      decoration: InputDecoration(
                          labelText: t('Group (Enter to save)',
                              'Группа (Enter для сохранения)'))),
                const Divider(),
                _connectionActions(),
              ]),
              FutureBuilder<dynamic>(
                  future: _history,
                  builder: (context, snapshot) {
                    if (_history == null)
                      return Center(
                          child: Text(
                              t('No agent sessions.', 'Сеансов агента нет.')));
                    if (snapshot.hasError)
                      return Center(
                          child: Text(t('Session history unavailable.',
                              'История сеансов недоступна.')));
                    if (!snapshot.hasData)
                      return const Center(child: CircularProgressIndicator());
                    return ListView(children: [
                      for (final entry in snapshot.data as List)
                        ListTile(
                            title: Text(_value(entry['username'])),
                            subtitle: Text(
                                '${entry['transport']} · ${entry['kind']} · ${entry['observed_at']}')),
                    ]);
                  }),
            ])),
          ],
        ));
  }

  Future<void> _launch() async {
    final device = _selected?['device_id'];
    if (!isWindows || _launching || device is! String) return;
    setState(() => _launching = true);
    try {
      final options = await request('/v2/devices/$device/connection-options');
      if (!mounted || _selected?['device_id'] != device) return;
      final launch = options['launch'];
      if (options['attended']?['available'] != true ||
          launch is! Map ||
          launch['device_id'] != device) {
        throw StateError('Corporate launch unavailable');
      }
      final peer = launch['yesdesk_id'] as String;
      if (bind.peerGetSessionsCount(
              id: peer, connType: ConnType.defaultConn.index) >
          0) {
        throw StateError('Close the existing session first');
      }
      final credentials = corporateSession.connectionCredentials;
      final session = const Uuid().v4obj();
      final error = bind.sessionAddCorporateSync(
          sessionId: session,
          id: peer,
          deviceId: device,
          endpointKeyHex: launch['endpoint_key'] as String,
          managementUrl: credentials.managementUrl,
          operator: credentials.operator,
          mode: 'consent',
          accessToken: credentials.token);
      if (error.isNotEmpty) throw StateError('Corporate session unavailable');
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => RemotePage(
              id: peer,
              toolbarState: ToolbarState(),
              sessionId: session,
              corporateSessionPrepared: true)));
    } catch (_) {
      if (mounted)
        setState(() => _notice = t('Could not start corporate connection.',
            'Не удалось начать корпоративное подключение.'));
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  Widget _connectionActions() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_connectionOptions != null)
            FutureBuilder<dynamic>(
              future: _connectionOptions,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(t('Access policy unavailable.',
                      'Политика доступа недоступна.'));
                }
                final options = snapshot.data;
                final consent = isWindows &&
                    options is Map &&
                    options['attended']?['available'] == true;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FilledButton(
                          onPressed: consent && !_launching ? _launch : null,
                          child: Text(t('Corporate connection',
                              'Корпоративное подключение'))),
                      if (!consent)
                        Text(t('Corporate connection is unavailable.',
                            'Корпоративное подключение недоступно.')),
                    ]);
              },
            ),
        ],
      );

  String _hotelName(String value) =>
      value.isEmpty ? t('Unassigned', 'Без отеля') : value;

  Widget _tree(List hotels) => ListView(children: [
        ListTile(
            title: Text(t('All hotels', 'Все отели')),
            selected: _hotel == null,
            onTap: () => _choose(null)),
        for (final hotel in [...hotels.cast<String>(), ''])
          ListTile(
            title: Text(_hotelName(hotel)),
            selected: _hotel == hotel,
            onTap: () => _choose(hotel),
          ),
      ]);

  void _choose(String? hotel) => setState(() {
        _hotel = hotel;
        _offset = 0;
        _selected = null;
        _load();
      });

  Widget _hotelComputers(List<Map<String, dynamic>> rows) {
    final hotels = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      hotels.putIfAbsent(row['hotel'] as String? ?? '', () => []).add(row);
    }
    return ListView(children: [
      for (final hotel in hotels.entries)
        ExpansionTile(
          key: PageStorageKey(hotel.key),
          initiallyExpanded: true,
          title: Text(_hotelName(hotel.key)),
          childrenPadding: const EdgeInsetsDirectional.only(start: 16),
          children: hotel.value.map(_record).toList(),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            return Center(
                child: TextButton(
                    onPressed: () => setState(_load),
                    child: Text(error is CorporateApiError &&
                            [401, 403].contains(error.statusCode)
                        ? t('Directory access denied.',
                            'Доступ к каталогу запрещён.')
                        : t('Directory unavailable. Retry',
                            'Каталог недоступен. Повторить'))));
          }
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final data = snapshot.data as Map<String, dynamic>;
          final rows = (data['rows'] as List).cast<Map<String, dynamic>>();
          final sync = data['sync'] as Map<String, dynamic>?;
          final hotels = data['hotels'] as List? ?? [];
          return Column(children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
              IconButton(
                  icon: const Icon(Icons.account_tree_outlined),
                  tooltip: t('Hotels', 'Отели'),
                  onPressed: () =>
                      setState(() => _treeVisible = !_treeVisible)),
              IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: t('Refresh', 'Обновить'),
                  onPressed: () => setState(_load)),
              DropdownButton<String>(
                value: _statusFilter,
                onChanged: (value) => setState(() {
                  _statusFilter = value!;
                  _offset = 0;
                  _selected = null;
                  _load();
                }),
                items: [
                  for (final entry in {
                    'all': t('All statuses', 'Все статусы'),
                    'online': t('Online', 'В сети'),
                    'offline': t('Offline', 'Не в сети'),
                    'no_agent': t('No agent', 'Без агента'),
                  }.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
              ),
              PopupMenuButton<String>(
                  tooltip: t('Sort', 'Сортировка'),
                  icon: const Icon(Icons.sort),
                  onSelected: (field) => setState(() {
                        _sort = field;
                        _offset = 0;
                        _load();
                      }),
                  itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'hostname',
                            child: Text(t('Hostname', 'Имя ПК'))),
                        PopupMenuItem(
                            value: 'heartbeat',
                            child:
                                Text(t('Last heartbeat', 'Последняя связь'))),
                      ]),
              PopupMenuButton<String>(
                  tooltip: t('Columns', 'Колонки'),
                  icon: const Icon(Icons.view_column_outlined),
                  onSelected: (field) => setState(() {
                        if (!_columns.add(field)) _columns.remove(field);
                      }),
                  itemBuilder: (_) => [
                        for (final column in {
                          'user': t('User', 'Пользователь'),
                          'status': t('Agent status', 'Статус агента'),
                          'id': 'YES Desk ID'
                        }.entries)
                          CheckedPopupMenuItem(
                              value: column.key,
                              checked: _columns.contains(column.key),
                              child: Text(column.value)),
                      ]),
              if (sync != null)
                Text(
                    'AD · ${sync['result'] == 'ok' ? t('Synced', 'Синхронизировано') : t('Sync failed', 'Ошибка синхронизации')} · ${_value(sync['successful_at'])}'),
            ]),
            if (_notice != null) Text(_notice!),
            Expanded(child: LayoutBuilder(builder: (context, bounds) {
              final list = rows.isEmpty
                  ? Center(
                      child: Text(
                          t('No devices found.', 'Устройства не найдены.')))
                  : widget.tiles
                      ? GridView.builder(
                          itemCount: rows.length,
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 300, mainAxisExtent: 90),
                          itemBuilder: (_, index) =>
                              Card(child: _record(rows[index])))
                      : _hotel == null
                          ? _hotelComputers(rows)
                          : ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (_, index) => _record(rows[index]));
              final narrow = bounds.maxWidth < (_treeVisible ? 900 : 690);
              final catalog = !_treeVisible
                  ? list
                  : narrow
                      ? Column(children: [
                          SizedBox(height: 110, child: _tree(hotels)),
                          Expanded(child: list),
                        ])
                      : Row(children: [
                          SizedBox(width: 180, child: _tree(hotels)),
                          const VerticalDivider(width: 1),
                          Expanded(child: list),
                        ]);
              final selected = rows.where((row) => _matchesSelection(row)).firstOrNull;
              if (selected == null) return catalog;
              if (!narrow)
                return Row(children: [
                  Expanded(child: catalog),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 315, child: _details(selected)),
                ]);
              return Column(children: [
                Expanded(child: catalog),
                const Divider(height: 1),
                Expanded(flex: 2, child: _details(selected)),
              ]);
            })),
            if (_offset > 0 || data['has_next'] == true)
              Wrap(children: [
                TextButton(
                    onPressed: _offset == 0
                        ? null
                        : () => setState(() {
                              _offset -= 100;
                              _load();
                            }),
                    child: Text(t('Previous', 'Назад'))),
                TextButton(
                    onPressed: data['has_next'] != true
                        ? null
                        : () => setState(() {
                              _offset += 100;
                              _load();
                            }),
                    child: Text(t('Next', 'Далее'))),
              ]),
          ]);
        },
      );
}
