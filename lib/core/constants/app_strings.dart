// core/constants/app_strings.dart

class AppStrings {
  // ============================================
  // APP BRANDING
  // ============================================
  static const String appName = 'CTS Go';
  static const String appTagline = 'Your Mobility Solution';

  // ============================================
  // SPLASH SCREEN
  // ============================================
  static const String splashTitle = 'CTS Go';
  static const String splashSubtitle = 'Your Mobility Solution';

  // ============================================
  // ONBOARDING SCREEN
  // ============================================
  static const String onboardingSkip = 'Skip';
  static const String onboardingNext = 'Next';
  static const String onboardingGetStarted = 'Get Started';

  // Onboarding Page 1 - Rides
  static const String onboardingTitle1 = 'Book a Ride';
  static const String onboardingSubtitle1 =
      'Request a ride and get picked up in minutes with our trusted drivers';

  // Onboarding Page 2 - Delivery
  static const String onboardingTitle2 = 'Fast Delivery';
  static const String onboardingSubtitle2 =
      'Send packages and parcels with speed and safety';

  // Onboarding Page 3 - Payments
  static const String onboardingTitle3 = 'Secure Payments';
  static const String onboardingSubtitle3 =
      'Multiple payment options including MoMo, Card, and Wallet';

  // ============================================
  // LOGIN SCREEN
  // ============================================
  static const String loginTitle = 'Welcome Back';
  static const String loginSubtitle = 'Sign in to continue';
  static const String loginPhone = 'Phone Number';
  static const String loginPassword = 'Password';
  static const String loginForgotPassword = 'Forgot Password?';
  static const String loginButton = 'Sign In';
  static const String loginNoAccount = 'Don\'t have an account? ';

  //new
  static const String errorEmptyField = 'Sign Up';
  static const String errorInvalidPhone = 'Sign Up';
  static const String errorPasswordTooShort = 'Sign Up';
  static const String loginSignUp = 'Sign Up';

  // ============================================
  // SIGNUP SCREEN
  // ============================================
  static const String signupTitle = 'Create Account';
  static const String signupSubtitle = 'Join CTS Go today';
  static const String signupFirstName = 'First Name';
  static const String signupLastName = 'Last Name';
  static const String signupEmail = 'Email Address';
  static const String signupPhone = 'Phone Number';
  static const String signupPassword = 'Password';
  static const String signupConfirmPassword = 'Confirm Password';
  static const String signupAgreeTerms = 'I agree to the Terms & Conditions';
  static const String signupButton = 'Create Account';
  static const String signupHaveAccount = 'Already have an account? ';

  //new
  static const String errorInvalidEmail = 'Sign In';
  static const String errorPasswordMismatch = 'Sign In';
  static const String signupLogin = 'Sign In';

  // ============================================
  // OTP VERIFICATION SCREEN
  // ============================================
  static const String otpTitle = 'Verify Phone Number';
  static const String otpSubtitle = 'Enter the 4-digit code sent to your phone';
  static const String otpInputLabel = 'OTP Code';
  static const String otpDidntReceive = 'Didn\'t receive code?';
  static const String otpResend = 'Resend Code';
  static const String otpResendIn = 'Resend in ';
  static const String otpVerifyButton = 'Verify';
  //new
  static const String confirm = '';
  static const String otpResendButton = 'Resend';
  static const String otpSeconds = 's';

  // ============================================
  // ROLE SELECTION SCREEN
  // ============================================
  static const String roleSelectionTitle = 'Select Your Role';
  static const String roleSelectionSubtitle =
      'Choose how you want to use CTS Go';
  static const String roleRider = 'Rider';
  static const String roleRiderDescription =
      'Book rides and request deliveries';
  static const String roleDriver = 'Driver';
  static const String roleDriverDescription =
      'Earn money by providing services';
  static const String roleContinueButton = 'Continue';

  //new
  static const String driverRole = 'Continue';
  static const String driverRoleDesc = 'Continue';
  static const String riderRole = 'Continue';
  static const String riderRoleDesc = 'Continue';
  static const String continueButton = 'Continue';

  // ============================================
  // RIDER HOME SCREEN
  // ============================================
  static const String riderGreeting = 'Hello, ';
  static const String riderWhereGoing = 'Where are you going?';
  static const String riderSearchDestination = 'Search destination...';
  static const String riderBookRide = 'Book Ride';
  static const String riderRequestDelivery = 'Request Delivery';
  static const String riderRecentLocations = 'Recent Locations';
  static const String riderNearbyRides = 'Nearby Drivers';
  static const String riderViewHistory = 'View History';
  static const String riderNoHistory = 'No ride history yet';
  static const String riderMyWallet = 'My Wallet';
  static const String riderProfile = 'Profile';
  static const String riderSettings = 'Settings';

  // ============================================
  // DRIVER HOME SCREEN
  // ============================================
  static const String driverGreeting = 'Hello, ';
  static const String driverGoOnline = 'Go Online';
  static const String driverGoOffline = 'Go Offline';
  static const String driverAvailableRequests = 'Available Requests';
  static const String driverNoRequests = 'No requests available';
  static const String driverTodayEarnings = 'Today\'s Earnings';
  static const String driverTotalEarnings = 'Total Earnings';
  static const String driverAcceptedRides = 'Accepted Rides';
  static const String driverCompletedRides = 'Completed';
  static const String driverRating = 'Rating';
  static const String driverTripHistory = 'Trip History';
  static const String driverMyWallet = 'My Wallet';
  static const String driverWithdrawal = 'Request Withdrawal';
  static const String driverProfile = 'Profile';
  static const String driverSettings = 'Settings';

  // ============================================
  // BOOK RIDE SCREEN
  // ============================================
  static const String bookRideTitle = 'Book Your Ride';
  static const String bookRidePickup = 'Pickup Location';
  static const String bookRideDropoff = 'Dropoff Location';
  static const String bookRideSelectVehicle = 'Select Vehicle Type';
  static const String bookRideTaxi = 'Taxi';
  static const String bookRideMotorbike = 'Okada';
  static const String bookRidePragya = 'Pragya';
  static const String bookRideEstimatedFare = 'Estimated Fare';
  static const String bookRideSearching = 'Searching for drivers...';
  static const String bookRideConfirmButton = 'Confirm Booking';
  static const String bookRideCancelButton = 'Cancel';

  // ============================================
  // ACTIVE RIDE SCREEN
  // ============================================
  static const String activeRideTitle = 'Trip in Progress';
  static const String activeRideDriverArriving = 'Driver is arriving';
  static const String activeRideDriverArrived = 'Driver has arrived';
  static const String activeRideInTrip = 'In Transit';
  static const String activeRideDriverDetails = 'Driver Details';
  static const String activeRideVehicleInfo = 'Vehicle Info';
  static const String activeRideCallDriver = 'Call Driver';
  static const String activeRideChatDriver = 'Chat Driver';
  static const String activeRideArrivalTime = 'Arrival in ';
  static const String activeRideMinutes = ' min';
  static const String activeRideCancelTrip = 'Cancel Trip';

  // ============================================
  // RIDE HISTORY SCREEN
  // ============================================
  static const String rideHistoryTitle = 'Ride History';
  static const String rideHistoryEmpty = 'No rides yet';
  static const String rideHistoryNoInternetMsg = 'Unable to load history';
  static const String rideHistoryDate = 'Date';
  static const String rideHistoryDestination = 'Destination';
  static const String rideHistoryFare = 'Fare';
  static const String rideHistoryStatus = 'Status';
  static const String rideHistoryViewDetails = 'View Details';

  // ============================================
  // BOOK DELIVERY SCREEN
  // ============================================
  static const String bookDeliveryTitle = 'Send Delivery';
  static const String bookDeliveryPickup = 'Pickup Location';
  static const String bookDeliveryDropoff = 'Dropoff Location';
  static const String bookDeliveryParcelType = 'Parcel Type';
  static const String bookDeliveryParcel = 'Parcel/Package';
  static const String bookDeliveryGasCylinder = 'Gas Cylinder';
  static const String bookDeliveryReceiverName = 'Receiver Name';
  static const String bookDeliveryReceiverPhone = 'Receiver Phone';
  static const String bookDeliverySelectVehicle = 'Select Vehicle Type';
  static const String bookDeliveryMotorbike = 'Okada';
  static const String bookDeliveryTricycle = 'Tricycle';
  static const String bookDeliveryMiniTruck = 'Mini Truck';
  static const String bookDeliveryEstimatedFee = 'Estimated Fee';
  static const String bookDeliveryConfirmButton = 'Confirm Delivery';

  // ============================================
  // ACTIVE DELIVERY SCREEN
  // ============================================
  static const String activeDeliveryTitle = 'Delivery in Progress';
  static const String activeDeliveryPickedUp = 'Picked Up';
  static const String activeDeliveryInTransit = 'In Transit';
  static const String activeDeliveryDelivering = 'Delivering';
  static const String activeDeliveryDriverArriving = 'Driver is arriving';
  static const String activeDeliveryCallDriver = 'Call Driver';
  static const String activeDeliveryChatDriver = 'Chat Driver';
  static const String activeDeliveryReceiverDetails = 'Receiver Details';
  static const String activeDeliveryTrackingCode = 'Tracking Code';
  static const String activeDeliveryCancelDelivery = 'Cancel Delivery';

  // ============================================
  // WALLET SCREEN
  // ============================================
  static const String walletTitle = 'My Wallet';
  static const String walletBalance = 'Wallet Balance';
  static const String walletAvailable = 'Available';
  static const String walletPending = 'Pending';
  static const String walletAddMoney = 'Add Money';
  static const String walletWithdraw = 'Withdraw';
  static const String walletTransactionHistory = 'Transaction History';
  static const String walletNoTransactions = 'No transactions yet';
  static const String walletPaymentMethod = 'Payment Method';
  static const String walletMoMo = 'MTN MoMo';
  static const String walletCard = 'Debit Card';
  static const String walletCash = 'Cash';
  static const String walletTopup = 'Topup Amount';
  static const String walletMinimum = 'Minimum GHS 1';

  // ============================================
  // WITHDRAWAL SCREEN
  // ============================================
  static const String withdrawalTitle = 'Request Withdrawal';
  static const String withdrawalAmount = 'Withdrawal Amount';
  static const String withdrawalBankAccount = 'Bank Account';
  static const String withdrawalSelectBank = 'Select Bank';
  static const String withdrawalAccountNumber = 'Account Number';
  static const String withdrawalAccountName = 'Account Name';
  static const String withdrawalMinimumAmount = 'Minimum withdrawal: GHS 50';
  static const String withdrawalProcessingTime =
      'Processing time: 1-2 business days';
  static const String withdrawalConfirmButton = 'Request Withdrawal';
  static const String withdrawalPending = 'Withdrawal Pending';
  static const String withdrawalCompleted = 'Withdrawal Completed';

  // ============================================
  // DRIVER PROFILE SCREEN
  // ============================================
  static const String profileTitle = 'My Profile';
  static const String profileFullName = 'Full Name';
  static const String profilePhoneNumber = 'Phone Number';
  static const String profileEmail = 'Email Address';
  static const String profileVehicleType = 'Vehicle Type';
  static const String profileVehicleNumber = 'Vehicle Number';
  static const String profileDocuments = 'Documents';
  static const String profileIDUpload = 'Upload ID';
  static const String profileLicenseUpload = 'Upload License';
  static const String profileEditProfile = 'Edit Profile';
  static const String profileChangePassword = 'Change Password';
  static const String profileLogout = 'Logout';

  // ============================================
  // AVAILABLE REQUESTS SCREEN
  // ============================================
  static const String requestsTitle = 'Available Requests';
  static const String requestsEmpty = 'No requests available';
  static const String requestsRefresh = 'Refresh';
  static const String requestsPickup = 'Pickup';
  static const String requestsDropoff = 'Dropoff';
  static const String requestsDistance = 'Distance';
  static const String requestsFare = 'Fare';
  static const String requestsAccept = 'Accept';
  static const String requestsReject = 'Reject';
  static const String requestsRiderRating = 'Rider Rating';

  // ============================================
  // EARNINGS SCREEN
  // ============================================
  static const String earningsTitle = 'My Earnings';
  static const String earningsToday = 'Today';
  static const String earningsThisWeek = 'This Week';
  static const String earningsThisMonth = 'This Month';
  static const String earningsTotalEarnings = 'Total Earnings';
  static const String earningsCommissionDeducted = 'Commission Deducted';
  static const String earningsNetEarnings = 'Net Earnings';
  static const String earningsRidesCompleted = 'Rides Completed';
  static const String earningsAverageRating = 'Average Rating';
  static const String earningsBreakdown = 'Earnings Breakdown';

  // ============================================
  // VALIDATION MESSAGES
  // ============================================
  static const String validationFieldRequired = 'This field is required';
  static const String validationInvalidEmail =
      'Please enter a valid email address';
  static const String validationInvalidPhone =
      'Please enter a valid phone number';
  static const String validationPasswordTooShort =
      'Password must be at least 6 characters';
  static const String validationPasswordMismatch = 'Passwords do not match';
  static const String validationPhoneRequired = 'Phone number is required';
  static const String validationEmptyField = 'This field cannot be empty';
  static const String validationInvalidAmount = 'Please enter a valid amount';
  static const String validationMinimumAmount = 'Minimum amount required';

  // ============================================
  // STATUS LABELS
  // ============================================
  static const String statusCompleted = 'Completed';
  static const String statusPending = 'Pending';
  static const String statusInProgress = 'In Progress';
  static const String statusCancelled = 'Cancelled';
  static const String statusRejected = 'Rejected';
  static const String statusSearching = 'Searching';
  static const String statusAccepted = 'Accepted';
  static const String statusPickedUp = 'Picked Up';
  static const String statusInTransit = 'In Transit';
  static const String statusDelivered = 'Delivered';
  static const String statusOnline = 'Online';
  static const String statusOffline = 'Offline';
  static const String statusAvailable = 'Available';
  static const String statusBusy = 'Busy';

  // ============================================
  // ACTION BUTTONS (Common)
  // ============================================
  static const String buttonContinue = 'Continue';
  static const String buttonConfirm = 'Confirm';
  static const String buttonCancel = 'Cancel';
  static const String buttonBack = 'Back';
  static const String buttonNext = 'Next';
  static const String buttonSkip = 'Skip';
  static const String buttonSubmit = 'Submit';
  static const String buttonSave = 'Save';
  static const String buttonEdit = 'Edit';
  static const String buttonDelete = 'Delete';
  static const String buttonClose = 'Close';
  static const String buttonOK = 'OK';
  static const String buttonRetry = 'Retry';
  static const String buttonSendOTP = 'Send OTP';
  static const String buttonLogout = 'Logout';

  // ============================================
  // COMMON MESSAGES
  // ============================================
  static const String messageLoading = 'Loading...';
  static const String messageError = 'An error occurred';
  static const String messageSomethingWrong = 'Something went wrong';
  static const String messageSuccess = 'Success';
  static const String messageTryAgain = 'Try Again';
  static const String messageNoInternet = 'No internet connection';
  static const String messageOfflineMode = 'You are offline';
  static const String messageSessionExpired =
      'Session expired. Please login again';
  static const String messageServerError =
      'Server error. Please try again later';
  static const String messageNetworkError =
      'Network error. Please check your connection';

  // ============================================
  // CONFIRMATION DIALOGS
  // ============================================
  static const String confirmCancelRide =
      'Are you sure you want to cancel this ride?';
  static const String confirmCancelDelivery =
      'Are you sure you want to cancel this delivery?';
  static const String confirmLogout = 'Are you sure you want to logout?';
  static const String confirmDeleteAccount =
      'Are you sure you want to delete your account?';
  static const String confirmRejectRequest =
      'Are you sure you want to reject this request?';

  // ============================================
  // NOTIFICATIONS
  // ============================================
  static const String notificationRideConfirmed = 'Ride confirmed';
  static const String notificationDriverArrived = 'Driver has arrived';
  static const String notificationTripCompleted = 'Trip completed successfully';
  static const String notificationDeliveryConfirmed = 'Delivery confirmed';
  static const String notificationDeliveryCompleted = 'Delivery completed';
  static const String notificationPaymentReceived = 'Payment received';
  static const String notificationEarningsAdded =
      'Earnings added to your wallet';
  static const String notificationNewRequest = 'New request available';

  // ============================================
  // EMPTY STATES
  // ============================================
  static const String emptyHistoryTitle = 'No History';
  static const String emptyHistoryMessage =
      'You haven\'t completed any trips yet';
  static const String emptyRequestsTitle = 'No Requests';
  static const String emptyRequestsMessage = 'No requests available right now';
  static const String emptyTransactionsTitle = 'No Transactions';
  static const String emptyTransactionsMessage =
      'Your transaction history is empty';
  static const String emptySearchTitle = 'No Results';
  static const String emptySearchMessage = 'Try searching for something else';

  // ============================================
  // PAYMENT & PRICING
  // ============================================
  static const String priceEstimate = 'Estimated Price';
  static const String priceBaseFare = 'Base Fare';
  static const String pricePerKm = 'Per KM';
  static const String pricePerMinute = 'Per Minute';
  static const String priceTotal = 'Total';
  static const String priceSubtotal = 'Subtotal';
  static const String priceTax = 'Tax';
  static const String priceDiscount = 'Discount';
  static const String paymentMethod = 'Payment Method';
  static const String paymentMomo = 'MTN MoMo';
  static const String paymentCard = 'Debit Card';
  static const String paymentWallet = 'Wallet';
  static const String paymentCash = 'Cash';

  // ============================================
  // TIME RELATED
  // ============================================
  static const String timeNow = 'Now';
  static const String timeSchedule = 'Schedule';
  static const String timeToday = 'Today';
  static const String timeTomorrow = 'Tomorrow';
  static const String timeMinute = 'min';
  static const String timeMinutes = 'mins';
  static const String timeHour = 'hour';
  static const String timeHours = 'hours';
  static const String timeDistance = 'km away';
}
