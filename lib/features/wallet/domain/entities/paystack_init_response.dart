class PaystackInitResponse {
  final String authorizationUrl;
  final String reference;
  final String accessCode;

  const PaystackInitResponse({
    required this.authorizationUrl,
    required this.reference,
    required this.accessCode,
  });
}