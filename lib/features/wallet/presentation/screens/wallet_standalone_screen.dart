// Standalone wallet screen — used when navigating to /wallet from outside shell
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/cts_theme.dart';
import '../../../../core/widgets/cts_ui.dart';
import 'wallet_screen.dart';

class WalletStandaloneScreen extends StatefulWidget {
  const WalletStandaloneScreen({super.key});

  @override
  State<WalletStandaloneScreen> createState() => _WalletStandaloneScreenState();
}

class _WalletStandaloneScreenState extends State<WalletStandaloneScreen> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CtsTheme.background,
      // Light bar with the shared back control; the Wallet page carries its
      // own title below it.
      appBar: AppBar(
        backgroundColor: CtsTheme.background,
        foregroundColor: CtsTheme.textPrimary,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        elevation: 0,
        leadingWidth: 64,
        leading: const Padding(
          padding: EdgeInsets.only(left: ctsGutter),
          child: Center(child: CtsBackButton()),
        ),
      ),
      body: WalletScreen(scrollController: _scrollController),
    );
  }
}
