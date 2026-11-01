import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: PcdropApp()));
}

class PcdropApp extends StatelessWidget {
  const PcdropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PCDrop',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

@Deprecated('Use PcdropApp for the application entry point.')
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _LegacyMyAppState();
}

class _LegacyMyAppState extends State<MyApp> {
  var _counter = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: Text('$_counter')),
        floatingActionButton: FloatingActionButton(
          onPressed: () => setState(() => _counter++),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}
