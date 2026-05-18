class OnboardingModel {
  final int id;
  final String title;
  final String subtitle;
  final String imagePath;

  OnboardingModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imagePath,
  });
}

final List<OnboardingModel> onboardingPages = [
  OnboardingModel(
    id: 1,
    title: 'Book a Ride',
    subtitle: 'Request a ride and get picked up in minutes',
    imagePath: 'assets/images/onboard.png',
  ),
  OnboardingModel(
    id: 2,
    title: 'Fast Delivery',
    subtitle: 'Send packages and parcels with ease',
    imagePath: 'assets/images/onboarding_2.png',
  ),
  OnboardingModel(
    id: 3,
    title: 'Secure Payments',
    subtitle: 'Multiple payment options for your convenience',
    imagePath: 'assets/images/onboarding_3.png',
  ),
];