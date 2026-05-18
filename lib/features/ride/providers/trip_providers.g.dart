// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trip_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(activeTripStream)
final activeTripStreamProvider = ActiveTripStreamProvider._();

final class ActiveTripStreamProvider extends $FunctionalProvider<
        AsyncValue<TripRequest?>, TripRequest?, Stream<TripRequest?>>
    with $FutureModifier<TripRequest?>, $StreamProvider<TripRequest?> {
  ActiveTripStreamProvider._()
      : super(
          from: null,
          argument: null,
          retry: null,
          name: r'activeTripStreamProvider',
          isAutoDispose: true,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$activeTripStreamHash();

  @$internal
  @override
  $StreamProviderElement<TripRequest?> $createElement(
          $ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<TripRequest?> create(Ref ref) {
    return activeTripStream(ref);
  }
}

String _$activeTripStreamHash() => r'6e278581199ad8949478868df3ca2aba5f632d2a';

@ProviderFor(TripRequestManager)
final tripRequestManagerProvider = TripRequestManagerProvider._();

final class TripRequestManagerProvider
    extends $AsyncNotifierProvider<TripRequestManager, void> {
  TripRequestManagerProvider._()
      : super(
          from: null,
          argument: null,
          retry: null,
          name: r'tripRequestManagerProvider',
          isAutoDispose: true,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$tripRequestManagerHash();

  @$internal
  @override
  TripRequestManager create() => TripRequestManager();
}

String _$tripRequestManagerHash() =>
    r'1486495b17427ff5f44244290be79cba2f79dcf1';

abstract class _$TripRequestManager extends $AsyncNotifier<void> {
  FutureOr<void> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<AsyncValue<void>, void>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<AsyncValue<void>, void>,
        AsyncValue<void>,
        Object?,
        Object?>;
    element.handleCreate(ref, build);
  }
}
