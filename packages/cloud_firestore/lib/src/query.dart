// Copyright 2017, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of cloud_firestore;

/// Represents a query over the data at a particular location.
class Query {
  Query._(
      {@required this.firestore,
      @required List<String> pathComponents,
      bool isCollectionGroup = false,
      Map<String, dynamic> parameters})
      : _pathComponents = pathComponents,
        _isCollectionGroup = isCollectionGroup,
        _parameters = parameters ??
            Map<String, dynamic>.unmodifiable(<String, dynamic>{
              'where': List<List<dynamic>>.unmodifiable(<List<dynamic>>[]),
              'orderBy': List<List<dynamic>>.unmodifiable(<List<dynamic>>[]),
            }),
        assert(firestore != null),
        assert(pathComponents != null);

  /// The Firestore instance associated with this query
  final Firestore firestore;

  final List<String> _pathComponents;
  final Map<String, dynamic> _parameters;
  final bool _isCollectionGroup;

  String get _path => _pathComponents.join('/');

  Query _copyWithParameters(Map<String, dynamic> parameters) {
    return Query._(
      firestore: firestore,
      isCollectionGroup: _isCollectionGroup,
      pathComponents: _pathComponents,
      parameters: Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(_parameters)..addAll(parameters),
      ),
    );
  }

  Map<String, dynamic> buildArguments() {
    return Map<String, dynamic>.from(_parameters)
      ..addAll(<String, dynamic>{
        'path': _path,
      });
  }

  /// Notifies of query results at this location
  // TODO(jackson): Reduce code duplication with [DocumentReference]
  Stream<QuerySnapshot> snapshots({bool includeMetadataChanges = false}) {
    assert(includeMetadataChanges != null);
    Future<int> _handle;
    // It's fine to let the StreamController be garbage collected once all the
    // subscribers have cancelled; this analyzer warning is safe to ignore.
    StreamController<QuerySnapshot> controller; // ignore: close_sinks
    controller = StreamController<QuerySnapshot>.broadcast(
      onListen: () {
        _handle = Firestore.channel.invokeMethod<int>(
          'Query#addSnapshotListener',
          <String, dynamic>{
            'app': firestore.app.name,
            'path': _path,
            'isCollectionGroup': _isCollectionGroup,
            'parameters': _parameters,
            'includeMetadataChanges': includeMetadataChanges,
          },
        ).then<int>((dynamic result) => result);
        _handle.then((int handle) {
          Firestore._queryObservers[handle] = controller;
        });
      },
      onCancel: () {
        _handle.then((int handle) async {
          await Firestore.channel.invokeMethod<void>(
            'removeListener',
            <String, dynamic>{'handle': handle},
          );
          Firestore._queryObservers.remove(handle);
        });
      },
    );
    return controller.stream;
  }

  /// Fetch the documents for this query
  Future<QuerySnapshot> getDocuments(
      {Source source = Source.serverAndCache}) async {
    assert(source != null);
    final Map<dynamic, dynamic> data =
        await Firestore.channel.invokeMapMethod<String, dynamic>(
      'Query#getDocuments',
      <String, dynamic>{
        'app': firestore.app.name,
        'path': _path,
        'isCollectionGroup': _isCollectionGroup,
        'parameters': _parameters,
        'source': _getSourceString(source),
      },
    );
    return QuerySnapshot._(data, firestore);
  }

  /// Obtains a CollectionReference corresponding to this query's location.
  CollectionReference reference() =>
      CollectionReference._(firestore, _pathComponents);

  /// Creates and returns a new [Query] with additional filter on specified
  /// [field]. [field] refers to a field in a document.
  ///
  /// The [field] may be a [String] consisting of a single field name
  /// (referring to a top level field in the document),
  /// or a series of field names separated by dots '.'
  /// (referring to a nested field in the document).
  /// Alternatively, the [field] can also be a [FieldPath].
  ///
  /// Only documents satisfying provided condition are included in the result
  /// set.
  Query where(
    dynamic field, {
    dynamic isEqualTo,
    dynamic isLessThan,
    dynamic isLessThanOrEqualTo,
    dynamic isGreaterThan,
    dynamic isGreaterThanOrEqualTo,
    dynamic arrayContains,
    bool isNull,
  }) {
    assert(field is String || field is FieldPath,
        'Supported [field] types are [String] and [FieldPath].');

    final ListEquality<dynamic> equality = const ListEquality<dynamic>();
    final List<List<dynamic>> conditions =
        List<List<dynamic>>.from(_parameters['where']);

    void addCondition(dynamic field, String operator, dynamic value) {
      final List<dynamic> condition = <dynamic>[field, operator, value];
      assert(
          conditions
              .where((List<dynamic> item) => equality.equals(condition, item))
              .isEmpty,
          'Condition $condition already exists in this query.');
      conditions.add(condition);
    }

    if (isEqualTo != null) addCondition(field, '==', isEqualTo);
    if (isLessThan != null) addCondition(field, '<', isLessThan);
    if (isLessThanOrEqualTo != null)
      addCondition(field, '<=', isLessThanOrEqualTo);
    if (isGreaterThan != null) addCondition(field, '>', isGreaterThan);
    if (isGreaterThanOrEqualTo != null)
      addCondition(field, '>=', isGreaterThanOrEqualTo);
    if (arrayContains != null)
      addCondition(field, 'array-contains', arrayContains);
    if (isNull != null) {
      assert(
          isNull,
          'isNull can only be set to true. '
          'Use isEqualTo to filter on non-null values.');
      addCondition(field, '==', null);
    }

    return _copyWithParameters(<String, dynamic>{'where': conditions});
  }

  /// Creates and returns a new [Query] that's additionally sorted by the specified
  /// [field].
  /// The field may be a [String] representing a single field name or a [FieldPath].
  ///
  /// After a [FieldPath.documentId] order by call, you cannot add any more [orderBy]
  /// calls.
  /// Furthermore, you may not use [orderBy] on the [FieldPath.documentId] [field] when
  /// using [startAfterDocument], [startAtDocument], [endAfterDocument],
  /// or [endAtDocument] because the order by clause on the document id
  /// is added by these methods implicitly.
  Query orderBy(dynamic field, {bool descending = false}) {
    assert(field != null && descending != null);
    assert(field is String || field is FieldPath,
        'Supported [field] types are [String] and [FieldPath].');

    final List<List<dynamic>> orders =
        List<List<dynamic>>.from(_parameters['orderBy']);

    final List<dynamic> order = <dynamic>[field, descending];
    assert(orders.where((List<dynamic> item) => field == item[0]).isEmpty,
        'OrderBy $field already exists in this query');

    assert(() {
      if (field == FieldPath.documentId) {
        return !(_parameters.containsKey('startAfterDocument') ||
            _parameters.containsKey('startAtDocument') ||
            _parameters.containsKey('endAfterDocument') ||
            _parameters.containsKey('endAtDocument'));
      }
      return true;
    }(),
        '{start/end}{At/After/Before}Document order by document id themselves. '
        'Hence, you may not use an order by [FieldPath.documentId] when using any of these methods for a query.');

    orders.add(order);
    return _copyWithParameters(<String, dynamic>{'orderBy': orders});
  }

  /// Creates and returns a new [Query] that starts after the provided document
  /// (exclusive). The starting position is relative to the order of the query.
  /// The document must contain all of the fields provided in the orderBy of
  /// this query.
  ///
  /// Cannot be used in combination with [startAtDocument], [startAt], or
  /// [startAfter], but can be used in combination with [endAt],
  /// [endBefore], [endAtDocument] and [endBeforeDocument].
  ///
  /// See also:
  ///  * [endAfterDocument] for a query that ends after a document.
  ///  * [startAtDocument] for a query that starts at a document.
  ///  * [endAtDocument] for a query that ends at a document.
  Query startAfterDocument(DocumentSnapshot documentSnapshot) {
    assert(documentSnapshot != null);
    assert(!_parameters.containsKey('startAfter'));
    assert(!_parameters.containsKey('startAt'));
    assert(!_parameters.containsKey('startAfterDocument'));
    assert(!_parameters.containsKey('startAtDocument'));
    assert(
        List<List<dynamic>>.from(_parameters['orderBy'])
            .where((List<dynamic> item) => item[0] == FieldPath.documentId)
            .isEmpty,
        '[startAfterDocument] orders by document id itself. '
        'Hence, you may not use an order by [FieldPath.documentId] when using [startAfterDocument].');
    return _copyWithParameters(<String, dynamic>{
      'startAfterDocument': <String, dynamic>{
        'id': documentSnapshot.documentID,
        'path': documentSnapshot.reference.path,
        'data': documentSnapshot.data
      }
    });
  }

  /// Creates and returns a new [Query] that starts at the provided document
  /// (inclusive). The starting position is relative to the order of the query.
  /// The document must contain all of the fields provided in the orderBy of
  /// this query.
  ///
  /// Cannot be used in combination with [startAfterDocument], [startAfter], or
  /// [startAt], but can be used in combination with [endAt],
  /// [endBefore], [endAtDocument] and [endBeforeDocument].
  ///
  /// See also:
  ///  * [startAfterDocument] for a query that starts after a document.
  ///  * [endAtDocument] for a query that ends at a document.
  ///  * [endBeforeDocument] for a query that ends before a document.
  Query startAtDocument(DocumentSnapshot documentSnapshot) {
    assert(documentSnapshot != null);
    assert(!_parameters.containsKey('startAfter'));
    assert(!_parameters.containsKey('startAt'));
    assert(!_parameters.containsKey('startAfterDocument'));
    assert(!_parameters.containsKey('startAtDocument'));
    assert(
        List<List<dynamic>>.from(_parameters['orderBy'])
            .where((List<dynamic> item) => item[0] == FieldPath.documentId)
            .isEmpty,
        '[startAtDocument] orders by document id itself. '
        'Hence, you may not use an order by [FieldPath.documentId] when using [startAtDocument].');
    return _copyWithParameters(<String, dynamic>{
      'startAtDocument': <String, dynamic>{
        'id': documentSnapshot.documentID,
        'path': documentSnapshot.reference.path,
        'data': documentSnapshot.data
      },
    });
  }

  /// Takes a list of [values], creates and returns a new [Query] that starts
  /// after the provided fields relative to the order of the query.
  ///
  /// The [values] must be in order of [orderBy] filters.
  ///
  /// Cannot be used in combination with [startAt], [startAfterDocument], or
  /// [startAtDocument], but can be used in combination with [endAt],
  /// [endBefore], [endAtDocument] and [endBeforeDocument].
  Query startAfter(List<dynamic> values) {
    assert(values != null);
    assert(!_parameters.containsKey('startAfter'));
    assert(!_parameters.containsKey('startAt'));
    assert(!_parameters.containsKey('startAfterDocument'));
    assert(!_parameters.containsKey('startAtDocument'));
    return _copyWithParameters(<String, dynamic>{'startAfter': values});
  }

  /// Takes a list of [values], creates and returns a new [Query] that starts at
  /// the provided fields relative to the order of the query.
  ///
  /// The [values] must be in order of [orderBy] filters.
  ///
  /// Cannot be used in combination with [startAfter], [startAfterDocument],
  /// or [startAtDocument], but can be used in combination with [endAt],
  /// [endBefore], [endAtDocument] and [endBeforeDocument].
  Query startAt(List<dynamic> values) {
    assert(values != null);
    assert(!_parameters.containsKey('startAfter'));
    assert(!_parameters.containsKey('startAt'));
    assert(!_parameters.containsKey('startAfterDocument'));
    assert(!_parameters.containsKey('startAtDocument'));
    return _copyWithParameters(<String, dynamic>{'startAt': values});
  }

  /// Creates and returns a new [Query] that ends at the provided document
  /// (inclusive). The end position is relative to the order of the query.
  /// The document must contain all of the fields provided in the orderBy of
  /// this query.
  ///
  /// Cannot be used in combination with [endBefore], [endBeforeDocument], or
  /// [endAt], but can be used in combination with [startAt],
  /// [startAfter], [startAtDocument] and [startAfterDocument].
  ///
  /// See also:
  ///  * [startAfterDocument] for a query that starts after a document.
  ///  * [startAtDocument] for a query that starts at a document.
  ///  * [endBeforeDocument] for a query that ends before a document.
  Query endAtDocument(DocumentSnapshot documentSnapshot) {
    assert(documentSnapshot != null);
    assert(!_parameters.containsKey('endBefore'));
    assert(!_parameters.containsKey('endAt'));
    assert(!_parameters.containsKey('endBeforeDocument'));
    assert(!_parameters.containsKey('endAtDocument'));
    assert(
        List<List<dynamic>>.from(_parameters['orderBy'])
            .where((List<dynamic> item) => item[0] == FieldPath.documentId)
            .isEmpty,
        '[endAtDocument] orders by document id itself. '
        'Hence, you may not use an order by [FieldPath.documentId] when using [endAtDocument].');
    return _copyWithParameters(<String, dynamic>{
      'endAtDocument': <String, dynamic>{
        'id': documentSnapshot.documentID,
        'path': documentSnapshot.reference.path,
        'data': documentSnapshot.data
      },
    });
  }

  /// Takes a list of [values], creates and returns a new [Query] that ends at the
  /// provided fields relative to the order of the query.
  ///
  /// The [values] must be in order of [orderBy] filters.
  ///
  /// Cannot be used in combination with [endBefore], [endBeforeDocument], or
  /// [endAtDocument], but can be used in combination with [startAt],
  /// [startAfter], [startAtDocument] and [startAfterDocument].
  Query endAt(List<dynamic> values) {
    assert(values != null);
    assert(!_parameters.containsKey('endBefore'));
    assert(!_parameters.containsKey('endAt'));
    assert(!_parameters.containsKey('endBeforeDocument'));
    assert(!_parameters.containsKey('endAtDocument'));
    return _copyWithParameters(<String, dynamic>{'endAt': values});
  }

  /// Creates and returns a new [Query] that ends before the provided document
  /// (exclusive). The end position is relative to the order of the query.
  /// The document must contain all of the fields provided in the orderBy of
  /// this query.
  ///
  /// Cannot be used in combination with [endAt], [endBefore], or
  /// [endAtDocument], but can be used in combination with [startAt],
  /// [startAfter], [startAtDocument] and [startAfterDocument].
  ///
  /// See also:
  ///  * [startAfterDocument] for a query that starts after document.
  ///  * [startAtDocument] for a query that starts at a document.
  ///  * [endAtDocument] for a query that ends at a document.
  Query endBeforeDocument(DocumentSnapshot documentSnapshot) {
    assert(documentSnapshot != null);
    assert(!_parameters.containsKey('endBefore'));
    assert(!_parameters.containsKey('endAt'));
    assert(!_parameters.containsKey('endBeforeDocument'));
    assert(!_parameters.containsKey('endAtDocument'));
    assert(
        List<List<dynamic>>.from(_parameters['orderBy'])
            .where((List<dynamic> item) => item[0] == FieldPath.documentId)
            .isEmpty,
        '[endBeforeDocument] orders by document id itself. '
        'Hence, you may not use an order by [FieldPath.documentId] when using [endBeforeDocument].');
    return _copyWithParameters(<String, dynamic>{
      'endBeforeDocument': <String, dynamic>{
        'id': documentSnapshot.documentID,
        'path': documentSnapshot.reference.path,
        'data': documentSnapshot.data,
      },
    });
  }

  /// Takes a list of [values], creates and returns a new [Query] that ends before
  /// the provided fields relative to the order of the query.
  ///
  /// The [values] must be in order of [orderBy] filters.
  ///
  /// Cannot be used in combination with [endAt], [endBeforeDocument], or
  /// [endBeforeDocument], but can be used in combination with [startAt],
  /// [startAfter], [startAtDocument] and [startAfterDocument].
  Query endBefore(List<dynamic> values) {
    assert(values != null);
    assert(!_parameters.containsKey('endBefore'));
    assert(!_parameters.containsKey('endAt'));
    assert(!_parameters.containsKey('endBeforeDocument'));
    assert(!_parameters.containsKey('endAtDocument'));
    return _copyWithParameters(<String, dynamic>{'endBefore': values});
  }

  /// Creates and returns a new Query that's additionally limited to only return up
  /// to the specified number of documents.
  Query limit(int length) {
    assert(!_parameters.containsKey('limit'));
    return _copyWithParameters(<String, dynamic>{'limit': length});
  }
}
