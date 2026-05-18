// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'service_request_manager.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(ActiveServiceRequest)
final activeServiceRequestProvider = ActiveServiceRequestProvider._();

final class ActiveServiceRequestProvider extends $StreamNotifierProvider<
    ActiveServiceRequest, ServiceRequestWrapper?> {
  ActiveServiceRequestProvider._()
      : super(
          from: null,
          argument: null,
          retry: null,
          name: r'activeServiceRequestProvider',
          isAutoDispose: true,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$activeServiceRequestHash();

  @$internal
  @override
  ActiveServiceRequest create() => ActiveServiceRequest();
}

String _$activeServiceRequestHash() =>
    r'486e1696c1f3e736c0f27186c596e975f4b65eab';

abstract class _$ActiveServiceRequest
    extends $StreamNotifier<ServiceRequestWrapper?> {
  Stream<ServiceRequestWrapper?> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref
        as $Ref<AsyncValue<ServiceRequestWrapper?>, ServiceRequestWrapper?>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<AsyncValue<ServiceRequestWrapper?>, ServiceRequestWrapper?>,
        AsyncValue<ServiceRequestWrapper?>,
        Object?,
        Object?>;
    element.handleCreate(ref, build);
  }
}
