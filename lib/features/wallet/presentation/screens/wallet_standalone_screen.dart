// Standalone wallet screen — used when navigating to /wallet from outside shell
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A56DB),
        foregroundColor: Colors.white,
        title: const Text(
          'My Wallet',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        elevation: 0,
      ),
      body: WalletScreen(scrollController: _scrollController),
    );
  }
}
