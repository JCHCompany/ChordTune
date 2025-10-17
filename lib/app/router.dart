import 'package:go_router/go_router.dart';
import '../features/home/presentation/pages/home_screen.dart';
import '../tuner/ui/tuner_page.dart';

GoRouter createRouter() => GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          name: 'home',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: HomeScreen(),
          ),
        ),
        GoRoute(
          path: '/tuner',
          name: 'tuner',
          pageBuilder: (context, state) => const NoTransitionPage(
            child: TunerPage(),
          ),
        ),
      ],
    );
