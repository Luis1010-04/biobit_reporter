import 'package:flutter/material.dart';
import 'chat_screen.dart';

void main() {
  runApp(const BiobitReporterApp());
}

class BiobitReporterApp extends StatelessWidget {
  const BiobitReporterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Biobit Reporter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const ChatScreen(),
    );
  }
}