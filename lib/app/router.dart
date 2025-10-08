import 'package:go_router/go_router.dart';
import '../features/home/presentation/pages/home_screen.dart';

GoRouter createRouter() => GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          name: 'home',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: HomeScreen(),
          ),
        ),
      ],
    );
